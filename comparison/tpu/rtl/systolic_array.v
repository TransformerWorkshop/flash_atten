module systolic_array#(
    parameter PE_SIZE    = 8,
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4
)(
    input                              clk,
    input                              rst_n,
    input  [1:0]                       control,
    input  [DATA_WIDTH*PE_SIZE-1:0]    up_all,      //8columns input,8bit num
    input  [DATA_WIDTH*PE_SIZE-1:0]    left_all,    //8rows input ,8bit num
    input  [PREC_WIDTH-1:0]            precision_mode,
    output [DATA_WIDTH*PE_SIZE*8-1:0]  data_selected,
    output [PE_SIZE-1:0]               data_valid,
    output                             done_systolic
);
localparam INT8     = 4'd1;
localparam INT8_32  = 4'd3;

wire [DATA_WIDTH*PE_SIZE-1:0] down_all         [0:PE_SIZE];
wire [2*PE_SIZE-1:0]          control_down_all [0:PE_SIZE];
reg  [5:0]                    cnt_delay                  ;//计算累加器延时，计算出结果需要的时间
reg                           cnt_state                  ;

assign done_systolic = (cnt_delay == 27);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n || done_systolic)begin
        cnt_state <= 0;
    end else if (control==2)begin
        cnt_state <= 1;
    end else begin
        cnt_state <= cnt_state;
    end
end

always @(posedge clk) begin
    if (!cnt_state) begin
        cnt_delay <= 0;
    end else begin
        cnt_delay <= cnt_delay + 1;
    end
end

genvar i; 
generate
    for (i = 0; i < 8; i = i + 1) begin : pe_row
        if (i==0) begin
            PE_row #(
                .PE_SIZE     (PE_SIZE),
                .DATA_WIDTH  (DATA_WIDTH),
                .PREC_WIDTH  (PREC_WIDTH)
            ) pe_row_inst (
                .clk              (clk),
                .rst_n            (rst_n),
                .left             (left_all[i*DATA_WIDTH +: 32]),
                .up_all           (up_all),
                .control_left     (control),
                .control_up_all   (),
                .precision_mode   (precision_mode),
                .down_all         (down_all[i]),
                .control_down_all (control_down_all[i]),
                .data_selected    (data_selected[i*DATA_WIDTH*8 +: DATA_WIDTH*8]),
                .data_valid       (data_valid[i])
            );
        end else begin
            PE_row #(
                .PE_SIZE     (PE_SIZE),
                .DATA_WIDTH  (DATA_WIDTH),
                .PREC_WIDTH  (PREC_WIDTH)
            ) pe_row_inst (
                .clk              (clk),
                .rst_n            (rst_n),
                .left             (left_all[i*DATA_WIDTH +: 32]),
                .up_all           (down_all[i-1]),
                .control_left     (),
                .control_up_all   (control_down_all[i-1]),
                .precision_mode   (precision_mode),
                .down_all         (down_all[i]),
                .control_down_all (control_down_all[i]),
                .data_selected    (data_selected[i*DATA_WIDTH*8 +: DATA_WIDTH*8]),
                .data_valid       (data_valid[i])
            );
        end
    end
endgenerate

endmodule
