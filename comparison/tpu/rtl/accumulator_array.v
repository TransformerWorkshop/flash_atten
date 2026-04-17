module accumulator_array #(
    parameter DATA_WIDTH = 32,
    parameter PE_SIZE    = 16,
    parameter PREC_WIDTH = 4,
    parameter MATRIX_DIM_WIDTH = 8
)(
    input                              clk,
    input                              rst_n,
    input  [PREC_WIDTH-1:0]            precision_mode,
    input  [DATA_WIDTH*PE_SIZE*PE_SIZE-1:0]  num,
    input  [PE_SIZE-1:0]               data_valid,
    input  [MATRIX_DIM_WIDTH-1:0]      matrix_m,
    input  [MATRIX_DIM_WIDTH-1:0]      matrix_n,
    input  [MATRIX_DIM_WIDTH-1:0]      matrix_k,
    output [DATA_WIDTH*PE_SIZE-1:0]    out,
    output [PE_SIZE-1:0]               wr_en_to_fifo,
    output wire                        accu_partial_accept_dbg,
    output reg                         accu_output_done,
    output reg [DATA_WIDTH-1:0]        first_emitted_word_dbg,
    output reg [DATA_WIDTH-1:0]        last_emitted_word_dbg,
    output reg                         first_emitted_word_vld_dbg,
    output reg                         last_emitted_word_vld_dbg,
    output wire [7:0]                  dbg_ctrl_flags,
    output wire [7:0]                  dbg_ctrl_partial_phase,
    output wire [7:0]                  dbg_ctrl_partials_per_output,
    output wire [19:0]                 dbg_ctrl_valid_cycle_count,
    output wire [19:0]                 dbg_ctrl_emit_cycle_count,
    output wire [19:0]                 dbg_ctrl_valid_cycle_limit,
    output wire [19:0]                 dbg_ctrl_output_cycle_limit,
    output wire [PREC_WIDTH-1:0]       dbg_ctrl_precision_mode
);
reg  [PREC_WIDTH-1:0]                     precision_mode_reg;
wire [PE_SIZE-1:0]                        partial_accept_dbg_bus;
wire [PE_SIZE-1:0]                        accu_output_done_bus;
wire [PE_SIZE*8-1:0]                      dbg_ctrl_flags_bus;
wire [PE_SIZE*8-1:0]                      dbg_ctrl_partial_phase_bus;
wire [PE_SIZE*8-1:0]                      dbg_ctrl_partials_per_output_bus;
wire [PE_SIZE*20-1:0]                     dbg_ctrl_valid_cycle_count_bus;
wire [PE_SIZE*20-1:0]                     dbg_ctrl_emit_cycle_count_bus;
wire [PE_SIZE*20-1:0]                     dbg_ctrl_valid_cycle_limit_bus;
wire [PE_SIZE*20-1:0]                     dbg_ctrl_output_cycle_limit_bus;
wire [PE_SIZE*PREC_WIDTH-1:0]             dbg_ctrl_precision_mode_bus;
reg  [PE_SIZE-1:0]                        lane_done_seen;
reg                                       seen_emit_word;
reg  [DATA_WIDTH-1:0]                     selected_emit_word;
reg  [PE_SIZE-1:0]                        next_lane_done_seen;
integer                                   emit_lane_idx;

assign accu_partial_accept_dbg = |partial_accept_dbg_bus;
assign dbg_ctrl_flags = dbg_ctrl_flags_bus[7:0];
assign dbg_ctrl_partial_phase = dbg_ctrl_partial_phase_bus[7:0];
assign dbg_ctrl_partials_per_output = dbg_ctrl_partials_per_output_bus[7:0];
assign dbg_ctrl_valid_cycle_count = dbg_ctrl_valid_cycle_count_bus[19:0];
assign dbg_ctrl_emit_cycle_count = dbg_ctrl_emit_cycle_count_bus[19:0];
assign dbg_ctrl_valid_cycle_limit = dbg_ctrl_valid_cycle_limit_bus[19:0];
assign dbg_ctrl_output_cycle_limit = dbg_ctrl_output_cycle_limit_bus[19:0];
assign dbg_ctrl_precision_mode = dbg_ctrl_precision_mode_bus[PREC_WIDTH-1:0];

