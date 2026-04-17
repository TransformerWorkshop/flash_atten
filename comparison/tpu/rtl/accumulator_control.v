module accumulator_control#(
    parameter PE_SIZE          = 16,
    parameter PREC_WIDTH       = 4,
    parameter MATRIX_DIM_WIDTH = 8
)(
    input                                 clk             ,
    input                                 rst_n           ,
    input      [      PREC_WIDTH-1:0]     precision_mode  ,
    input                                 data_valid      ,
    input      [ MATRIX_DIM_WIDTH-1:0]    matrix_m        ,
    input      [ MATRIX_DIM_WIDTH-1:0]    matrix_n        ,
    input      [ MATRIX_DIM_WIDTH-1:0]    matrix_k        ,
    output reg                            wr_en_to_demux  ,
    output reg                            group_first     ,
    output reg                            wr_en_to_fifo   ,
    output reg                            accu_output_done,
    output reg  [               7:0]      output_slot_idx ,
    output wire [7:0]                     dbg_flags       ,
    output wire [7:0]                     dbg_partial_phase,
    output wire [7:0]                     dbg_partials_per_output,
    output wire [19:0]                    dbg_valid_cycle_count,
    output wire [19:0]                    dbg_emit_cycle_count,
    output wire [19:0]                    dbg_valid_cycle_limit,
    output wire [19:0]                    dbg_output_cycle_limit,
    output wire [PREC_WIDTH-1:0]          dbg_precision_mode
);

localparam LOG2_PE_SIZE      = $clog2(PE_SIZE);
localparam TREE_LATENCY_INT  = LOG2_PE_SIZE + 3;
localparam COUNTER_WIDTH     = 20;

localparam INT8     = 4'd1;
localparam INT8_32  = 4'd3;

reg  [COUNTER_WIDTH-1:0] valid_cycle_count;
reg  [COUNTER_WIDTH-1:0] emit_cycle_count;
reg  [               7:0] partial_phase;
reg  [               7:0] output_slot_raw;
reg  [               7:0] output_slot_count;
reg                       run_active;

reg  [TREE_LATENCY_INT-1:0] accept_pipe;
reg  [TREE_LATENCY_INT-1:0] first_pipe;
reg  [TREE_LATENCY_INT-1:0] emit_pipe;
reg  [TREE_LATENCY_INT-1:0] done_pipe;
reg  [TREE_LATENCY_INT*8-1:0] slot_pipe;

reg  [COUNTER_WIDTH-1:0] output_cycle_limit;
reg  [               7:0] partials_per_output;
reg  [COUNTER_WIDTH-1:0] valid_cycle_limit;

reg  [COUNTER_WIDTH-1:0] next_valid_cycle_count;
reg  [COUNTER_WIDTH-1:0] next_emit_cycle_count;
reg  [               7:0] next_partial_phase;
reg  [               7:0] next_output_slot_count;
reg                       next_run_active;

reg                       accept_raw;
reg                       first_raw;
reg                       emit_raw;
reg                       done_raw;
reg  [COUNTER_WIDTH-1:0] row_groups;
reg  [COUNTER_WIDTH-1:0] partial_groups;
reg  [               7:0] slot_limit;

wire int_wire = (precision_mode == INT8) || (precision_mode == INT8_32);
wire done_tail = done_pipe[TREE_LATENCY_INT-1];

assign dbg_flags = {
    done_tail,
    done_raw,
    emit_raw,
    first_raw,
    accept_raw,
    data_valid,
    run_active,
    int_wire
};
assign dbg_partial_phase = partial_phase;
assign dbg_partials_per_output = partials_per_output;
assign dbg_valid_cycle_count = valid_cycle_count;
assign dbg_emit_cycle_count = emit_cycle_count;
assign dbg_valid_cycle_limit = valid_cycle_limit;
assign dbg_output_cycle_limit = output_cycle_limit;
assign dbg_precision_mode = precision_mode;

