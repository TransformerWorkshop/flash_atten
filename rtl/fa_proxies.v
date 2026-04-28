module FA_TILE_GEMM_PROXY #(
    parameter integer LATENCY = 8
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          req_valid,
    output wire          req_ready,
    input  wire          mode_pv,
    input  wire [16383:0] q_tile_flat,
    input  wire [16383:0] k_tile_flat,
    input  wire [4095:0] p_tile_flat,
    input  wire [16383:0] v_tile_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [16383:0] result_tile_flat,
    output reg           done_pulse
);

    reg busy_r;
    integer countdown_r;
    integer row_idx;
    integer col_idx;
    integer k_idx;
    integer word_idx;
    integer elem_idx;
    reg signed [15:0] lhs_raw;
    reg signed [15:0] rhs_raw;
    reg signed [63:0] acc_val;
    reg signed [31:0] score_q16_16;
    reg signed [15:0] result_fixed;
    reg [16383:0] calc_tile;

    function automatic signed [15:0] unpack_q88_from_tile_16x64;
        input [16383:0] tile;
        input integer row;
        input integer col;
        integer idx;
        integer word_index;
        integer lane_index;
        begin
            idx = (row * 64) + col;
            word_index = idx >> 1;
            lane_index = idx & 1;
            unpack_q88_from_tile_16x64 = tile[(word_index * 32) + (lane_index * 16) +: 16];
        end
    endfunction

    function automatic signed [15:0] unpack_q88_from_tile_16x16;
        input [4095:0] tile;
        input integer row;
        input integer col;
        integer idx;
        integer word_index;
        integer lane_index;
        begin
            idx = (row * 16) + col;
            word_index = idx >> 1;
            lane_index = idx & 1;
            unpack_q88_from_tile_16x16 = tile[(word_index * 32) + (lane_index * 16) +: 16];
        end
    endfunction

    function automatic signed [31:0] clamp_q16_16_from_acc;
        input signed [63:0] value;
        begin
            if (value > 64'sh7FFF_FFFF) begin
                clamp_q16_16_from_acc = 32'sh7FFF_FFFF;
            end else if (value < -64'sh8000_0000) begin
                clamp_q16_16_from_acc = -32'sh8000_0000;
            end else begin
                clamp_q16_16_from_acc = value[31:0];
            end
        end
    endfunction

    function automatic signed [15:0] q16_16_to_q88;
        input signed [63:0] value;
        reg signed [63:0] rounded;
        begin
            if (value >= 0) begin
                rounded = value + 64'sd128;
            end else begin
                rounded = value - 64'sd128;
            end
            if (rounded > 32767) begin
                q16_16_to_q88 = 16'sh7FFF;
            end else if (rounded < -32768) begin
                q16_16_to_q88 = -16'sh8000;
            end else begin
                q16_16_to_q88 = (rounded >>> 8);
            end
        end
    endfunction

    assign req_ready = !busy_r && !resp_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            result_tile_flat <= {16384{1'b0}};
            calc_tile <= {16384{1'b0}};
            done_pulse <= 1'b0;
        end else if (clear) begin
            busy_r <= 1'b0;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            result_tile_flat <= {16384{1'b0}};
            calc_tile <= {16384{1'b0}};
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (busy_r) begin
                if (countdown_r == 0) begin
                    busy_r <= 1'b0;
                    resp_valid <= 1'b1;
                    result_tile_flat <= calc_tile;
                end else begin
                    countdown_r <= countdown_r - 1;
                end
            end else if (req_valid && req_ready) begin
                calc_tile = {16384{1'b0}};
                if (!mode_pv) begin
                    for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                        for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                            acc_val = 64'sd0;
                            for (k_idx = 0; k_idx < 64; k_idx = k_idx + 1) begin
                                lhs_raw = unpack_q88_from_tile_16x64(q_tile_flat, row_idx, k_idx);
                                rhs_raw = unpack_q88_from_tile_16x64(k_tile_flat, col_idx, k_idx);
                                acc_val = acc_val + (lhs_raw * rhs_raw);
                            end
                            score_q16_16 = clamp_q16_16_from_acc(acc_val);
                            calc_tile[((row_idx * 16) + col_idx) * 32 +: 32] = score_q16_16;
                        end
                    end
                end else begin
                    for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                        for (col_idx = 0; col_idx < 64; col_idx = col_idx + 1) begin
                            acc_val = 64'sd0;
                            for (k_idx = 0; k_idx < 16; k_idx = k_idx + 1) begin
                                lhs_raw = unpack_q88_from_tile_16x16(p_tile_flat, row_idx, k_idx);
                                rhs_raw = unpack_q88_from_tile_16x64(v_tile_flat, k_idx, col_idx);
                                acc_val = acc_val + (lhs_raw * rhs_raw);
                            end
                            word_idx = ((row_idx * 64) + col_idx) >> 1;
                            elem_idx = col_idx & 1;
                            result_fixed = q16_16_to_q88(acc_val);
                            calc_tile[(word_idx * 32) + (elem_idx * 16) +: 16] = result_fixed[15:0];
                        end
                    end
                end
                busy_r <= 1'b1;
                countdown_r <= LATENCY - 1;
            end
        end
    end

endmodule

module FA_SCORE_POST_PROXY #(
    parameter integer LATENCY = 4
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          req_valid,
    output wire          req_ready,
    input  wire [3:0]    q_blk_idx,
    input  wire [3:0]    kv_blk_idx,
    input  wire          causal_en,
    input  wire [31:0]   scale_word,
    input  wire [31:0]   neg_large_word,
    input  wire [8191:0] score_tile_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [8191:0] masked_score_tile_flat,
    output reg           done_pulse
);

    reg busy_r;
    integer countdown_r;
    integer row_idx;
    integer col_idx;
    integer global_q_idx;
    integer global_k_idx;
    reg signed [31:0] score_q16_16;
    reg signed [63:0] scaled_q32_32;
    reg [8191:0] calc_tile;

    function automatic signed [31:0] round_q32_32_to_q16_16;
        input signed [63:0] value;
        reg signed [63:0] rounded;
        begin
            if (value >= 0) begin
                rounded = value + 64'sd32768;
            end else begin
                rounded = value - 64'sd32768;
            end
            if ((rounded >>> 16) > 64'sh7FFF_FFFF) begin
                round_q32_32_to_q16_16 = 32'sh7FFF_FFFF;
            end else if ((rounded >>> 16) < -64'sh8000_0000) begin
                round_q32_32_to_q16_16 = -32'sh8000_0000;
            end else begin
                round_q32_32_to_q16_16 = (rounded >>> 16);
            end
        end
    endfunction

    assign req_ready = !busy_r && !resp_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            masked_score_tile_flat <= {8192{1'b0}};
            calc_tile <= {8192{1'b0}};
            done_pulse <= 1'b0;
        end else if (clear) begin
            busy_r <= 1'b0;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            masked_score_tile_flat <= {8192{1'b0}};
            calc_tile <= {8192{1'b0}};
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (busy_r) begin
                if (countdown_r == 0) begin
                    busy_r <= 1'b0;
                    resp_valid <= 1'b1;
                    masked_score_tile_flat <= calc_tile;
                end else begin
                    countdown_r <= countdown_r - 1;
                end
            end else if (req_valid && req_ready) begin
                calc_tile = {8192{1'b0}};
                for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                    global_q_idx = (q_blk_idx * 16) + row_idx;
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        global_k_idx = (kv_blk_idx * 16) + col_idx;
                        if (causal_en && (global_k_idx > global_q_idx)) begin
                            calc_tile[((row_idx * 16) + col_idx) * 32 +: 32] = neg_large_word;
                        end else begin
                            score_q16_16 = score_tile_flat[((row_idx * 16) + col_idx) * 32 +: 32];
                            scaled_q32_32 = $signed(score_q16_16) * $signed(scale_word);
                            calc_tile[((row_idx * 16) + col_idx) * 32 +: 32] = round_q32_32_to_q16_16(scaled_q32_32);
                        end
                    end
                end
                busy_r <= 1'b1;
                countdown_r <= LATENCY - 1;
            end
        end
    end

endmodule

module FA_ROW_STATE_PROXY #(
    parameter integer LATENCY = 2
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          init_valid,
    output wire          init_ready,
    output reg           init_done_pulse,
    input  wire          update_valid,
    output wire          update_ready,
    input  wire [31:0]   neg_large_word,
    input  wire [8191:0] masked_score_tile_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [4095:0] p_tile_flat,
    output reg  [511:0]  rescale_vec_flat,
    output reg           done_pulse
);

    localparam [1:0] OP_NONE = 2'd0;
    localparam [1:0] OP_INIT = 2'd1;
    localparam [1:0] OP_UPDATE = 2'd2;

    reg busy_r;
    reg [1:0] op_r;
    integer countdown_r;
    real m_state_r [0:15];
    real l_state_r [0:15];
    reg [4095:0] calc_p_tile;
    reg [511:0]  calc_rescale;
    integer row_idx;
    integer col_idx;
    integer word_idx;
    integer lane_idx;
    real row_max;
    real old_m;
    real old_l;
    real alpha;
    real sum_beta;
    real beta_val;
    real l_new;
    real score_real [0:15];
    real p_real;
    integer p_fixed;
    integer rescale_fixed;

    function automatic real q16_16_to_real;
        input signed [31:0] value;
        begin
            q16_16_to_real = value;
            q16_16_to_real = q16_16_to_real / 65536.0;
        end
    endfunction

    function automatic signed [15:0] real_to_q88;
        input real value;
        real scaled;
        integer rounded;
        begin
            scaled = value * 256.0;
            if (scaled >= 0.0) begin
                rounded = $rtoi(scaled + 0.5);
            end else begin
                rounded = $rtoi(scaled - 0.5);
            end
            if (rounded > 32767) begin
                real_to_q88 = 16'sh7FFF;
            end else if (rounded < -32768) begin
                real_to_q88 = -16'sh8000;
            end else begin
                real_to_q88 = rounded[15:0];
            end
        end
    endfunction

    function automatic signed [31:0] real_to_q16_16;
        input real value;
        real scaled;
        integer rounded;
        begin
            scaled = value * 65536.0;
            if (scaled >= 0.0) begin
                rounded = $rtoi(scaled + 0.5);
            end else begin
                rounded = $rtoi(scaled - 0.5);
            end
            real_to_q16_16 = rounded;
        end
    endfunction

    function automatic real exp_real;
        input real value;
        begin
            if (value < -40.0) begin
                exp_real = 0.0;
            end else begin
                exp_real = 2.718281828459045 ** value;
            end
        end
    endfunction

    assign init_ready = !busy_r && !resp_valid;
    assign update_ready = !busy_r && !resp_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            op_r <= OP_NONE;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            p_tile_flat <= {4096{1'b0}};
            rescale_vec_flat <= {512{1'b0}};
            calc_p_tile <= {4096{1'b0}};
            calc_rescale <= {512{1'b0}};
            init_done_pulse <= 1'b0;
            done_pulse <= 1'b0;
            for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                m_state_r[row_idx] <= -1.0e30;
                l_state_r[row_idx] <= 0.0;
            end
        end else if (clear) begin
            busy_r <= 1'b0;
            op_r <= OP_NONE;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            p_tile_flat <= {4096{1'b0}};
            rescale_vec_flat <= {512{1'b0}};
            calc_p_tile <= {4096{1'b0}};
            calc_rescale <= {512{1'b0}};
            init_done_pulse <= 1'b0;
            done_pulse <= 1'b0;
            for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                m_state_r[row_idx] <= -1.0e30;
                l_state_r[row_idx] <= 0.0;
            end
        end else begin
            init_done_pulse <= 1'b0;
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (busy_r) begin
                if (countdown_r == 0) begin
                    busy_r <= 1'b0;
                    if (op_r == OP_INIT) begin
                        init_done_pulse <= 1'b1;
                    end else if (op_r == OP_UPDATE) begin
                        resp_valid <= 1'b1;
                        p_tile_flat <= calc_p_tile;
                        rescale_vec_flat <= calc_rescale;
                    end
                    op_r <= OP_NONE;
                end else begin
                    countdown_r <= countdown_r - 1;
                end
            end else if (init_valid && init_ready) begin
                for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                    m_state_r[row_idx] <= -1.0e30;
                    l_state_r[row_idx] <= 0.0;
                end
                calc_p_tile <= {4096{1'b0}};
                calc_rescale <= {512{1'b0}};
                busy_r <= 1'b1;
                op_r <= OP_INIT;
                countdown_r <= LATENCY - 1;
            end else if (update_valid && update_ready) begin
                calc_p_tile = {4096{1'b0}};
                calc_rescale = {512{1'b0}};
                for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                    old_m = m_state_r[row_idx];
                    old_l = l_state_r[row_idx];
                    row_max = old_m;
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        score_real[col_idx] = q16_16_to_real(masked_score_tile_flat[((row_idx * 16) + col_idx) * 32 +: 32]);
                        if (masked_score_tile_flat[((row_idx * 16) + col_idx) * 32 +: 32] != neg_large_word) begin
                            if ((col_idx == 0) || (score_real[col_idx] > row_max)) begin
                                row_max = score_real[col_idx];
                            end
                        end
                    end
                    alpha = (old_l == 0.0) ? 0.0 : exp_real(old_m - row_max);
                    sum_beta = 0.0;
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        if (masked_score_tile_flat[((row_idx * 16) + col_idx) * 32 +: 32] == neg_large_word) begin
                            score_real[col_idx] = -1.0e30;
                            beta_val = 0.0;
                        end else begin
                            beta_val = exp_real(score_real[col_idx] - row_max);
                        end
                        sum_beta = sum_beta + beta_val;
                        score_real[col_idx] = beta_val;
                    end
                    l_new = (alpha * old_l) + sum_beta;
                    if (l_new <= 1.0e-30) begin
                        rescale_fixed = 0;
                        for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                            word_idx = ((row_idx * 16) + col_idx) >> 1;
                            lane_idx = col_idx & 1;
                            calc_p_tile[(word_idx * 32) + (lane_idx * 16) +: 16] = 16'd0;
                        end
                        m_state_r[row_idx] <= row_max;
                        l_state_r[row_idx] <= 0.0;
                    end else begin
                        rescale_fixed = real_to_q16_16((alpha * old_l) / l_new);
                        for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                            p_real = score_real[col_idx] / l_new;
                            p_fixed = real_to_q88(p_real);
                            word_idx = ((row_idx * 16) + col_idx) >> 1;
                            lane_idx = col_idx & 1;
                            calc_p_tile[(word_idx * 32) + (lane_idx * 16) +: 16] = p_fixed[15:0];
                        end
                        m_state_r[row_idx] <= row_max;
                        l_state_r[row_idx] <= l_new;
                    end
                    calc_rescale[(row_idx * 32) +: 32] = rescale_fixed[31:0];
                end
                busy_r <= 1'b1;
                op_r <= OP_UPDATE;
                countdown_r <= LATENCY - 1;
            end
        end
    end

endmodule

module FA_OACC_UPDATE_PROXY #(
    parameter integer LATENCY = 4
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          req_valid,
    output wire          req_ready,
    input  wire [511:0]  rescale_vec_flat,
    input  wire [16383:0] old_oacc_tile_flat,
    input  wire [16383:0] partial_o_tile_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [16383:0] updated_oacc_tile_flat,
    output reg           done_pulse
);

    reg busy_r;
    integer countdown_r;
    integer row_idx;
    integer col_idx;
    integer word_idx;
    integer lane_idx;
    reg signed [15:0] old_raw;
    reg signed [15:0] partial_raw;
    reg signed [31:0] scale_raw;
    reg signed [63:0] scaled_old_q24_24;
    reg signed [31:0] scaled_old_q8_8;
    reg signed [31:0] new_raw;
    reg [16383:0] calc_tile;

    function automatic signed [15:0] unpack_q88_from_tile_16x64;
        input [16383:0] tile;
        input integer row;
        input integer col;
        integer idx;
        integer word_index;
        integer lane_index;
        begin
            idx = (row * 64) + col;
            word_index = idx >> 1;
            lane_index = idx & 1;
            unpack_q88_from_tile_16x64 = tile[(word_index * 32) + (lane_index * 16) +: 16];
        end
    endfunction

    function automatic signed [15:0] clamp_q88_from_int;
        input signed [31:0] value;
        begin
            if (value > 32767) begin
                clamp_q88_from_int = 16'sh7FFF;
            end else if (value < -32768) begin
                clamp_q88_from_int = -16'sh8000;
            end else begin
                clamp_q88_from_int = value[15:0];
            end
        end
    endfunction

    assign req_ready = !busy_r && !resp_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            updated_oacc_tile_flat <= {16384{1'b0}};
            calc_tile <= {16384{1'b0}};
            done_pulse <= 1'b0;
        end else if (clear) begin
            busy_r <= 1'b0;
            countdown_r <= 0;
            resp_valid <= 1'b0;
            updated_oacc_tile_flat <= {16384{1'b0}};
            calc_tile <= {16384{1'b0}};
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (busy_r) begin
                if (countdown_r == 0) begin
                    busy_r <= 1'b0;
                    resp_valid <= 1'b1;
                    updated_oacc_tile_flat <= calc_tile;
                end else begin
                    countdown_r <= countdown_r - 1;
                end
            end else if (req_valid && req_ready) begin
                calc_tile = {16384{1'b0}};
                for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                    scale_raw = rescale_vec_flat[(row_idx * 32) +: 32];
                    for (col_idx = 0; col_idx < 64; col_idx = col_idx + 1) begin
                        old_raw = unpack_q88_from_tile_16x64(old_oacc_tile_flat, row_idx, col_idx);
                        partial_raw = unpack_q88_from_tile_16x64(partial_o_tile_flat, row_idx, col_idx);
                        scaled_old_q24_24 = $signed(old_raw) * $signed(scale_raw);
                        if (scaled_old_q24_24 >= 0) begin
                            scaled_old_q8_8 = (scaled_old_q24_24 + 64'sd32768) >>> 16;
                        end else begin
                            scaled_old_q8_8 = (scaled_old_q24_24 - 64'sd32768) >>> 16;
                        end
                        new_raw = scaled_old_q8_8 + partial_raw;
                        word_idx = ((row_idx * 64) + col_idx) >> 1;
                        lane_idx = col_idx & 1;
                        calc_tile[(word_idx * 32) + (lane_idx * 16) +: 16] = clamp_q88_from_int(new_raw);
                    end
                end
                busy_r <= 1'b1;
                countdown_r <= LATENCY - 1;
            end
        end
    end

endmodule
