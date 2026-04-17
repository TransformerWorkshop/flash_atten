module accumulator #(
    parameter DATA_WIDTH = 32,
    parameter PE_SIZE    = 16,
    parameter PREC_WIDTH = 4,
    parameter MATRIX_DIM_WIDTH = 8,
    parameter ROW_IDX    = 0
)(
    input                              clk,
    input                              rst_n,
    input  [PREC_WIDTH-1:0]            precision_mode,
    input                              data_valid,
    input  [DATA_WIDTH*PE_SIZE-1:0]    num,
    input  [MATRIX_DIM_WIDTH-1:0]      matrix_m,
    input  [MATRIX_DIM_WIDTH-1:0]      matrix_n,
    input  [MATRIX_DIM_WIDTH-1:0]      matrix_k,
    output reg [DATA_WIDTH-1:0]        sum,
    output reg                         wr_en_to_fifo,
    output wire                        partial_accept_dbg,
    output reg                         accu_output_done,
    output wire [7:0]                  dbg_ctrl_flags,
    output wire [7:0]                  dbg_ctrl_partial_phase,
    output wire [7:0]                  dbg_ctrl_partials_per_output,
    output wire [19:0]                 dbg_ctrl_valid_cycle_count,
    output wire [19:0]                 dbg_ctrl_emit_cycle_count,
    output wire [19:0]                 dbg_ctrl_valid_cycle_limit,
    output wire [19:0]                 dbg_ctrl_output_cycle_limit,
    output wire [PREC_WIDTH-1:0]       dbg_ctrl_precision_mode
);
    localparam MAX_OUTPUT_SLOTS = PE_SIZE;

    reg [PREC_WIDTH-1:0]   precision_mode_reg;
    reg signed [DATA_WIDTH-1:0] accum_mem [0:MAX_OUTPUT_SLOTS-1];
    wire signed [DATA_WIDTH-1:0] partial_sum_signed;

    wire                   group_first;
    wire                   wr_en_to_demux;
    wire                   ctrl_wr_en_to_fifo;
    wire                   ctrl_accu_output_done;
    wire [7:0]             output_slot_idx;
    wire [DATA_WIDTH-1:0]  out;
    integer                clear_idx;
    integer                slot_idx_int;
    reg signed [DATA_WIDTH-1:0] accum_next_value;


    // 寄存减少信号扇出
    always @(posedge clk) begin
        precision_mode_reg <= precision_mode;
    end

    tree_adder #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_SIZE(PE_SIZE),
        .PREC_WIDTH(PREC_WIDTH),
        .ROW_IDX(ROW_IDX)
    )tree_adder_inst(
        .clk             (clk),
        .num             (num),
        .precision_mode  (precision_mode_reg),
        .out             (out)
    );

    accumulator_control #(
        .PE_SIZE(PE_SIZE),
        .PREC_WIDTH(PREC_WIDTH),
        .MATRIX_DIM_WIDTH(MATRIX_DIM_WIDTH)
    )accumulator_control_inst(
        .clk             (clk),
        .rst_n           (rst_n),
        .precision_mode  (precision_mode_reg),
        .data_valid      (data_valid),
        .matrix_m        (matrix_m),
        .matrix_n        (matrix_n),
        .matrix_k        (matrix_k),
        .wr_en_to_demux  (wr_en_to_demux),
        .group_first     (group_first),
        .wr_en_to_fifo   (ctrl_wr_en_to_fifo),
        .accu_output_done(ctrl_accu_output_done),
        .output_slot_idx (output_slot_idx),
        .dbg_flags       (dbg_ctrl_flags),
        .dbg_partial_phase(dbg_ctrl_partial_phase),
        .dbg_partials_per_output(dbg_ctrl_partials_per_output),
        .dbg_valid_cycle_count(dbg_ctrl_valid_cycle_count),
        .dbg_emit_cycle_count(dbg_ctrl_emit_cycle_count),
        .dbg_valid_cycle_limit(dbg_ctrl_valid_cycle_limit),
        .dbg_output_cycle_limit(dbg_ctrl_output_cycle_limit),
        .dbg_precision_mode(dbg_ctrl_precision_mode)
    );

    assign partial_accept_dbg = wr_en_to_demux;
    assign partial_sum_signed = out;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (clear_idx = 0; clear_idx < MAX_OUTPUT_SLOTS; clear_idx = clear_idx + 1) begin
                accum_mem[clear_idx] <= {DATA_WIDTH{1'b0}};
            end
            sum <= {DATA_WIDTH{1'b0}};
            wr_en_to_fifo <= 1'b0;
            accu_output_done <= 1'b0;
        end else begin
            wr_en_to_fifo <= ctrl_wr_en_to_fifo;
            accu_output_done <= ctrl_accu_output_done;

            if (wr_en_to_demux) begin
                slot_idx_int = output_slot_idx;
                if (slot_idx_int >= MAX_OUTPUT_SLOTS) begin
                    slot_idx_int = 0;
                end

                if (group_first) begin
                    accum_next_value = partial_sum_signed;
                end else begin
                    accum_next_value = accum_mem[slot_idx_int] + partial_sum_signed;
                end

                accum_mem[slot_idx_int] <= accum_next_value;
                if (ctrl_wr_en_to_fifo) begin
                    sum <= accum_next_value;
                    accum_mem[slot_idx_int] <= {DATA_WIDTH{1'b0}};
                end
            end

            if (ctrl_accu_output_done) begin
                for (clear_idx = 0; clear_idx < MAX_OUTPUT_SLOTS; clear_idx = clear_idx + 1) begin
                    accum_mem[clear_idx] <= {DATA_WIDTH{1'b0}};
                end
            end
        end
    end

endmodule
