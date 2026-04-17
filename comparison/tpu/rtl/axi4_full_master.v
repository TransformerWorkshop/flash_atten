module axi4_full_master#(
    parameter  AXI_ID_WIDTH          = 4  ,
    parameter  AXI_ADDR_WIDTH        = 32 ,
    parameter  AXI_DATA_WIDTH        = 32 ,
    parameter  RAM_DATA_WIDTH        = AXI_DATA_WIDTH ,
    parameter  AXI_AWUSER_WIDTH      = 8  ,
    parameter  AXI_WUSER_WIDTH       = 8  ,
    parameter  AXI_BUSER_WIDTH       = 8  ,
    parameter  MAX_BURST_LEN         = 255,
    parameter  FIFO_DEPTH            = 32
)(
    input  wire                              m_axi_aclk       ,
    input  wire                              m_axi_aresetn    ,

    // AXI写地址通道
    output wire [          AXI_ID_WIDTH-1:0] m_axi_awid       ,
    output wire [        AXI_ADDR_WIDTH-1:0] m_axi_awaddr     ,
    output wire [                       7:0] m_axi_awlen      ,
    output wire [                       2:0] m_axi_awsize     ,
    output wire [                       1:0] m_axi_awburst    ,
    output wire                              m_axi_awlock     ,
    output wire [                       3:0] m_axi_awcache    ,
    output wire [                       2:0] m_axi_awprot     ,
    output wire [                       3:0] m_axi_awqos      ,
    output wire [                       3:0] m_axi_awregion   ,
    output wire [      AXI_AWUSER_WIDTH-1:0] m_axi_awuser     ,
    output wire                              m_axi_awvalid    ,
    input  wire                              m_axi_awready    ,

    // AXI写数据通道
    output wire [        AXI_DATA_WIDTH-1:0] m_axi_wdata      ,
    output wire [    (AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb      ,
    output wire                              m_axi_wlast      ,
    output wire [       AXI_WUSER_WIDTH-1:0] m_axi_wuser      ,
    output wire                              m_axi_wvalid     ,
    input  wire                              m_axi_wready     ,

    // AXI写响应通道
    input  wire [          AXI_ID_WIDTH-1:0] m_axi_bid        ,
    input  wire [                       1:0] m_axi_bresp      ,
    input  wire [       AXI_BUSER_WIDTH-1:0] m_axi_buser      ,
    input  wire                              m_axi_bvalid     ,
    output wire                              m_axi_bready     ,

    // RAM接口
    output wire                              axi_rd_en        ,
    output wire [        AXI_ADDR_WIDTH-1:0] axi_rd_addr      ,
    input  wire [        AXI_DATA_WIDTH-1:0] axi_rd_data      ,
    input  wire                              axi_rd_data_vld  ,

    // 控制信号
    input  wire                              transfer_start   ,
    input  wire [                      15:0] transfer_count   ,
    input  wire [        AXI_ADDR_WIDTH-1:0] ram_base_addr    ,
    input  wire [        AXI_ADDR_WIDTH-1:0] axi_target_addr  ,
    
    // 状态信号
    output wire                              transfer_done    ,
    output wire [                       1:0] transfer_status    
);

    // 内部寄存器定义
    reg [      AXI_ID_WIDTH-1:0] awid_r    ;
    reg [    AXI_ADDR_WIDTH-1:0] awaddr_r  ;
    reg [                   7:0] awlen_r   ;
    reg [                   2:0] awsize_r  ;
    reg [                   1:0] awburst_r ;
    reg                          awlock_r  ;
    reg [                   3:0] awcache_r ;
    reg [                   2:0] awprot_r  ;
    reg [                   3:0] awqos_r   ;
    reg [                   3:0] awregion_r;
    reg [  AXI_AWUSER_WIDTH-1:0] awuser_r  ;
    reg                          awvalid_r ;
    
    reg [(AXI_DATA_WIDTH/8)-1:0] wstrb_r   ;
    reg                          wlast_r   ;
    reg [   AXI_WUSER_WIDTH-1:0] wuser_r   ;
    reg                          wvalid_r  ;
    
    reg                          bready_r  ;
    
    reg                          ram_rd_en_r  ;
    reg [    AXI_ADDR_WIDTH-1:0] ram_rd_addr_r;
    
    reg                          transfer_done_r  ;
    reg [                   1:0] transfer_status_r;

    // 定义状态机状态
    localparam IDLE       = 3'd0;
    localparam SETUP      = 3'd1;
    localparam ADDR_PHASE = 3'd2;
    localparam DATA_PHASE = 3'd3;
    localparam RESP_PHASE = 3'd4;
    localparam COMPLETE   = 3'd5;
    localparam ERROR      = 3'd6;

    // 状态寄存器
    reg [2:0] curr_state;
    reg [2:0] next_state;

    // 计数器和控制寄存器
    reg [15:0] data_sent_count;     // 已发送数据计数
    reg [15:0] data_read_count;     // 已读取数据计数
    reg [7:0]  current_burst_len;   // 当前突发长度
    reg [31:0] current_axi_addr;    // 当前AXI地址
    reg [7:0]  burst_data_count;    // 当前突发内已发送数据计数
    
    // FIFO参数定义
    localparam FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH);
    localparam AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8;
    localparam RAM_STRB_WIDTH = RAM_DATA_WIDTH / 8;
    localparam RAM_WORDS_PER_AXI_BEAT = (RAM_DATA_WIDTH >= AXI_DATA_WIDTH) ? 1 : (AXI_DATA_WIDTH / RAM_DATA_WIDTH);
    localparam PACK_COUNT_WIDTH = (RAM_WORDS_PER_AXI_BEAT > 1) ? $clog2(RAM_WORDS_PER_AXI_BEAT + 1) : 1;
    reg [AXI_DATA_WIDTH-1:0] fifo_data [0:FIFO_DEPTH-1]; // 数据存储
    reg [AXI_STRB_WIDTH-1:0] fifo_strb [0:FIFO_DEPTH-1];
    reg [FIFO_ADDR_WIDTH:0]  fifo_wr_ptr; // 写指针，多一位用于判断FIFO满
    reg [FIFO_ADDR_WIDTH:0]  fifo_rd_ptr; // 读指针，多一位用于判断FIFO空
    wire [FIFO_ADDR_WIDTH:0] fifo_count;  // FIFO中数据计数
    wire fifo_empty; // FIFO是否为空
    wire fifo_full;  // FIFO是否已满
    wire fifo_almost_full; // FIFO接近满
    wire fifo_almost_empty; // FIFO接近空
    
    // FIFO状态信号
    assign fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    assign fifo_empty = (fifo_count == 0);
    assign fifo_full  = (fifo_count == FIFO_DEPTH);
    assign fifo_almost_full  = (fifo_count >= (FIFO_DEPTH - 4));
    assign fifo_almost_empty = (fifo_count <= 4);
    
    reg [AXI_DATA_WIDTH-1:0] pack_data_r;
    reg [AXI_STRB_WIDTH-1:0] pack_strb_r;
    reg [PACK_COUNT_WIDTH-1:0] pack_count_r;
    reg [15:0] data_recv_count;
    wire [15:0] transfer_beat_count = (transfer_count + RAM_WORDS_PER_AXI_BEAT - 1'b1) / RAM_WORDS_PER_AXI_BEAT;

    wire [AXI_DATA_WIDTH-1:0] fifo_data_out;
    wire [AXI_STRB_WIDTH-1:0] fifo_strb_out;
    assign fifo_data_out = fifo_empty ? {AXI_DATA_WIDTH{1'b0}} : fifo_data[fifo_rd_ptr[FIFO_ADDR_WIDTH-1:0]];
    assign fifo_strb_out = fifo_empty ? {AXI_STRB_WIDTH{1'b0}} : fifo_strb[fifo_rd_ptr[FIFO_ADDR_WIDTH-1:0]];
    wire fifo_push_this_cycle = axi_rd_data_vld &&
        ((pack_count_r == RAM_WORDS_PER_AXI_BEAT - 1) || (data_recv_count == transfer_count - 1));
    wire last_w_beat_handshake;
    wire same_cycle_bresp_handshake;
    wire [15:0] data_sent_count_after_beat;
    assign last_w_beat_handshake = (curr_state == DATA_PHASE) && m_axi_wready && wvalid_r && wlast_r;
    assign same_cycle_bresp_handshake = last_w_beat_handshake && m_axi_bvalid && bready_r;
    assign data_sent_count_after_beat = data_sent_count + 16'd1;

    function [AXI_DATA_WIDTH-1:0] pack_ram_word;
        input [AXI_DATA_WIDTH-1:0] current_word;
        input [PACK_COUNT_WIDTH-1:0] slot_idx;
        input [RAM_DATA_WIDTH-1:0] ram_word;
        reg [AXI_DATA_WIDTH-1:0] temp_word;
        begin
            temp_word = current_word;
            temp_word[slot_idx*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] = ram_word;
            pack_ram_word = temp_word;
        end
    endfunction

    function [AXI_STRB_WIDTH-1:0] pack_ram_strb;
        input [AXI_STRB_WIDTH-1:0] current_strb;
        input [PACK_COUNT_WIDTH-1:0] slot_idx;
        reg [AXI_STRB_WIDTH-1:0] temp_strb;
        begin
            temp_strb = current_strb;
            temp_strb[slot_idx*RAM_STRB_WIDTH +: RAM_STRB_WIDTH] = {RAM_STRB_WIDTH{1'b1}};
            pack_ram_strb = temp_strb;
        end
    endfunction
    
    // 将内部寄存器连接到输出端口
    assign m_axi_awid     = awid_r;
    assign m_axi_awaddr   = awaddr_r;
    assign m_axi_awlen    = awlen_r;
    assign m_axi_awsize   = awsize_r;
    assign m_axi_awburst  = awburst_r;
    assign m_axi_awlock   = awlock_r;
    assign m_axi_awcache  = awcache_r;
    assign m_axi_awprot   = awprot_r;
    assign m_axi_awqos    = awqos_r;
    assign m_axi_awregion = awregion_r;
    assign m_axi_awuser   = awuser_r;
    assign m_axi_awvalid  = awvalid_r;
    
    assign m_axi_wdata    = fifo_data_out; // 直接从FIFO读取数据
    assign m_axi_wstrb    = wstrb_r;
    assign m_axi_wlast    = (awlen_r == 0) ? (m_axi_wready && wvalid_r) : wlast_r;
    assign m_axi_wuser    = wuser_r;
    assign m_axi_wvalid   = wvalid_r;
    
    assign m_axi_bready   = bready_r;
    
    assign axi_rd_en      = ram_rd_en_r;
    assign axi_rd_addr    = ram_rd_addr_r;
    
    assign transfer_done   = transfer_done_r;
    assign transfer_status = transfer_status_r;
    
    // 状态机
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            curr_state <= IDLE;
        end else begin
            curr_state <= next_state;
        end
    end
    
    // 状态转换逻辑
    always @(*) begin
        next_state = curr_state;
        
        case (curr_state)
            IDLE: begin
                if (transfer_start)
                    next_state = SETUP;
            end
            
            SETUP: begin
                next_state = ADDR_PHASE;
            end
            
            ADDR_PHASE: begin
                if (m_axi_awready && awvalid_r)
                    next_state = DATA_PHASE;
            end
            
            DATA_PHASE: begin
                if (same_cycle_bresp_handshake) begin
                    if (m_axi_bresp != 2'b00)
                        next_state = ERROR;
                    else if (data_sent_count_after_beat < transfer_beat_count)
                        next_state = ADDR_PHASE;
                    else
                        next_state = COMPLETE;
                end else if (last_w_beat_handshake) begin
                    next_state = RESP_PHASE;
                end
            end
            
            RESP_PHASE: begin
                if (m_axi_bvalid && bready_r) begin
                    if (m_axi_bresp != 2'b00) // 非OKAY响应
                        next_state = ERROR;
                    else if (data_sent_count < transfer_beat_count)
                        next_state = ADDR_PHASE; // 直接进入下一个地址阶段
                    else
                        next_state = COMPLETE;
                end
            end
            
            COMPLETE: begin
                next_state = IDLE;
            end
            
            ERROR: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
     
    // RAM读取控制 FIFO写入控制
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            ram_rd_en_r     <= 1'b0;
            ram_rd_addr_r   <= {AXI_ADDR_WIDTH{1'b0}};
            data_read_count <= 16'd0;
            data_recv_count <= 16'd0;
            fifo_wr_ptr     <= 0;
            pack_data_r     <= {AXI_DATA_WIDTH{1'b0}};
            pack_strb_r     <= {AXI_STRB_WIDTH{1'b0}};
            pack_count_r    <= {PACK_COUNT_WIDTH{1'b0}};
        end else begin
            case (curr_state)
                IDLE: begin
                    ram_rd_en_r     <= 1'b0;
                    ram_rd_addr_r   <= {AXI_ADDR_WIDTH{1'b0}};
                    data_read_count <= 16'd0;
                    data_recv_count <= 16'd0;
                    fifo_wr_ptr     <= 0;
                    pack_data_r     <= {AXI_DATA_WIDTH{1'b0}};
                    pack_strb_r     <= {AXI_STRB_WIDTH{1'b0}};
                    pack_count_r    <= {PACK_COUNT_WIDTH{1'b0}};
                end
                
                SETUP: begin
                    // 重置读计数
                    data_read_count <= 16'd0;
                    data_recv_count <= 16'd0;
                    pack_data_r     <= {AXI_DATA_WIDTH{1'b0}};
                    pack_strb_r     <= {AXI_STRB_WIDTH{1'b0}};
                    pack_count_r    <= {PACK_COUNT_WIDTH{1'b0}};
                    // 开始预读数据
                    ram_rd_en_r   <= 1'b1;
                    ram_rd_addr_r <= ram_base_addr;
                end
                
                ADDR_PHASE, DATA_PHASE: begin
                    // 控制RAM读取
                    if (fifo_almost_full || data_read_count == transfer_count - 1) begin
                        ram_rd_en_r <= 1'b0;
                    end else begin
                        ram_rd_en_r <= 1'b1;
                        ram_rd_addr_r <= ram_base_addr + data_read_count + 1'b1; // 更新读地址
                        data_read_count <= data_read_count + 1'b1;
                    end

                    if (axi_rd_data_vld) begin
                        data_recv_count <= data_recv_count + 1'b1;
                        if ((pack_count_r == RAM_WORDS_PER_AXI_BEAT - 1) || (data_recv_count == transfer_count - 1)) begin
                            fifo_data[fifo_wr_ptr[FIFO_ADDR_WIDTH-1:0]] <=
                                pack_ram_word(pack_data_r, pack_count_r, axi_rd_data[RAM_DATA_WIDTH-1:0]);
                            fifo_strb[fifo_wr_ptr[FIFO_ADDR_WIDTH-1:0]] <=
                                pack_ram_strb(pack_strb_r, pack_count_r);
                            fifo_wr_ptr  <= fifo_wr_ptr + 1'b1;
                            pack_data_r  <= {AXI_DATA_WIDTH{1'b0}};
                            pack_strb_r  <= {AXI_STRB_WIDTH{1'b0}};
                            pack_count_r <= {PACK_COUNT_WIDTH{1'b0}};
                        end else begin
                            pack_data_r  <= pack_ram_word(pack_data_r, pack_count_r, axi_rd_data[RAM_DATA_WIDTH-1:0]);
                            pack_strb_r  <= pack_ram_strb(pack_strb_r, pack_count_r);
                            pack_count_r <= pack_count_r + 1'b1;
                        end
                    end
                end

                COMPLETE: begin
                    data_read_count <= 16'd0;
                    data_recv_count <= 16'd0;
                    pack_data_r     <= {AXI_DATA_WIDTH{1'b0}};
                    pack_strb_r     <= {AXI_STRB_WIDTH{1'b0}};
                    pack_count_r    <= {PACK_COUNT_WIDTH{1'b0}};
                end
                
                default: begin
                    ram_rd_en_r <= 1'b0;
                    if (axi_rd_data_vld) begin
                        data_recv_count <= data_recv_count + 1'b1;
                        if ((pack_count_r == RAM_WORDS_PER_AXI_BEAT - 1) || (data_recv_count == transfer_count - 1)) begin
                            fifo_data[fifo_wr_ptr[FIFO_ADDR_WIDTH-1:0]] <=
                                pack_ram_word(pack_data_r, pack_count_r, axi_rd_data[RAM_DATA_WIDTH-1:0]);
                            fifo_strb[fifo_wr_ptr[FIFO_ADDR_WIDTH-1:0]] <=
                                pack_ram_strb(pack_strb_r, pack_count_r);
                            fifo_wr_ptr  <= fifo_wr_ptr + 1'b1;
                            pack_data_r  <= {AXI_DATA_WIDTH{1'b0}};
                            pack_strb_r  <= {AXI_STRB_WIDTH{1'b0}};
                            pack_count_r <= {PACK_COUNT_WIDTH{1'b0}};
                        end else begin
                            pack_data_r  <= pack_ram_word(pack_data_r, pack_count_r, axi_rd_data[RAM_DATA_WIDTH-1:0]);
                            pack_strb_r  <= pack_ram_strb(pack_strb_r, pack_count_r);
                            pack_count_r <= pack_count_r + 1'b1;
                        end
                    end
                end
            endcase
        end
    end
    
    // AXI写地址通道控制
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            awid_r     <= {AXI_ID_WIDTH{1'b0}};
            awaddr_r   <= {AXI_ADDR_WIDTH{1'b0}};
            awlen_r    <= 8'd0;
            awsize_r   <= 3'b000;
            awburst_r  <= 2'b00;
            awlock_r   <= 1'b0;
            awcache_r  <= 4'b0000;
            awprot_r   <= 3'b000;
            awqos_r    <= 4'd0;
            awregion_r <= 4'd0;
            awuser_r   <= {AXI_AWUSER_WIDTH{1'b0}};
            awvalid_r  <= 1'b0;
            current_burst_len <= 8'd0;
            current_axi_addr <= {AXI_ADDR_WIDTH{1'b0}};
        end else begin
            // 写地址握手完成后清除有效标志
            if (m_axi_awready && awvalid_r) begin
                awvalid_r <= 1'b0;
            end
            
            case (curr_state)
                IDLE: begin
                    awid_r     <= {AXI_ID_WIDTH{1'b0}};
                    awaddr_r   <= {AXI_ADDR_WIDTH{1'b0}};
                    awlen_r    <= 8'd0;
                    awsize_r   <= 3'b000;
                    awburst_r  <= 2'b00;
                    awlock_r   <= 1'b0;
                    awcache_r  <= 4'b0000;
                    awprot_r   <= 3'b000;
                    awqos_r    <= 4'd0;
                    awregion_r <= 4'd0;
                    awuser_r   <= {AXI_AWUSER_WIDTH{1'b0}};
                    awvalid_r  <= 1'b0;
                    current_burst_len <= 8'd0;
                    current_axi_addr <= {AXI_ADDR_WIDTH{1'b0}};
                end

                SETUP: begin
                    if (transfer_beat_count <= MAX_BURST_LEN + 1)
                        current_burst_len <= transfer_beat_count - 1'b1; // len=传输次数-1
                    else
                        current_burst_len <= MAX_BURST_LEN;
                    
                    current_axi_addr <= axi_target_addr;
                end

                ADDR_PHASE: begin
                    if (!awvalid_r) begin
                        awid_r     <= {AXI_ID_WIDTH{1'b0}};
                        awaddr_r   <= current_axi_addr;
                        awlen_r    <= current_burst_len;
                        awsize_r   <= $clog2(AXI_DATA_WIDTH/8);
                        awburst_r  <= 2'b01;  // INCR
                        awlock_r   <= 1'b0;   // 正常访问
                        awcache_r  <= 4'b0010; // 非缓存
                        awprot_r   <= 3'b000; // 数据访问，安全，非特权
                        awvalid_r  <= 1'b1;
                    end
                end
                
                RESP_PHASE: begin
                    // 如果收到响应，准备下一次突发传输的参数
                    if (m_axi_bvalid && bready_r && data_sent_count < transfer_beat_count) begin
                        // 计算下一次突发长度
                        if (transfer_beat_count - data_sent_count <= MAX_BURST_LEN + 1)
                            current_burst_len <= transfer_beat_count - data_sent_count - 1'b1;
                        else
                            current_burst_len <= MAX_BURST_LEN;
                        
                        // 更新AXI地址，以字节为单位
                        current_axi_addr <= axi_target_addr + (data_sent_count << $clog2(AXI_DATA_WIDTH/8));
                    end
                end

                DATA_PHASE: begin
                    if (same_cycle_bresp_handshake && m_axi_bresp == 2'b00 && data_sent_count_after_beat < transfer_beat_count) begin
                        if (transfer_beat_count - data_sent_count_after_beat <= MAX_BURST_LEN + 1)
                            current_burst_len <= transfer_beat_count - data_sent_count_after_beat - 1'b1;
                        else
                            current_burst_len <= MAX_BURST_LEN;

                        current_axi_addr <= axi_target_addr + (data_sent_count_after_beat << $clog2(AXI_DATA_WIDTH/8));
                    end
                end
                
                default: begin
                    // 其他状态不改变地址通道信号
                end
            endcase
        end
    end
    
    // AXI写数据通道控制
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            wvalid_r <= 1'b0;
            wlast_r <= 1'b0;
            wstrb_r <= {AXI_STRB_WIDTH{1'b0}};
            wuser_r <= {AXI_WUSER_WIDTH{1'b0}};
            burst_data_count <= 8'd0;
            data_sent_count <= 16'd0;
            fifo_rd_ptr <= 0;
        end else begin
            case (curr_state)
                IDLE, SETUP: begin
                    wvalid_r <= 1'b0;
                    wlast_r <= 1'b0;
                    wstrb_r <= {AXI_STRB_WIDTH{1'b0}};
                    burst_data_count <= 8'd0;
                    data_sent_count  <= 16'd0;
                    fifo_rd_ptr <= 0;
                end
                
                DATA_PHASE: begin
                    if (!fifo_empty) begin
                        wstrb_r <= fifo_strb_out;
                        wvalid_r <= 1'b1;
                        if (burst_data_count == awlen_r) begin
                            wlast_r <= 1'b1;
                        end

                        if (m_axi_wready && wvalid_r) begin
                            fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
                            data_sent_count <= data_sent_count + 1'b1;
                            
                            if (wlast_r) begin
                                wlast_r <= 1'b0;
                                burst_data_count <= 8'd0;
                                wvalid_r <= 1'b0;
                                
                            end else begin
                                burst_data_count <= burst_data_count + 1'b1;
                                
                                // 预先设置下一个last信号
                                if (burst_data_count + 1 == awlen_r) begin
                                    wlast_r <= 1'b1;
                                end

                                if ((fifo_count == 1) && !fifo_push_this_cycle) begin
                                    wvalid_r <= 1'b0;
                                end
                            end
                        end
                    end else begin
                        // FIFO为空时，清除有效标志
                        wstrb_r <= {AXI_STRB_WIDTH{1'b0}};
                        wvalid_r <= 1'b0;
                    end
                end

                COMPLETE: begin
                    data_sent_count  <= 16'd0;
                    wvalid_r <= 1'b0;
                    wlast_r <= 1'b0;
                    wstrb_r <= {AXI_STRB_WIDTH{1'b0}};
                end
                
                default: begin
                    wvalid_r <= 1'b0;
                    wlast_r <= 1'b0;
                    wstrb_r <= {AXI_STRB_WIDTH{1'b0}};
                end
            endcase
        end
    end
    
    // AXI写响应通道控制
    // Keep BREADY asserted once data is flowing so we cannot miss a write
    // response that comes back in the same cycle as the final W beat.
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            bready_r <= 1'b0;
        end else begin
            if (curr_state == DATA_PHASE || curr_state == RESP_PHASE) begin
                bready_r <= 1'b1;
            end else begin
                bready_r <= 1'b0;
            end
        end
    end
    
    // 传输状态和完成标志管理
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            transfer_done_r <= 1'b0;
            transfer_status_r <= 2'b00;
        end else begin
            case (curr_state)
                IDLE: begin
                    transfer_done_r <= 1'b0;
                    transfer_status_r <= 2'b00; // 空闲
                end
                
                SETUP, ADDR_PHASE, DATA_PHASE, RESP_PHASE: begin
                    transfer_done_r <= 1'b0;
                    transfer_status_r <= 2'b01; // 传输中
                end
                
                COMPLETE: begin
                    transfer_done_r <= 1'b1;
                    transfer_status_r <= 2'b10; // 成功
                end
                
                ERROR: begin
                    transfer_done_r <= 1'b1;
                    transfer_status_r <= 2'b11; // 错误
                end
            endcase
        end
    end

endmodule
