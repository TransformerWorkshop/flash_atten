module c_matrix_adder #(
    parameter PE_SIZE    = 16,
    parameter RAM_DATA_WIDTH = 64,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 5,
    parameter PREC_WIDTH = 4
)(
    input                               clk,
    input                               rst_n,
    input      [DATA_WIDTH*PE_SIZE-1:0] PE_data,
    input      [DATA_WIDTH*PE_SIZE-1:0] RAM_C_data,
    input                               done_systolic,
    input                               done_fifoC,
    input                               done_transfer,
    input      [PREC_WIDTH-1:0]         precision_mode,
    input      [7:0]                    matrix_m,
    input      [7:0]                    matrix_n,
    output reg [RAM_DATA_WIDTH*PE_SIZE-1:0]wr_data,
    output reg                          rd_en,
    output reg                          wr_en,
    output reg [ADDR_WIDTH-1:0]         wr_addr,
    output reg [(RAM_DATA_WIDTH/8)-1:0] wr_strb,
    output reg                          done,//计算结束信号，用于通知AXI_MASTER模块
    output wire [1:0]                   dbg_state,
    output wire [15:0]                  dbg_cnt,
    output wire [7:0]                   dbg_active_rows,
    output wire [15:0]                  dbg_total_output_cycles,
    output wire [15:0]                  dbg_write_start_cycle
);

    localparam IDLE    = 0;
    localparam CAL     = 1;
    localparam DONE    = 2;
    localparam PENDING = 3;

    localparam DELAY_INT = 2;//寄存器级数
    localparam DELAY_FP  = 5;
    localparam LOG2_PE_SIZE = $clog2(PE_SIZE);
    localparam RAM_STRB_WIDTH = RAM_DATA_WIDTH / 8;
    localparam HALFWORDS_PER_RAM_WORD = RAM_DATA_WIDTH / 16;
    localparam INT32S_PER_RAM_WORD = RAM_DATA_WIDTH / 32;

    localparam INT4     = 4'd0;
    localparam INT8     = 4'd1;
    localparam INT4_32  = 4'd2;
    localparam INT8_32  = 4'd3;

    reg  [1:0]                      curr_state;
    reg  [1:0]                      next_state;

    reg  [15:0]                     cnt;//计数输入的数据
    reg                             first_to_CAL;
    reg  [DATA_WIDTH*PE_SIZE*2-1:0] i_data;
    wire [  DATA_WIDTH*PE_SIZE-1:0] o_data;

    reg                             done_systolic_reg;
    reg                             done_fifoC_reg;
    reg                             done_transfer_reg;
    wire                            finish;
    wire                            int_wire;

    reg [PREC_WIDTH-1:0]            precision_mode_reg;
    reg [$clog2(HALFWORDS_PER_RAM_WORD)-1:0] byte_select_cnt;
    reg [7:0]                       matrix_row_groups;
    reg [7:0]                       active_rows;
    reg [7:0]                       active_cols;
    reg [15:0]                      total_output_cycles;
    reg [15:0]                      write_start_cycle;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            precision_mode_reg <= {PREC_WIDTH{1'b0}};
        end else begin
            precision_mode_reg <= precision_mode;
        end
    end

    always @(*) begin
        matrix_row_groups = (active_rows + PE_SIZE - 1) >> LOG2_PE_SIZE;
        if (matrix_row_groups == 0)
            matrix_row_groups = 8'd1;
        total_output_cycles = {8'd0, matrix_row_groups} * {8'd0, active_cols};
        write_start_cycle = int_wire ? (DELAY_INT + 1) : (DELAY_FP + 1);
    end

    wire [8:0] mode_onehot = 1 << precision_mode_reg;

    assign int_wire = |{mode_onehot[INT4],mode_onehot[INT8],mode_onehot[INT4_32],mode_onehot[INT8_32]};//计算类型为int
    assign finish = (cnt == (int_wire ? (total_output_cycles + DELAY_INT + 1) : (total_output_cycles + DELAY_FP + 1))) ? 1'b1 : 1'b0;
    // 完成时刻为总输出拍数加上计算流水延时

    integer i;
    always @(*) begin
        for (i=0;i<PE_SIZE;i=i+1) begin
            i_data[i*DATA_WIDTH*2 +: DATA_WIDTH*2] = {PE_data[i*DATA_WIDTH +: DATA_WIDTH],RAM_C_data[i*DATA_WIDTH +: DATA_WIDTH]};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || curr_state == CAL) begin
            done_systolic_reg <= 1'b0;
        end else if (done_systolic) begin
            done_systolic_reg <= 1'b1;
        end else begin
            done_systolic_reg <= done_systolic_reg;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || curr_state == CAL) begin
            done_fifoC_reg <= 1'b0;
        end else if (done_fifoC) begin
            done_fifoC_reg <= 1'b1;
        end else begin
            done_fifoC_reg <= done_fifoC_reg;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
        end else begin
            curr_state <= next_state;
        end
    end

    always @(*) begin
        case(curr_state)
            IDLE:begin
                if (done_systolic_reg && done_fifoC_reg) begin
                    next_state = CAL;
                end else begin
                    next_state = IDLE;
                end
            end
            CAL: begin
                if (finish)begin
                    next_state = DONE;
                end else begin
                    next_state = CAL;
                end
            end
            DONE: next_state = PENDING; // DONE状态不再使用，直接跳转到PENDING
            PENDING :begin
                if (done_transfer) begin
                    next_state = IDLE;
                end else begin
                    next_state = PENDING;
                end
            end
            default : next_state = IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)begin
            cnt <= 0;
            active_rows <= PE_SIZE[7:0];
            active_cols <= PE_SIZE[7:0];
            byte_select_cnt <= 0;
            rd_en <= 0;
            wr_en <= 0;
            wr_addr <= 0;
            // wr_strb <= 8'h00;  // 初始化字节使能为全0
            done <= 0;
            first_to_CAL <= 1;
        end else begin
            case(next_state)
                IDLE: begin
                    byte_select_cnt <= 0;
                    first_to_CAL <= 1;
                    done <= 0;
                    cnt <= 0;
                    wr_addr <= 0;
                    wr_en <= 0;
                    rd_en <= 0;
                    active_rows <= matrix_m;
                    active_cols <= matrix_n;
                end
                CAL: begin
                    cnt <= cnt + 1;

                    // 控制读使能
                    if (cnt >= total_output_cycles) begin
                        rd_en <= 0;
                    end else begin
                        rd_en <= 1;
                    end

                    // 控制写使能和地址生成
                    if (cnt >= write_start_cycle && cnt < (write_start_cycle + total_output_cycles)) begin
                        wr_en <= 1;
                        
                        // 精度模式判断
                        case(precision_mode_reg)
                            INT4: begin  // 16位模式
                                // 每写满一个RAM字后增加地址
                                if (first_to_CAL)begin
                                    byte_select_cnt <= 0;
                                    first_to_CAL <= 0;
                                end
                                else if (byte_select_cnt == HALFWORDS_PER_RAM_WORD - 1'b1) begin
                                    wr_addr <= wr_addr + 1;
                                    byte_select_cnt <= 0;
                                end else begin
                                    byte_select_cnt <= byte_select_cnt + 1;
                                end
                            end
                            default: begin  // 32位及其他模式
                                // 每写满一个RAM字后增加地址
                                if (first_to_CAL)begin
                                    byte_select_cnt <= 0;
                                    first_to_CAL <= 0;
                                end
                                else if (byte_select_cnt == INT32S_PER_RAM_WORD - 1'b1) begin
                                    wr_addr <= wr_addr + 1;
                                    byte_select_cnt <= 0;
                                end else begin
                                    byte_select_cnt <= byte_select_cnt + 1;
                                end
                            end
                        endcase
                        
                    end else begin
                        wr_en <= 0;
                    end
                end
                DONE:begin
                    done <= 1;
                end
                PENDING: begin
                    cnt <= 0;
                    byte_select_cnt <= 0;
                    rd_en <= 0;
                    wr_en <= 0;
                    wr_addr <= 0;
                    done <= 0;
                end
                default: begin
                    cnt <= 0;
                    byte_select_cnt <= 0;
                    rd_en <= 0;
                    wr_en <= 0;
                    wr_addr <= 0;
                    done <= 0;
                end
            endcase 
        end
    end

    always @(*) begin
        wr_strb = {RAM_STRB_WIDTH{1'b0}};
        case (precision_mode_reg)
            INT4: begin
                wr_strb = {{(RAM_STRB_WIDTH-2){1'b0}}, 2'b11} << (byte_select_cnt * 2);
            end
            default: begin
                wr_strb = {{(RAM_STRB_WIDTH-4){1'b0}}, 4'hF} << (byte_select_cnt * 4);
            end
        endcase
    end

    always @(*) begin
        wr_data = {(RAM_DATA_WIDTH*PE_SIZE){1'b0}};
        case(precision_mode_reg)
            INT4: begin
                for(i=0;i<PE_SIZE;i=i+1) begin
                    wr_data[i*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] =
                        {{(RAM_DATA_WIDTH-DATA_WIDTH){1'b0}}, o_data[i*DATA_WIDTH +: DATA_WIDTH]} << (byte_select_cnt * 16);
                end
            end
            default: begin
                for(i=0;i<PE_SIZE;i=i+1) begin
                    wr_data[i*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] =
                        {{(RAM_DATA_WIDTH-DATA_WIDTH){1'b0}}, o_data[i*DATA_WIDTH +: DATA_WIDTH]} << (byte_select_cnt * 32);
                end
            end
        endcase
    end

    assign dbg_state = curr_state;
    assign dbg_cnt = cnt;
    assign dbg_active_rows = active_rows;
    assign dbg_total_output_cycles = total_output_cycles;
    assign dbg_write_start_cycle = write_start_cycle;

    adder_array_8 #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_SIZE(PE_SIZE),
        .PREC_WIDTH(PREC_WIDTH)
    ) adder_array_8_inst (
        .clk            (clk),              
        .precision_mode (precision_mode_reg),
        .num_in         (i_data),//左侧开始，每两个数据相加，结果从输出的最左侧开始排列
        .num_out        (o_data)
    );
endmodule
