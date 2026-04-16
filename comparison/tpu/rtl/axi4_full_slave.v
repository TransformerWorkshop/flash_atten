module axi4_full_slave #(
    parameter AXI_ID_WIDTH     = 4  ,
    parameter AXI_ADDR_WIDTH   = 32 ,
    parameter AXI_DATA_WIDTH   = 32 ,
    parameter AXI_AWUSER_WIDTH = 8  ,
    parameter AXI_WUSER_WIDTH  = 8  ,
    parameter AXI_BUSER_WIDTH  = 8
) (
    // Global signals
    input wire                               s_axi_aclk       ,
    input wire                               s_axi_aresetn    ,

    // Write address channel
    input  wire [        AXI_ID_WIDTH-1:0]   s_axi_awid       ,
    input  wire [      AXI_ADDR_WIDTH-1:0]   s_axi_awaddr     ,
    input  wire [                     7:0]   s_axi_awlen      ,
    input  wire [                     2:0]   s_axi_awsize     ,
    input  wire [                     1:0]   s_axi_awburst    ,
    input  wire                              s_axi_awlock     ,
    input  wire [                     3:0]   s_axi_awcache    ,
    input  wire [                     2:0]   s_axi_awprot     ,
    input  wire [                     3:0]   s_axi_awqos      ,
    input  wire [                     3:0]   s_axi_awregion   ,
    input  wire [    AXI_AWUSER_WIDTH-1:0]   s_axi_awuser     ,
    input  wire                              s_axi_awvalid    ,
    output wire                              s_axi_awready    ,

    // Write data channel
    input  wire [        AXI_DATA_WIDTH-1:0] s_axi_wdata      ,
    input  wire [    (AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb      ,
    input  wire                              s_axi_wlast      ,
    input  wire [       AXI_WUSER_WIDTH-1:0] s_axi_wuser      ,
    input  wire                              s_axi_wvalid     ,
    output wire                              s_axi_wready     ,

    // Write response channel
    output wire [       AXI_ID_WIDTH-1:0]    s_axi_bid        ,
    output wire [                    1:0]    s_axi_bresp      ,
    output wire [    AXI_BUSER_WIDTH-1:0]    s_axi_buser      ,
    output wire                              s_axi_bvalid     ,
    input  wire                              s_axi_bready     ,

    // RAM interface outputs
    output wire                              ram_wr_en        ,
    output wire [        AXI_ADDR_WIDTH-1:0] ram_wr_addr      ,
    output wire [        AXI_DATA_WIDTH-1:0] ram_wr_data      ,
    output wire [    (AXI_DATA_WIDTH/8)-1:0] ram_wr_strb      ,
    output wire                              dbg_short_burst_event,
    output wire [                     7:0]   dbg_short_burst_missing_beats,
    
    // RAM写就绪信号
    input  wire                              ram_wr_ready
);

    // AXI4 状态定义
    localparam [1:0] IDLE   = 2'b00;
    localparam [1:0] BURST  = 2'b01;
    localparam [1:0] RESP   = 2'b10;

    // Burst类型定义
    localparam [1:0] BURST_FIXED = 2'b00;
    localparam [1:0] BURST_INCR  = 2'b01;
    localparam [1:0] BURST_WRAP  = 2'b10;

    // 写地址通道寄存器
    reg [        AXI_ADDR_WIDTH-1:0] axi_awaddr         ;
    reg [                       7:0] axi_awlen          ;
    reg [                       1:0] axi_awburst        ;
    reg [                       2:0] axi_awsize         ;
    reg [          AXI_ID_WIDTH-1:0] axi_awid           ;
    reg                              axi_awready        ;

    // 写数据通道寄存器
    reg                              axi_wready         ;

    // 写响应通道寄存器
    reg [          AXI_ID_WIDTH-1:0] axi_bid            ;
    reg [                       1:0] axi_bresp          ;
    reg                              axi_bvalid         ;

    // 内部信号
    reg [                       1:0] write_state        ;
    reg [                       7:0] write_burst_counter;
    reg [        AXI_ADDR_WIDTH-1:0] burst_write_address;

    // RAM接口信号
    reg                              ram_write_en_r     ;
    reg [        AXI_ADDR_WIDTH-1:0] ram_write_addr_r   ;
    reg [        AXI_DATA_WIDTH-1:0] ram_write_data_r   ;
    reg [    (AXI_DATA_WIDTH/8)-1:0] ram_write_strb_r   ;
    reg                              dbg_short_burst_event_r;
    reg [                       7:0] dbg_short_burst_missing_beats_r;


    // AXI接口赋值
    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bid     = axi_bid;
    assign s_axi_bresp   = axi_bresp;
    assign s_axi_buser   = {AXI_BUSER_WIDTH{1'b0}};
    assign s_axi_bvalid  = axi_bvalid;

    // RAM接口赋值
    assign ram_wr_en     = ram_write_en_r;
    assign ram_wr_addr   = ram_write_addr_r;
    assign ram_wr_data   = ram_write_data_r;
    assign ram_wr_strb   = ram_write_strb_r;
    assign dbg_short_burst_event = dbg_short_burst_event_r;
    assign dbg_short_burst_missing_beats = dbg_short_burst_missing_beats_r;

    // 根据突发大小计算字节偏移
    function [31:0] get_byte_offset;
        input [2:0] axsize;
        begin
            case (axsize)
                3'b000:  get_byte_offset = 32'h00000001;  // 1 byte
                3'b001:  get_byte_offset = 32'h00000002;  // 2 bytes
                3'b010:  get_byte_offset = 32'h00000004;  // 4 bytes
                3'b011:  get_byte_offset = 32'h00000008;  // 8 bytes
                3'b100:  get_byte_offset = 32'h00000010;  // 16 bytes
                3'b101:  get_byte_offset = 32'h00000020;  // 32 bytes
                3'b110:  get_byte_offset = 32'h00000040;  // 64 bytes
                3'b111:  get_byte_offset = 32'h00000080;  // 128 bytes
                default: get_byte_offset = 32'h00000001;
            endcase
        end
    endfunction

    // 根据突发类型计算下一个地址
    function [AXI_ADDR_WIDTH-1:0] get_next_addr;
        input [AXI_ADDR_WIDTH-1:0] addr;
        input [1:0] burst_type;
        input [2:0] axsize;
        input [7:0] len;
        reg [                  31:0] byte_offset;
        reg [AXI_ADDR_WIDTH-1:0] mask;
        begin
            byte_offset = get_byte_offset(axsize);

            case (burst_type)
                BURST_FIXED:  // FIXED burst
                get_next_addr = addr;

                BURST_INCR:  // INCR burst
                get_next_addr = addr + byte_offset;

                BURST_WRAP: begin  // WRAP burst
                    mask = (byte_offset * (len + 1)) - 1;
                    get_next_addr = (addr & ~mask) | ((addr + byte_offset) & mask);
                end

                default:  // 默认为INCR
                get_next_addr = addr + byte_offset;
            endcase
        end
    endfunction

    // 写地址通道逻辑
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            axi_awready         <= 1'b0;
            axi_awaddr          <= 0;
            axi_awlen           <= 0;
            axi_awburst         <= 0;
            axi_awsize          <= 0;
            axi_awid            <= 0;
            write_burst_counter <= 0;
            burst_write_address <= 0;

            axi_wready          <= 1'b0;  // 复位时不接受写数据
            ram_write_en_r      <= 1'b0;
            ram_write_addr_r    <= 0;
            ram_write_data_r    <= 0;
            ram_write_strb_r    <= 0;
            dbg_short_burst_event_r <= 1'b0;
            dbg_short_burst_missing_beats_r <= 8'd0;

            axi_bvalid          <= 1'b0;
            axi_bresp           <= 2'b00;  // OKAY
            axi_bid             <= 0;

            write_state         <= IDLE;
        end else begin
            dbg_short_burst_event_r <= 1'b0;
            case (write_state)
                IDLE: begin
                    write_burst_counter <= 0;
                    ram_write_en_r      <= 1'b0;
                    
                    if (s_axi_awvalid && axi_awready) begin
                        axi_awaddr          <= s_axi_awaddr;
                        axi_awlen           <= s_axi_awlen;
                        axi_awburst         <= s_axi_awburst;
                        axi_awsize          <= s_axi_awsize;
                        axi_awid            <= s_axi_awid;
                        burst_write_address <= s_axi_awaddr;
                        write_state         <= BURST;
                        axi_awready         <= 1'b0;
                    end else begin
                        axi_awready <= ram_wr_ready;
                        axi_wready  <= 1'b0        ;
                    end
                end
                
                BURST: begin
                    axi_awready <= 1'b0;
                    ram_write_en_r <= 1'b0;
                    
                    if (s_axi_wvalid && axi_wready) begin
                        ram_write_en_r   <= 1'b1;
                        ram_write_addr_r <= burst_write_address;
                        ram_write_data_r <= s_axi_wdata;
                        ram_write_strb_r <= s_axi_wstrb;
                        
                        if (!s_axi_wlast) begin
                            axi_wready <= 1'b1;
                            burst_write_address <= get_next_addr(burst_write_address, axi_awburst, axi_awsize, axi_awlen);
                            write_burst_counter <= write_burst_counter + 1;
                        end else begin
                            // Drop WREADY for the cycle after WLAST so the next
                            // burst's first beat cannot handshake while we are
                            // already transitioning into RESP.
                            axi_wready <= 1'b0;
                        end
                    end else begin
                        axi_wready <= 1'b1;
                    end

                    // 当收到最后一个数据时，进入响应状态
                    if (s_axi_wvalid && axi_wready && s_axi_wlast) begin
                        if (write_burst_counter != axi_awlen) begin
                            dbg_short_burst_event_r <= 1'b1;
                            dbg_short_burst_missing_beats_r <= axi_awlen - write_burst_counter;
                        end
                        write_state <= RESP;
                    end

                end
                
                RESP: begin
                    axi_awready     <= 1'b0;
                    axi_wready      <= 1'b0;
                    ram_write_en_r  <= 1'b0;

                    if (!axi_bvalid) begin
                        axi_bvalid  <= 1'b1;
                        axi_bresp   <= 2'b00;  // OKAY
                        axi_bid     <= axi_awid;
                    end else if (axi_bvalid && s_axi_bready) begin
                        axi_bvalid  <= 1'b0;
                        write_state <= IDLE;
                    end

                end
                
                default: begin
                    write_state      <= IDLE;
                    axi_awready      <= 1'b0;
                    axi_wready       <= 1'b0;
                    ram_write_en_r   <= 1'b0;
                end
            endcase
        end
    end

endmodule