always @(*) begin
    selected_emit_word = {DATA_WIDTH{1'b0}};
    for (emit_lane_idx = 0; emit_lane_idx < PE_SIZE; emit_lane_idx = emit_lane_idx + 1) begin
        if (wr_en_to_fifo[emit_lane_idx]) begin
            selected_emit_word = out[emit_lane_idx*DATA_WIDTH +: DATA_WIDTH];
        end
    end
end

// 寄存减少信号扇出
always @(posedge clk) begin
    precision_mode_reg <= precision_mode;
end

genvar i;
generate
    for (i = 0; i < PE_SIZE; i = i + 1) begin : gen_accumulator_array
        accumulator #(
            .DATA_WIDTH      (32),
            .PE_SIZE         (PE_SIZE),
            .PREC_WIDTH      (PREC_WIDTH),
            .MATRIX_DIM_WIDTH(MATRIX_DIM_WIDTH),
            .ROW_IDX         (i)
        )accumulator_inst(
            .clk             (clk),
            .rst_n           (rst_n),
            .num             (num[i*DATA_WIDTH*PE_SIZE +: DATA_WIDTH*PE_SIZE]),
            .data_valid      (data_valid[i]),
            .precision_mode  (precision_mode_reg),
            .matrix_m        (matrix_m),
            .matrix_n        (matrix_n),
            .matrix_k        (matrix_k),
            .sum             (out[i*DATA_WIDTH +: DATA_WIDTH]),
            .wr_en_to_fifo   (wr_en_to_fifo[i]),
            .partial_accept_dbg(partial_accept_dbg_bus[i]),
            .accu_output_done(accu_output_done_bus[i]),
            .dbg_ctrl_flags(dbg_ctrl_flags_bus[i*8 +: 8]),
            .dbg_ctrl_partial_phase(dbg_ctrl_partial_phase_bus[i*8 +: 8]),
            .dbg_ctrl_partials_per_output(dbg_ctrl_partials_per_output_bus[i*8 +: 8]),
            .dbg_ctrl_valid_cycle_count(dbg_ctrl_valid_cycle_count_bus[i*20 +: 20]),
            .dbg_ctrl_emit_cycle_count(dbg_ctrl_emit_cycle_count_bus[i*20 +: 20]),
            .dbg_ctrl_valid_cycle_limit(dbg_ctrl_valid_cycle_limit_bus[i*20 +: 20]),
            .dbg_ctrl_output_cycle_limit(dbg_ctrl_output_cycle_limit_bus[i*20 +: 20]),
            .dbg_ctrl_precision_mode(dbg_ctrl_precision_mode_bus[i*PREC_WIDTH +: PREC_WIDTH])
        );
    end

endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lane_done_seen <= {PE_SIZE{1'b0}};
        seen_emit_word <= 1'b0;
        accu_output_done <= 1'b0;
        first_emitted_word_dbg <= {DATA_WIDTH{1'b0}};
        last_emitted_word_dbg <= {DATA_WIDTH{1'b0}};
        first_emitted_word_vld_dbg <= 1'b0;
        last_emitted_word_vld_dbg <= 1'b0;
    end else begin
        next_lane_done_seen = lane_done_seen | accu_output_done_bus;

        accu_output_done <= 1'b0;
        first_emitted_word_vld_dbg <= 1'b0;
        last_emitted_word_vld_dbg <= 1'b0;

        if (|wr_en_to_fifo) begin
            if (!seen_emit_word) begin
                first_emitted_word_dbg <= selected_emit_word;
                first_emitted_word_vld_dbg <= 1'b1;
                seen_emit_word <= 1'b1;
            end

            last_emitted_word_dbg <= selected_emit_word;
            last_emitted_word_vld_dbg <= 1'b1;
        end

        if (&next_lane_done_seen) begin
            lane_done_seen <= {PE_SIZE{1'b0}};
            seen_emit_word <= 1'b0;
            accu_output_done <= 1'b1;
        end else begin
            lane_done_seen <= next_lane_done_seen;
        end
    end
end


endmodule
