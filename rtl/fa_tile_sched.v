module FA_TILE_SCHED (
    input  wire       clk,
    input  wire       rstn,
    input  wire       clear,
    input  wire       run_active,
    input  wire       run_start_pulse,
    output wire [3:0] q_blk_idx,
    output wire [3:0] kv_blk_idx,
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

    localparam [1:0] LOAD_KIND_Q = 2'd0;
    localparam [1:0] LOAD_KIND_K = 2'd1;
    localparam [1:0] LOAD_KIND_V = 2'd2;

    reg [4:0] state_r;
    reg [3:0] q_blk_r;
    reg [3:0] kv_blk_r;

    assign q_blk_idx = q_blk_r;
    assign kv_blk_idx = kv_blk_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
        end else if (clear || !run_active) begin
            if (run_start_pulse) begin
                state_r <= ST_Q_LOAD_REQ;
                q_blk_r <= 4'd0;
                kv_blk_r <= 4'd0;
            end else begin
                state_r <= ST_IDLE;
                q_blk_r <= 4'd0;
                kv_blk_r <= 4'd0;
            end
        end else begin
            case (state_r)
                ST_IDLE: begin
                    if (run_start_pulse) begin
                        state_r <= ST_Q_LOAD_REQ;
                        q_blk_r <= 4'd0;
                        kv_blk_r <= 4'd0;
                    end
                end
                ST_Q_LOAD_REQ:      if (load_req_ready) state_r <= ST_Q_LOAD_WAIT;
                ST_Q_LOAD_WAIT:     if (load_done_pulse) state_r <= ST_ROW_INIT_REQ;
                ST_ROW_INIT_REQ:    if (row_init_ready) state_r <= ST_ROW_INIT_WAIT;
                ST_ROW_INIT_WAIT:   if (row_init_done_pulse) state_r <= ST_OACC_CLEAR_REQ;
                ST_OACC_CLEAR_REQ:  if (oacc_clear_ready) state_r <= ST_OACC_CLEAR_WAIT;
                ST_OACC_CLEAR_WAIT: if (oacc_clear_done_pulse) state_r <= ST_K_LOAD_REQ;
                ST_K_LOAD_REQ:      if (load_req_ready) state_r <= ST_K_LOAD_WAIT;
                ST_K_LOAD_WAIT:     if (load_done_pulse) state_r <= ST_V_LOAD_REQ;
                ST_V_LOAD_REQ:      if (load_req_ready) state_r <= ST_V_LOAD_WAIT;
                ST_V_LOAD_WAIT:     if (load_done_pulse) state_r <= ST_QK_REQ;
                ST_QK_REQ:          if (qk_req_ready) state_r <= ST_QK_WAIT;
                ST_QK_WAIT:         if (qk_done_pulse) state_r <= ST_SCORE_REQ;
                ST_SCORE_REQ:       if (score_req_ready) state_r <= ST_SCORE_WAIT;
                ST_SCORE_WAIT:      if (score_done_pulse) state_r <= ST_ROW_UPDATE_REQ;
                ST_ROW_UPDATE_REQ:  if (row_update_ready) state_r <= ST_ROW_UPDATE_WAIT;
                ST_ROW_UPDATE_WAIT: if (row_update_done_pulse) state_r <= ST_PV_REQ;
                ST_PV_REQ:          if (pv_req_ready) state_r <= ST_PV_WAIT;
                ST_PV_WAIT:         if (pv_done_pulse) state_r <= ST_OACC_UPDATE_REQ;
                ST_OACC_UPDATE_REQ: if (oacc_update_ready) state_r <= ST_OACC_UPDATE_WAIT;
                ST_OACC_UPDATE_WAIT: begin
                    if (oacc_update_done_pulse) begin
                        if (kv_blk_r == 4'd15) begin
                            state_r <= ST_STORE_REQ;
                        end else begin
                            state_r <= ST_K_LOAD_REQ;
                            kv_blk_r <= kv_blk_r + 1'b1;
                        end
                    end
                end
                ST_STORE_REQ: begin
                    if (store_req_ready) begin
                        state_r <= ST_STORE_WAIT;
                    end
                end
                ST_STORE_WAIT: begin
                    if (store_done_pulse) begin
                        if (q_blk_r == 4'd15) begin
                            state_r <= ST_IDLE;
                        end else begin
                            state_r <= ST_Q_LOAD_REQ;
                            q_blk_r <= q_blk_r + 1'b1;
                            kv_blk_r <= 4'd0;
                        end
                    end
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end

    always @(*) begin
        load_req_valid = 1'b0;
        load_req_kind = LOAD_KIND_Q;
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
