module FA_TILE_SCHED (
    input  wire       clk,
    input  wire       rstn,
    input  wire       clear,
    input  wire       run_active,
    input  wire       run_start_pulse,
    output wire [3:0] q_blk_idx,
    output wire [3:0] kv_blk_idx,
    output reg  [3:0] load_q_blk_idx,
    output reg  [3:0] load_kv_blk_idx,
    output reg        load_req_valid,
    input  wire       load_req_ready,
    output reg  [1:0] load_req_kind,
    input  wire       load_done_pulse,
    output reg        row_init_valid,
    input  wire       row_init_ready,
    input  wire       row_init_done_pulse,
    output reg        oacc_clear_valid,
    input  wire       oacc_clear_ready,
    input  wire       oacc_clear_done_pulse,
    output reg        qk_req_valid,
    input  wire       qk_req_ready,
    input  wire       qk_done_pulse,
    output reg        score_req_valid,
    input  wire       score_req_ready,
    input  wire       score_done_pulse,
    output reg        row_update_valid,
    input  wire       row_update_ready,
    input  wire       row_update_done_pulse,
    output reg        pv_req_valid,
    input  wire       pv_req_ready,
    input  wire       pv_done_pulse,
    output reg        oacc_update_valid,
    input  wire       oacc_update_ready,
    input  wire       oacc_update_done_pulse,
    output reg        store_req_valid,
    input  wire       store_req_ready,
    input  wire       store_done_pulse,
    output reg        run_complete_pulse
);

    localparam [4:0] ST_IDLE             = 5'd0;
    localparam [4:0] ST_Q_LOAD_REQ       = 5'd1;
    localparam [4:0] ST_Q_LOAD_WAIT      = 5'd2;
    localparam [4:0] ST_ROW_INIT_REQ     = 5'd3;
    localparam [4:0] ST_ROW_INIT_WAIT    = 5'd4;
    localparam [4:0] ST_OACC_CLEAR_REQ   = 5'd5;
    localparam [4:0] ST_OACC_CLEAR_WAIT  = 5'd6;
    localparam [4:0] ST_K_LOAD_REQ       = 5'd7;
    localparam [4:0] ST_K_LOAD_WAIT      = 5'd8;
    localparam [4:0] ST_V_LOAD_REQ       = 5'd9;
    localparam [4:0] ST_V_LOAD_WAIT      = 5'd10;
    localparam [4:0] ST_QK_REQ           = 5'd11;
    localparam [4:0] ST_QK_WAIT          = 5'd12;
    localparam [4:0] ST_SCORE_REQ        = 5'd13;
    localparam [4:0] ST_SCORE_WAIT       = 5'd14;
    localparam [4:0] ST_ROW_UPDATE_REQ   = 5'd15;
    localparam [4:0] ST_ROW_UPDATE_WAIT  = 5'd16;
    localparam [4:0] ST_PV_REQ           = 5'd17;
    localparam [4:0] ST_PV_WAIT          = 5'd18;
    localparam [4:0] ST_OACC_UPDATE_REQ  = 5'd19;
    localparam [4:0] ST_OACC_UPDATE_WAIT = 5'd20;
    localparam [4:0] ST_STORE_REQ        = 5'd21;
    localparam [4:0] ST_STORE_WAIT       = 5'd22;
    localparam [4:0] ST_K_PREFETCH_WAIT  = 5'd23;

    localparam [1:0] LOAD_KIND_Q = 2'd0;
    localparam [1:0] LOAD_KIND_K = 2'd1;
    localparam [1:0] LOAD_KIND_V = 2'd2;

    reg [4:0] state_r;
    reg [4:0] state_n;
    reg [3:0] q_blk_r;
    reg [3:0] q_blk_n;
    reg [3:0] kv_blk_r;
    reg [3:0] kv_blk_n;
    reg       v_load_pending_r;
    reg       v_load_pending_n;
    reg       v_load_done_r;
    reg       v_load_done_n;
    reg       k_prefetch_wanted_r;
    reg       k_prefetch_wanted_n;
    reg       k_prefetch_inflight_r;
    reg       k_prefetch_inflight_n;
    reg       k_prefetch_done_r;
    reg       k_prefetch_done_n;

    assign q_blk_idx = q_blk_r;
    assign kv_blk_idx = kv_blk_r;

    always @(*) begin
        state_n = state_r;
        q_blk_n = q_blk_r;
        kv_blk_n = kv_blk_r;
        v_load_pending_n = v_load_pending_r;
        v_load_done_n = v_load_done_r;
        k_prefetch_wanted_n = k_prefetch_wanted_r;
        k_prefetch_inflight_n = k_prefetch_inflight_r;
        k_prefetch_done_n = k_prefetch_done_r;

        if (clear || !run_active) begin
            if (run_start_pulse) begin
                state_n = ST_Q_LOAD_REQ;
                q_blk_n = 4'd0;
                kv_blk_n = 4'd0;
                v_load_pending_n = 1'b0;
                v_load_done_n = 1'b0;
                k_prefetch_wanted_n = 1'b0;
                k_prefetch_inflight_n = 1'b0;
                k_prefetch_done_n = 1'b0;
            end else begin
                state_n = ST_IDLE;
                q_blk_n = 4'd0;
                kv_blk_n = 4'd0;
                v_load_pending_n = 1'b0;
                v_load_done_n = 1'b0;
                k_prefetch_wanted_n = 1'b0;
                k_prefetch_inflight_n = 1'b0;
                k_prefetch_done_n = 1'b0;
            end
        end else begin
            if (v_load_pending_r && load_done_pulse) begin
                v_load_pending_n = 1'b0;
                v_load_done_n = 1'b1;
            end
            if (k_prefetch_inflight_r && load_done_pulse) begin
                k_prefetch_inflight_n = 1'b0;
                k_prefetch_done_n = 1'b1;
            end

            case (state_r)
                ST_IDLE: begin
                    if (run_start_pulse) begin
                        state_n = ST_Q_LOAD_REQ;
                        q_blk_n = 4'd0;
                        kv_blk_n = 4'd0;
                        v_load_pending_n = 1'b0;
                        v_load_done_n = 1'b0;
                        k_prefetch_wanted_n = 1'b0;
                        k_prefetch_inflight_n = 1'b0;
                        k_prefetch_done_n = 1'b0;
                    end
                end
                ST_Q_LOAD_REQ: if (load_req_ready) state_n = ST_Q_LOAD_WAIT;
                ST_Q_LOAD_WAIT: if (load_done_pulse) state_n = ST_ROW_INIT_REQ;
                ST_ROW_INIT_REQ: if (row_init_ready) state_n = ST_ROW_INIT_WAIT;
                ST_ROW_INIT_WAIT: if (row_init_done_pulse) state_n = ST_OACC_CLEAR_REQ;
                ST_OACC_CLEAR_REQ: if (oacc_clear_ready) state_n = ST_OACC_CLEAR_WAIT;
                ST_OACC_CLEAR_WAIT: if (oacc_clear_done_pulse) state_n = ST_K_LOAD_REQ;
                ST_K_LOAD_REQ: if (load_req_ready) state_n = ST_K_LOAD_WAIT;
                ST_K_LOAD_WAIT: begin
                    if (load_done_pulse) begin
                        v_load_pending_n = 1'b0;
                        v_load_done_n = 1'b0;
                        state_n = ST_V_LOAD_REQ;
                    end
                end
                ST_V_LOAD_REQ: begin
                    if (load_req_ready) begin
                        v_load_pending_n = 1'b1;
                        v_load_done_n = 1'b0;
                        state_n = ST_QK_REQ;
                    end
                end
                ST_V_LOAD_WAIT: begin
                    if (v_load_done_r) begin
                        state_n = ST_PV_REQ;
                    end
                end
                ST_QK_REQ: if (qk_req_ready) state_n = ST_QK_WAIT;
                ST_QK_WAIT: begin
                    if (qk_done_pulse) begin
                        if (kv_blk_r != 4'd15) begin
                            k_prefetch_wanted_n = 1'b1;
                            k_prefetch_inflight_n = 1'b0;
                            k_prefetch_done_n = 1'b0;
                        end
                        state_n = ST_SCORE_REQ;
                    end
                end
                ST_SCORE_REQ: if (score_req_ready) state_n = ST_SCORE_WAIT;
                ST_SCORE_WAIT: begin
                    if (k_prefetch_wanted_r && !k_prefetch_inflight_r && !k_prefetch_done_r && load_req_ready) begin
                        k_prefetch_inflight_n = 1'b1;
                    end
                    if (score_done_pulse) state_n = ST_ROW_UPDATE_REQ;
                end
                ST_ROW_UPDATE_REQ: if (row_update_ready) state_n = ST_ROW_UPDATE_WAIT;
                ST_ROW_UPDATE_WAIT: begin
                    if (k_prefetch_wanted_r && !k_prefetch_inflight_r && !k_prefetch_done_r && load_req_ready) begin
                        k_prefetch_inflight_n = 1'b1;
                    end
                    if (row_update_done_pulse) begin
                        if (v_load_done_r) begin
                            state_n = ST_PV_REQ;
                        end else begin
                            state_n = ST_V_LOAD_WAIT;
                        end
                    end
                end
                ST_PV_REQ: if (pv_req_ready) state_n = ST_PV_WAIT;
                ST_PV_WAIT: begin
                    if (k_prefetch_wanted_r && !k_prefetch_inflight_r && !k_prefetch_done_r && load_req_ready) begin
                        k_prefetch_inflight_n = 1'b1;
                    end
                    if (pv_done_pulse) state_n = ST_OACC_UPDATE_REQ;
                end
                ST_OACC_UPDATE_REQ: if (oacc_update_ready) state_n = ST_OACC_UPDATE_WAIT;
                ST_OACC_UPDATE_WAIT: begin
                    if (k_prefetch_wanted_r && !k_prefetch_inflight_r && !k_prefetch_done_r && load_req_ready) begin
                        k_prefetch_inflight_n = 1'b1;
                    end
                    if (oacc_update_done_pulse) begin
                        if (kv_blk_r == 4'd15) begin
                            k_prefetch_wanted_n = 1'b0;
                            k_prefetch_inflight_n = 1'b0;
                            k_prefetch_done_n = 1'b0;
                            state_n = ST_STORE_REQ;
                        end else if (k_prefetch_done_r) begin
                            kv_blk_n = kv_blk_r + 1'b1;
                            v_load_pending_n = 1'b0;
                            v_load_done_n = 1'b0;
                            k_prefetch_wanted_n = 1'b0;
                            k_prefetch_inflight_n = 1'b0;
                            k_prefetch_done_n = 1'b0;
                            state_n = ST_V_LOAD_REQ;
                        end else begin
                            state_n = ST_K_PREFETCH_WAIT;
                        end
                    end
                end
                ST_K_PREFETCH_WAIT: begin
                    if (k_prefetch_wanted_r && !k_prefetch_inflight_r && !k_prefetch_done_r && load_req_ready) begin
                        k_prefetch_inflight_n = 1'b1;
                    end
                    if (k_prefetch_done_r) begin
                        kv_blk_n = kv_blk_r + 1'b1;
                        v_load_pending_n = 1'b0;
                        v_load_done_n = 1'b0;
                        k_prefetch_wanted_n = 1'b0;
                        k_prefetch_inflight_n = 1'b0;
                        k_prefetch_done_n = 1'b0;
                        state_n = ST_V_LOAD_REQ;
                    end
                end
                ST_STORE_REQ: begin
                    if (store_req_ready) begin
                        state_n = ST_STORE_WAIT;
                    end
                end
                ST_STORE_WAIT: begin
                    if (store_done_pulse) begin
                        if (q_blk_r == 4'd15) begin
                            state_n = ST_IDLE;
                        end else begin
                            state_n = ST_Q_LOAD_REQ;
                            q_blk_n = q_blk_r + 1'b1;
                            kv_blk_n = 4'd0;
                            v_load_pending_n = 1'b0;
                            v_load_done_n = 1'b0;
                            k_prefetch_wanted_n = 1'b0;
                            k_prefetch_inflight_n = 1'b0;
                            k_prefetch_done_n = 1'b0;
                        end
                    end
                end
                default: begin
                    state_n = ST_IDLE;
                end
            endcase
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            v_load_pending_r <= 1'b0;
            v_load_done_r <= 1'b0;
            k_prefetch_wanted_r <= 1'b0;
            k_prefetch_inflight_r <= 1'b0;
            k_prefetch_done_r <= 1'b0;
        end else if (clear || !run_active) begin
            if (run_start_pulse) begin
                state_r <= ST_Q_LOAD_REQ;
                q_blk_r <= 4'd0;
                kv_blk_r <= 4'd0;
                v_load_pending_r <= 1'b0;
                v_load_done_r <= 1'b0;
                k_prefetch_wanted_r <= 1'b0;
                k_prefetch_inflight_r <= 1'b0;
                k_prefetch_done_r <= 1'b0;
            end else begin
                state_r <= ST_IDLE;
                q_blk_r <= 4'd0;
                kv_blk_r <= 4'd0;
                v_load_pending_r <= 1'b0;
                v_load_done_r <= 1'b0;
                k_prefetch_wanted_r <= 1'b0;
                k_prefetch_inflight_r <= 1'b0;
                k_prefetch_done_r <= 1'b0;
            end
        end else begin
            state_r <= state_n;
            q_blk_r <= q_blk_n;
            kv_blk_r <= kv_blk_n;
            v_load_pending_r <= v_load_pending_n;
            v_load_done_r <= v_load_done_n;
            k_prefetch_wanted_r <= k_prefetch_wanted_n;
            k_prefetch_inflight_r <= k_prefetch_inflight_n;
            k_prefetch_done_r <= k_prefetch_done_n;
        end
    end

    always @(*) begin
        load_req_valid = 1'b0;
        load_req_kind = LOAD_KIND_Q;
        load_q_blk_idx = q_blk_r;
        load_kv_blk_idx = kv_blk_r;
        row_init_valid = 1'b0;
        oacc_clear_valid = 1'b0;
        qk_req_valid = 1'b0;
        score_req_valid = 1'b0;
        row_update_valid = 1'b0;
        pv_req_valid = 1'b0;
        oacc_update_valid = 1'b0;
        store_req_valid = 1'b0;
        run_complete_pulse = 1'b0;

        case (state_r)
            ST_Q_LOAD_REQ: begin
                load_req_valid = 1'b1;
                load_req_kind = LOAD_KIND_Q;
            end
            ST_ROW_INIT_REQ: begin
                row_init_valid = 1'b1;
            end
            ST_OACC_CLEAR_REQ: begin
                oacc_clear_valid = 1'b1;
            end
            ST_K_LOAD_REQ: begin
                load_req_valid = 1'b1;
                load_req_kind = LOAD_KIND_K;
            end
            ST_V_LOAD_REQ: begin
                load_req_valid = 1'b1;
                load_req_kind = LOAD_KIND_V;
            end
            ST_SCORE_WAIT,
            ST_ROW_UPDATE_WAIT,
            ST_PV_WAIT,
            ST_OACC_UPDATE_WAIT,
            ST_K_PREFETCH_WAIT: begin
                if (k_prefetch_wanted_r && !k_prefetch_inflight_r && !k_prefetch_done_r) begin
                    load_req_valid = 1'b1;
                    load_req_kind = LOAD_KIND_K;
                    load_kv_blk_idx = kv_blk_r + 1'b1;
                end
            end
            ST_QK_REQ: begin
                qk_req_valid = 1'b1;
            end
            ST_SCORE_REQ: begin
                score_req_valid = 1'b1;
            end
            ST_ROW_UPDATE_REQ: begin
                row_update_valid = 1'b1;
            end
            ST_PV_REQ: begin
                pv_req_valid = 1'b1;
            end
            ST_OACC_UPDATE_REQ: begin
                oacc_update_valid = 1'b1;
            end
            ST_STORE_REQ: begin
                store_req_valid = 1'b1;
            end
            ST_STORE_WAIT: begin
                if (store_done_pulse && (q_blk_r == 4'd15)) begin
                    run_complete_pulse = 1'b1;
                end
            end
            default: begin
            end
        endcase
    end

endmodule
