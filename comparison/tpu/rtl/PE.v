/*
1. 每四拍生成一个input_valid，control输入的一瞬间拉高valid，并写一个cnt_data_num（用于计算传递数）计数器和cnt4（用于产生valid）
2. output_valid作为写使能，每当其拉高，address+1
*/
module PE #(
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4
    )(
    input                              clk,
    input                              rst_n,
    input         [PREC_WIDTH-1:0]     precision_mode_left,
    input         [DATA_WIDTH-1:0]     left,
    input         [DATA_WIDTH-1:0]     up,
    input         [1:0]                control_up,
    input         [1:0]                control_left,
    input         [DATA_WIDTH*8-1:0]   i_data,

    output  reg   [DATA_WIDTH-1:0]     right,
    output  reg   [DATA_WIDTH-1:0]     down,
    output        [DATA_WIDTH*8-1:0]   o_data,
    output  reg                        data_valid,
    output        [1:0]                control_down,//the control of next PE
    output  reg   [1:0]                control_right,
    output  reg   [PREC_WIDTH-1:0]     precision_mode_right
);
    localparam IDLE       = 0;
    localparam WAIT       = 1;
    localparam STORE      = 2;
    localparam STORE_FP32 = 3;

    localparam DELAY_FP   = 4;//寄存器级数+1
    localparam DELAY_FP32 = 8;
    localparam DELAY_INT  = 3;

    localparam INT4     = 4'd0;
    localparam INT8     = 4'd1;
    localparam INT4_32  = 4'd2;
    localparam INT8_32  = 4'd3;
    localparam FP32     = 4'd6;

    reg                 [1:0]                curr_state;
    reg                 [1:0]                next_state;
    reg                                      is_first_store;
    wire                                     int_wire       ;

    wire                [DATA_WIDTH-1:0]     result_sel;
    reg                                      wr_en,wr_en_1; //打一拍
    wire                                     input_valid;
    wire                                     output_valid;
    wire                [DATA_WIDTH-1:0]     product;

    reg                 [2:0]                cnt_delay;//计数首次计算演示
    reg                 [3:0]                cnt_end;//计数结束
    reg                 [1:0]                cnt_input_valid;//计数给出valid的时间
    reg                 [2:0]                address;
    reg                 [DATA_WIDTH-1:0]     mem     [0:7];


assign o_data = (data_valid)?{mem[0],mem[1],mem[2],mem[3],mem[4],mem[5],mem[6],mem[7]}:i_data;
assign input_valid = (next_state==STORE_FP32 && cnt_input_valid==0);

wire [8:0] mode_onehot = 1 << precision_mode_left;
assign int_wire = | {mode_onehot[INT4],
                mode_onehot[INT8],
                mode_onehot[INT4_32],
                mode_onehot[INT8_32]};
assign fp32 = mode_onehot[FP32];

always @(*) begin
    case(curr_state)
        IDLE: begin
            if ((control_left==1 || control_up==1)&&fp32) begin
                next_state = STORE_FP32;
            end else if (control_left==1 || control_up==1)begin
                next_state = WAIT;
            end else begin
                next_state = IDLE;
            end
        end
        WAIT: begin
            if ((int_wire && cnt_delay==DELAY_INT)||(!int_wire && cnt_delay==DELAY_FP)) begin
                next_state = STORE;
            end else begin
                next_state = WAIT;
            end 
        end
        STORE: begin
            if ((int_wire && cnt_end==DELAY_INT)||(!int_wire && cnt_end==DELAY_FP)) begin
                next_state = IDLE;
            end else begin
                next_state = STORE;
            end
        end
        STORE_FP32: begin
            if (cnt_end==DELAY_FP32) begin
                next_state = IDLE;
            end else begin
                next_state = STORE_FP32;
            end
        end
        default: next_state = IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        curr_state <= IDLE;
    end else begin
        curr_state <= next_state;
    end
end

always @(posedge clk ) begin
    case(next_state)
    IDLE: begin
        cnt_delay <= 0;
        address <= 0;
        wr_en <= 0;
        cnt_end <= 0;
        data_valid <= 0;
        is_first_store <= 1;
        cnt_input_valid <= 0;
    end
    WAIT: begin
        cnt_delay <= cnt_delay + 1;
        wr_en <= 0;
    end
    STORE: begin
        wr_en <= 1;

        if (is_first_store) begin
            address <= 0;
            is_first_store <= 0;
        end else begin
            address <= address + 1;
            is_first_store <= is_first_store;
        end

        if (address == 7) begin
            data_valid <= 1;
        end else begin
            data_valid <= 0;
        end

        if ((control_left==2 || control_up==2)||cnt_end!=0) begin
            cnt_end <= cnt_end + 1;
        end
    end
    STORE_FP32: begin
        wr_en_1 <= output_valid;
        wr_en <= wr_en_1; //打一拍
        cnt_input_valid <= cnt_input_valid + 1;

        if (wr_en) begin
            address <= address + 1;
        end

        if (address == 7 && wr_en) begin
            data_valid <= 1;
        end else begin
            data_valid <= 0;
        end

        if ((control_left==2 || control_up==2)||cnt_end!=0) begin
            cnt_end <= cnt_end + 1;
        end
    end
    default:begin
        cnt_delay <= 0;
        address <= 0;
        data_valid <= 0;
        wr_en <= 0;
        cnt_end <= 0;
    end
    endcase
end 

//data transfer
always @(posedge clk) begin
    right  <=left;
    down   <=up;
    precision_mode_right <= precision_mode_left;
end

//store data
integer i;
always @(posedge clk) begin
    if (wr_en) begin
        mem[address] <= result_sel;
    end else begin
        for (i=0;i<8;i=i+1) begin
            mem[i] <= mem[i];
        end
    end
end


// control signal transfer
assign control_down = control_right;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        control_right <= 0;
    end else if (control_up==1 || control_left==1)begin
        control_right <= 1;
    end else if (control_up==2 || control_left==2)begin
        control_right <= 2;
    end else begin
        control_right <= 0;
    end
end

multi_precision_multiplier #(
    .DATA_WIDTH(32),
    .PREC_WIDTH(PREC_WIDTH)
)u_multi_precision_multiplier(
    .clk             (clk)           ,
    .rst_n           (rst_n)         ,
    .num1            (up)            ,
    .num2            (left)          ,
    .input_valid     (input_valid)   ,
    .output_valid    (output_valid)  ,
    .precision_mode  (precision_mode_left),
    .product         (product)        
);

precision_convert #(
    .PREC_WIDTH(PREC_WIDTH)
)u_precision_convert (
    .clk            (clk),
    .data           (product),
    .precision_mode (precision_mode_left),
    .data_output    (result_sel)
);

endmodule
