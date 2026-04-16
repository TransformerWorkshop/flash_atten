module precision_convert #(
    parameter PREC_WIDTH = 4
)(
    input                        clk,
    input      [31:0]            data,
    input      [PREC_WIDTH-1:0]  precision_mode,
    output reg [31:0]            data_output
);

    reg [31:0] data_stage1;

    // INT runtime paths only need registered passthrough, but we keep the
    // two-stage alignment that the existing integer pipeline expects.
    always @(posedge clk) begin
        data_stage1 <= data;
        data_output <= data_stage1;
    end
endmodule
