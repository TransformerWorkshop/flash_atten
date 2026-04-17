module PE_row#(
    parameter PE_SIZE    = 16,
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4
)(
    input                           clk,
    input                           rst_n,
    input  [7:0]                    matrix_n,
    input  [DATA_WIDTH-1:0]         left,
    input  [DATA_WIDTH*PE_SIZE-1:0] up_all,
    input  [1:0]                    control_left,
    input  [2*PE_SIZE-1:0]          control_up_all,
    input  [PREC_WIDTH-1:0]         precision_mode,
    output [DATA_WIDTH*PE_SIZE-1:0] down_all,
    output [PE_SIZE*2-1:0]          control_down_all,
    output [DATA_WIDTH*PE_SIZE-1:0] data_selected,
    output                          data_valid
);

wire [DATA_WIDTH-1:0]    right         [0:PE_SIZE-1];
wire [1:0]               control_right [0:PE_SIZE-1];
wire [1:0]               control_down  [0:PE_SIZE-1];
wire [DATA_WIDTH*PE_SIZE-1:0] data          [0:PE_SIZE-1];
wire [PE_SIZE-1:0]       data_valid_row                 ;
wire [PREC_WIDTH-1:0]    precision_mode_right  [0:PE_SIZE-1];

assign data_valid = |data_valid_row;

genvar i;  // 生成变量
generate
    for (i = 0; i < PE_SIZE; i = i + 1) begin : pe
        if (i==0)begin
            PE #(
                .PE_SIZE    (PE_SIZE),
                .DATA_WIDTH (DATA_WIDTH),
                .PREC_WIDTH (PREC_WIDTH)
            ) PE_inst (
                .clk                 (clk),
                .rst_n               (rst_n),
                .precision_mode_left (precision_mode),
                .left                ((i < matrix_n) ? left : {DATA_WIDTH{1'b0}}),
                .up                  ((i < matrix_n) ? up_all[i*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}}),
                .right               (right[i]),
                .down                (down_all[i*DATA_WIDTH +: DATA_WIDTH]),
                .o_data              (data_selected),
                .data_valid          (data_valid_row[i]),
                .i_data              (((i + 1) < matrix_n) ? data[i] : {(DATA_WIDTH*PE_SIZE){1'b0}}),
                .control_up          ((i < matrix_n) ? control_up_all[i*2 +: 2] : 2'b0),
                .control_left        ((i < matrix_n) ? control_left : 2'b0),
                .control_down        (control_down_all[i*2 +: 2]),
                .control_right       (control_right[i]),
                .precision_mode_right(precision_mode_right[i])
            );
        end else begin
            PE #(
                .PE_SIZE    (PE_SIZE),
                .DATA_WIDTH (DATA_WIDTH),
                .PREC_WIDTH (PREC_WIDTH)
            ) PE_inst (
                .clk                 (clk),
                .rst_n               (rst_n),
                .precision_mode_left (precision_mode_right[i-1]),
                .left                ((i < matrix_n) ? right[i-1] : {DATA_WIDTH{1'b0}}),
                .up                  ((i < matrix_n) ? up_all[i*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}}),
                .right               (right[i]),
                .down                (down_all[i*DATA_WIDTH +: DATA_WIDTH]),
                .o_data              (data[i-1]),
                .data_valid          (data_valid_row[i]),
                .i_data              (((i + 1) < matrix_n) ? data[i] : {(DATA_WIDTH*PE_SIZE){1'b0}}),
                .control_up          ((i < matrix_n) ? control_up_all[i*2 +: 2] : 2'b0),
                .control_left        ((i < matrix_n) ? control_right[i-1] : 2'b0),
                .control_down        (control_down_all[i*2 +: 2]),
                .control_right       (control_right[i]),
                .precision_mode_right(precision_mode_right[i])
            );
        end
    end
endgenerate

endmodule