always @(*) begin
    row_groups = (matrix_m + PE_SIZE - 1) >> LOG2_PE_SIZE;
    if (row_groups == 0) begin
        row_groups = 1;
    end

    partial_groups = (matrix_k + PE_SIZE - 1) >> LOG2_PE_SIZE;
    if (partial_groups == 0) begin
        partial_groups = 1;
    end

    if (matrix_n == 0) begin
        slot_limit = 8'd1;
    end else if (matrix_n < PE_SIZE) begin
        slot_limit = matrix_n[7:0];
    end else begin
        slot_limit = PE_SIZE[7:0];
    end

    output_cycle_limit = row_groups * matrix_n;
    partials_per_output = partial_groups[7:0];
    valid_cycle_limit = row_groups * matrix_n * partial_groups;
end

always @(*) begin
    next_valid_cycle_count = valid_cycle_count;
    next_emit_cycle_count = emit_cycle_count;
    next_partial_phase = partial_phase;
    next_output_slot_count = output_slot_count;
    next_run_active = run_active;

    accept_raw = 1'b0;
    first_raw = 1'b0;
    emit_raw = 1'b0;
    done_raw = 1'b0;
    output_slot_raw = output_slot_count;

    if (done_tail) begin
        next_valid_cycle_count = {COUNTER_WIDTH{1'b0}};
        next_emit_cycle_count = {COUNTER_WIDTH{1'b0}};
        next_partial_phase = 8'd0;
        next_output_slot_count = 8'd0;
        next_run_active = 1'b0;
    end else begin
        if (data_valid && (valid_cycle_count < valid_cycle_limit)) begin
            if (!run_active) begin
                next_run_active = 1'b1;
            end

            output_slot_raw = output_slot_count;
            next_valid_cycle_count = valid_cycle_count + 1'b1;
            accept_raw = 1'b1;
            first_raw = (partial_phase == 0);
            emit_raw = ((partial_phase + 1'b1) >= partials_per_output);

            if (emit_raw) begin
                next_emit_cycle_count = emit_cycle_count + 1'b1;
            end

            if ((output_slot_count + 1'b1) >= slot_limit) begin
                next_output_slot_count = 8'd0;
                if (emit_raw) begin
                    next_partial_phase = 8'd0;
                    done_raw = ((emit_cycle_count + 1'b1) == output_cycle_limit);
                end else begin
                    next_partial_phase = partial_phase + 1'b1;
                end
            end else begin
                next_output_slot_count = output_slot_count + 1'b1;
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_cycle_count <= {COUNTER_WIDTH{1'b0}};
        emit_cycle_count <= {COUNTER_WIDTH{1'b0}};
        partial_phase <= 8'd0;
        output_slot_count <= 8'd0;
        run_active <= 1'b0;

        accept_pipe <= {TREE_LATENCY_INT{1'b0}};
        first_pipe <= {TREE_LATENCY_INT{1'b0}};
        emit_pipe <= {TREE_LATENCY_INT{1'b0}};
        done_pipe <= {TREE_LATENCY_INT{1'b0}};
        slot_pipe <= {(TREE_LATENCY_INT*8){1'b0}};

        wr_en_to_demux <= 1'b0;
        group_first <= 1'b0;
        wr_en_to_fifo <= 1'b0;
        accu_output_done <= 1'b0;
        output_slot_idx <= 8'd0;
    end else begin
        valid_cycle_count <= next_valid_cycle_count;
        emit_cycle_count <= next_emit_cycle_count;
        partial_phase <= next_partial_phase;
        output_slot_count <= next_output_slot_count;
        run_active <= next_run_active;

        accept_pipe <= {accept_pipe[TREE_LATENCY_INT-2:0], int_wire && accept_raw};
        first_pipe <= {first_pipe[TREE_LATENCY_INT-2:0], int_wire && first_raw};
        emit_pipe <= {emit_pipe[TREE_LATENCY_INT-2:0], int_wire && emit_raw};
        done_pipe <= {done_pipe[TREE_LATENCY_INT-2:0], int_wire && done_raw};
        slot_pipe <= {slot_pipe[(TREE_LATENCY_INT-1)*8-1:0], int_wire && accept_raw ? output_slot_raw : 8'd0};

        wr_en_to_demux <= accept_pipe[TREE_LATENCY_INT-1];
        group_first <= first_pipe[TREE_LATENCY_INT-1];
        wr_en_to_fifo <= emit_pipe[TREE_LATENCY_INT-1];
        accu_output_done <= done_pipe[TREE_LATENCY_INT-1];
        output_slot_idx <= slot_pipe[TREE_LATENCY_INT*8-1 -: 8];
    end
end

endmodule
