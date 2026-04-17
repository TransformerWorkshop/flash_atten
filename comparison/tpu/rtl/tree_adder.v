module tree_adder #(
    parameter DATA_WIDTH = 32,
    parameter PE_SIZE    = 16,
    parameter PREC_WIDTH = 4,
    parameter ROW_IDX    = 0
)(
    input                      clk,
    input  [PREC_WIDTH-1:0]    precision_mode,
    input  [DATA_WIDTH*PE_SIZE-1:0] num,
    output [DATA_WIDTH-1:0]    out
);

localparam integer TREE_STAGES = $clog2(PE_SIZE);

wire [DATA_WIDTH*PE_SIZE-1:0] stage_data [0:TREE_STAGES];

reg [PREC_WIDTH-1:0] precision_mode_reg;
// 寄存减少信号扇出
always @(posedge clk) begin
    precision_mode_reg <= precision_mode;
end

assign stage_data[0] = num;

genvar stage_idx;
generate
    for (stage_idx = 0; stage_idx < TREE_STAGES; stage_idx = stage_idx + 1) begin : gen_tree_stage
        genvar pair_idx;
        for (pair_idx = 0; pair_idx < (PE_SIZE >> (stage_idx + 1)); pair_idx = pair_idx + 1) begin : gen_tree_pair
            multi_precision_adder u_multi_precision_adder(
                .clk             (clk),
                .num1            (stage_data[stage_idx][(2*pair_idx)*DATA_WIDTH +: DATA_WIDTH]),
                .num2            (stage_data[stage_idx][(2*pair_idx + 1)*DATA_WIDTH +: DATA_WIDTH]),
                .precision_mode  (precision_mode_reg),
                .location        (2'd0),
                .sum             (stage_data[stage_idx + 1][pair_idx*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    end
endgenerate

assign out = stage_data[TREE_STAGES][DATA_WIDTH-1:0];
endmodule
