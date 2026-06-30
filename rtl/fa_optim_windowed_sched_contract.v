module FA_OPTIM_WINDOWED_SCHED_CONTRACT #(
    parameter integer SEQ_LEN = 256,
    parameter integer HEAD_DIM = 64,
    parameter integer Q_GROUP_ROWS = 64,
    parameter integer Q_TILE_ROWS = 4,
    parameter integer KV_TILE_ROWS = 16,
    parameter integer KV_WINDOW_TILES = 4,
    parameter integer SCORE_SLICE_COLS = 4,
    parameter integer OACC_SLICE_COLS = 16
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        causal_en,
    output wire        q_tile_req_valid,
    input  wire        q_tile_req_ready,
    output wire [5:0]  q_tile_req_q_idx,
    output wire        k_tile_req_valid,
    input  wire        k_tile_req_ready,
    output wire [4:0]  k_tile_req_kv_idx,
    output wire        v_tile_req_valid,
    input  wire        v_tile_req_ready,
    output wire [4:0]  v_tile_req_kv_idx,
    output wire        busy,
    output reg         done,
    output reg         error,
    output reg  [31:0] cycles,
    output reg  [31:0] q_group_count,
    output reg  [31:0] kv_window_count,
    output reg  [31:0] q_tile_visit_count,
    output reg  [31:0] kv_tile_compute_count,
    output reg  [31:0] skipped_future_kv_tiles,
    output reg  [31:0] q_tile_req_count,
    output reg  [31:0] k_tile_req_count,
    output reg  [31:0] v_tile_req_count,
    output reg  [31:0] score_slice_count,
    output reg  [31:0] oacc_slice_count,
    output reg  [31:0] state_fill_count,
    output reg  [31:0] state_spill_count
);

    localparam integer Q_GROUP_COUNT = SEQ_LEN / Q_GROUP_ROWS;
    localparam integer Q_TILES_PER_GROUP = Q_GROUP_ROWS / Q_TILE_ROWS;
    localparam integer KV_TILE_COUNT = SEQ_LEN / KV_TILE_ROWS;
    localparam integer KV_WINDOWS_PER_GROUP = KV_TILE_COUNT / KV_WINDOW_TILES;
    localparam integer SCORE_SLICES_PER_TILE = KV_TILE_ROWS / SCORE_SLICE_COLS;
    localparam integer OACC_SLICES_PER_TILE = HEAD_DIM / OACC_SLICE_COLS;
    localparam integer Q_TILE_GLOBAL_COUNT = SEQ_LEN / Q_TILE_ROWS;
    localparam [4:0] KV_WINDOW_TILES_W = KV_WINDOW_TILES;
    localparam [8:0] Q_TILE_ROWS_W = Q_TILE_ROWS;
    localparam [8:0] KV_TILE_ROWS_W = KV_TILE_ROWS;

    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_GROUP_START  = 4'd1;
    localparam [3:0] ST_K_REQ        = 4'd2;
    localparam [3:0] ST_V_REQ        = 4'd3;
    localparam [3:0] ST_Q_REQ        = 4'd4;
    localparam [3:0] ST_STATE_FILL   = 4'd5;
    localparam [3:0] ST_TILE_COMPUTE = 4'd6;
    localparam [3:0] ST_STATE_SPILL  = 4'd7;
    localparam [3:0] ST_DONE         = 4'd8;

    reg [3:0] state_r;
    reg [3:0] state_n;
    reg [1:0] q_group_idx_r;
    reg [1:0] kv_window_idx_r;
    reg [1:0] kv_load_slot_idx_r;
    reg [3:0] q_tile_in_group_idx_r;
    reg [1:0] kv_compute_slot_idx_r;
    reg       busy_r;

    wire q_tile_req_fire_w = q_tile_req_valid && q_tile_req_ready;
    wire k_tile_req_fire_w = k_tile_req_valid && k_tile_req_ready;
    wire v_tile_req_fire_w = v_tile_req_valid && v_tile_req_ready;
    wire [4:0] kv_window_base_idx_w =
        ({3'd0, kv_window_idx_r} * KV_WINDOW_TILES_W);
    wire [4:0] kv_load_tile_idx_w =
        kv_window_base_idx_w + {3'd0, kv_load_slot_idx_r};
    wire [4:0] kv_compute_tile_idx_w =
        kv_window_base_idx_w + {3'd0, kv_compute_slot_idx_r};
    wire [5:0] q_group_base_tile_idx_w =
        {q_group_idx_r, 4'd0};
    wire [5:0] q_current_tile_idx_w =
        q_group_base_tile_idx_w + {2'd0, q_tile_in_group_idx_r};
    wire [8:0] q_tile_last_row_idx_w =
        ({3'd0, q_current_tile_idx_w} * Q_TILE_ROWS_W) + (Q_TILE_ROWS - 1);
    wire [8:0] kv_tile_first_row_idx_w =
        {4'd0, kv_compute_tile_idx_w} * KV_TILE_ROWS_W;
    wire current_kv_tile_fully_future_w =
        causal_en && (kv_tile_first_row_idx_w > q_tile_last_row_idx_w);

    assign q_tile_req_valid = (state_r == ST_Q_REQ);
    assign q_tile_req_q_idx = q_current_tile_idx_w;
    assign k_tile_req_valid = (state_r == ST_K_REQ);
    assign k_tile_req_kv_idx = kv_load_tile_idx_w;
    assign v_tile_req_valid = (state_r == ST_V_REQ);
    assign v_tile_req_kv_idx = kv_load_tile_idx_w;
    assign busy = busy_r;

    always @(*) begin
        state_n = state_r;
        case (state_r)
            ST_IDLE: begin
                if (start) begin
                    state_n = ST_GROUP_START;
                end
            end
            ST_GROUP_START: begin
                state_n = ST_K_REQ;
            end
            ST_K_REQ: begin
                if (k_tile_req_fire_w) begin
                    state_n = ST_V_REQ;
                end
            end
            ST_V_REQ: begin
                if (v_tile_req_fire_w) begin
                    if (kv_load_slot_idx_r == (KV_WINDOW_TILES - 1)) begin
                        state_n = ST_Q_REQ;
                    end else begin
                        state_n = ST_K_REQ;
                    end
                end
            end
            ST_Q_REQ: begin
                if (q_tile_req_fire_w) begin
                    state_n = ST_STATE_FILL;
                end
            end
            ST_STATE_FILL: begin
                state_n = ST_TILE_COMPUTE;
            end
            ST_TILE_COMPUTE: begin
                if (kv_compute_slot_idx_r == (KV_WINDOW_TILES - 1)) begin
                    state_n = ST_STATE_SPILL;
                end
            end
            ST_STATE_SPILL: begin
                if ((q_group_idx_r == (Q_GROUP_COUNT - 1)) &&
                    (kv_window_idx_r == (KV_WINDOWS_PER_GROUP - 1)) &&
                    (q_tile_in_group_idx_r == (Q_TILES_PER_GROUP - 1))) begin
                    state_n = ST_DONE;
                end else if (q_tile_in_group_idx_r == (Q_TILES_PER_GROUP - 1)) begin
                    if (kv_window_idx_r == (KV_WINDOWS_PER_GROUP - 1)) begin
                        state_n = ST_GROUP_START;
                    end else begin
                        state_n = ST_K_REQ;
                    end
                end else begin
                    state_n = ST_Q_REQ;
                end
            end
            ST_DONE: begin
                state_n = ST_IDLE;
            end
            default: begin
                state_n = ST_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
        end else if (clear) begin
            state_r <= ST_IDLE;
        end else begin
            state_r <= state_n;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cycles <= 32'd0;
            q_group_count <= 32'd0;
            kv_window_count <= 32'd0;
            q_tile_visit_count <= 32'd0;
            kv_tile_compute_count <= 32'd0;
            skipped_future_kv_tiles <= 32'd0;
            q_tile_req_count <= 32'd0;
            k_tile_req_count <= 32'd0;
            v_tile_req_count <= 32'd0;
            score_slice_count <= 32'd0;
            oacc_slice_count <= 32'd0;
            state_fill_count <= 32'd0;
            state_spill_count <= 32'd0;
            q_group_idx_r <= 2'd0;
            kv_window_idx_r <= 2'd0;
            kv_load_slot_idx_r <= 2'd0;
            q_tile_in_group_idx_r <= 4'd0;
            kv_compute_slot_idx_r <= 2'd0;
        end else if (clear) begin
            busy_r <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cycles <= 32'd0;
            q_group_count <= 32'd0;
            kv_window_count <= 32'd0;
            q_tile_visit_count <= 32'd0;
            kv_tile_compute_count <= 32'd0;
            skipped_future_kv_tiles <= 32'd0;
            q_tile_req_count <= 32'd0;
            k_tile_req_count <= 32'd0;
            v_tile_req_count <= 32'd0;
            score_slice_count <= 32'd0;
            oacc_slice_count <= 32'd0;
            state_fill_count <= 32'd0;
            state_spill_count <= 32'd0;
            q_group_idx_r <= 2'd0;
            kv_window_idx_r <= 2'd0;
            kv_load_slot_idx_r <= 2'd0;
            q_tile_in_group_idx_r <= 4'd0;
            kv_compute_slot_idx_r <= 2'd0;
        end else begin
            done <= 1'b0;

            if (busy_r) begin
                cycles <= cycles + 32'd1;
            end

            if (state_r == ST_IDLE && start) begin
                busy_r <= 1'b1;
                error <= config_invalid_w;
                cycles <= 32'd0;
                q_group_count <= 32'd0;
                kv_window_count <= 32'd0;
                q_tile_visit_count <= 32'd0;
                kv_tile_compute_count <= 32'd0;
                skipped_future_kv_tiles <= 32'd0;
                q_tile_req_count <= 32'd0;
                k_tile_req_count <= 32'd0;
                v_tile_req_count <= 32'd0;
                score_slice_count <= 32'd0;
                oacc_slice_count <= 32'd0;
                state_fill_count <= 32'd0;
                state_spill_count <= 32'd0;
                q_group_idx_r <= 2'd0;
                kv_window_idx_r <= 2'd0;
                kv_load_slot_idx_r <= 2'd0;
                q_tile_in_group_idx_r <= 4'd0;
                kv_compute_slot_idx_r <= 2'd0;
            end

            if (state_r == ST_GROUP_START) begin
                q_group_count <= q_group_count + 32'd1;
            end

            if (k_tile_req_fire_w) begin
                k_tile_req_count <= k_tile_req_count + 32'd1;
            end

            if (v_tile_req_fire_w) begin
                v_tile_req_count <= v_tile_req_count + 32'd1;
                if (kv_load_slot_idx_r == (KV_WINDOW_TILES - 1)) begin
                    kv_load_slot_idx_r <= 2'd0;
                    kv_window_count <= kv_window_count + 32'd1;
                end else begin
                    kv_load_slot_idx_r <= kv_load_slot_idx_r + 1'b1;
                end
            end

            if (q_tile_req_fire_w) begin
                q_tile_req_count <= q_tile_req_count + 32'd1;
                q_tile_visit_count <= q_tile_visit_count + 32'd1;
            end

            if (state_r == ST_STATE_FILL) begin
                state_fill_count <= state_fill_count + 32'd1;
                kv_compute_slot_idx_r <= 2'd0;
            end

            if (state_r == ST_TILE_COMPUTE) begin
                if (current_kv_tile_fully_future_w) begin
                    skipped_future_kv_tiles <= skipped_future_kv_tiles + 32'd1;
                end else begin
                    kv_tile_compute_count <= kv_tile_compute_count + 32'd1;
                    score_slice_count <= score_slice_count + SCORE_SLICES_PER_TILE;
                    oacc_slice_count <= oacc_slice_count + OACC_SLICES_PER_TILE;
                end
                if (kv_compute_slot_idx_r != (KV_WINDOW_TILES - 1)) begin
                    kv_compute_slot_idx_r <= kv_compute_slot_idx_r + 1'b1;
                end
            end

            if (state_r == ST_STATE_SPILL) begin
                state_spill_count <= state_spill_count + 32'd1;
                kv_compute_slot_idx_r <= 2'd0;
                if (q_tile_in_group_idx_r == (Q_TILES_PER_GROUP - 1)) begin
                    q_tile_in_group_idx_r <= 4'd0;
                    if (kv_window_idx_r == (KV_WINDOWS_PER_GROUP - 1)) begin
                        kv_window_idx_r <= 2'd0;
                        if (q_group_idx_r != (Q_GROUP_COUNT - 1)) begin
                            q_group_idx_r <= q_group_idx_r + 1'b1;
                        end
                    end else begin
                        kv_window_idx_r <= kv_window_idx_r + 1'b1;
                    end
                end else begin
                    q_tile_in_group_idx_r <= q_tile_in_group_idx_r + 1'b1;
                end
            end

            if (state_r == ST_DONE) begin
                busy_r <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    wire config_invalid_w =
        (SEQ_LEN != 256) ||
        (HEAD_DIM != 64) ||
        (Q_GROUP_ROWS != 64) ||
        (Q_TILE_ROWS != 4) ||
        (KV_TILE_ROWS != 16) ||
        (KV_WINDOW_TILES != 4) ||
        (SCORE_SLICE_COLS != 4) ||
        (OACC_SLICE_COLS != 16) ||
        (Q_TILE_GLOBAL_COUNT != 64);

endmodule
