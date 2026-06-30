`timescale 1ns/1ps

module fa_optim_4x4_windowed_loop_tb;
    localparam integer EXPECTED_Q_GROUPS = 4;
    localparam integer EXPECTED_KV_WINDOWS = 16;
    localparam integer EXPECTED_Q_TILE_REQS = 256;
    localparam integer EXPECTED_Q_TILE_BEATS = 16384;
    localparam integer EXPECTED_K_TILE_REQS = 64;
    localparam integer EXPECTED_K_TILE_BEATS = 16384;
    localparam integer EXPECTED_V_TILE_REQS = 64;
    localparam integer EXPECTED_V_TILE_BEATS = 16384;
    localparam integer EXPECTED_MICRO_TILES = 1024;
    localparam integer EXPECTED_CORE_STARTS = 256;
    localparam integer EXPECTED_RESTORE_STARTS = 192;
    localparam integer EXPECTED_QK_TASKS = 131072;
    localparam integer EXPECTED_PV_TASKS = 131072;
    localparam integer EXPECTED_OACC_TASKS = 1024;
    localparam integer MAX_EXPECTED_CYCLES = 600000;
    localparam integer NUMERIC_MODE_UNIFORM_Q = 0;
    localparam integer NUMERIC_MODE_DENSE_QK = 1;
    localparam integer NUMERIC_MODE = NUMERIC_MODE_DENSE_QK;

    reg clk;
    reg rstn;
    reg clear;
    reg start;
    wire q_tile_req_valid;
    reg q_tile_req_ready;
    wire [5:0] q_tile_req_q_idx;
    reg q_tile_beat_valid;
    wire q_tile_beat_ready;
    reg [1:0] q_tile_beat_row_idx;
    reg [3:0] q_tile_beat_chunk_idx;
    reg [63:0] q_tile_beat_data;
    reg q_tile_beat_last;
    wire k_tile_req_valid;
    reg k_tile_req_ready;
    wire [4:0] k_tile_req_kv_idx;
    reg k_tile_beat_valid;
    wire k_tile_beat_ready;
    reg [3:0] k_tile_beat_row_idx;
    reg [3:0] k_tile_beat_chunk_idx;
    reg [63:0] k_tile_beat_data;
    reg k_tile_beat_last;
    wire v_tile_req_valid;
    reg v_tile_req_ready;
    wire [4:0] v_tile_req_kv_idx;
    reg v_tile_beat_valid;
    wire v_tile_beat_ready;
    reg [3:0] v_tile_beat_row_idx;
    reg [3:0] v_tile_beat_chunk_idx;
    reg [63:0] v_tile_beat_data;
    reg v_tile_beat_last;
    wire busy;
    wire done;
    wire error;
    wire [31:0] cycles;
    wire [31:0] micro_tile_count;
    wire [31:0] q_group_count;
    wire [31:0] kv_window_count;
    wire [31:0] q_tile_visit_count;
    wire [31:0] kv_tile_count;
    wire [31:0] q_tile_req_count;
    wire [31:0] q_tile_beat_count;
    wire [31:0] k_tile_req_count;
    wire [31:0] k_tile_beat_count;
    wire [31:0] v_tile_req_count;
    wire [31:0] v_tile_beat_count;
    wire [31:0] state_fill_count;
    wire [31:0] state_spill_count;
    wire [31:0] qk_task_count;
    wire [31:0] pv_task_count;
    wire [31:0] oacc_task_count;
    wire o_dump_valid;
    wire [1:0] o_dump_group_idx;
    wire [10:0] o_dump_word_idx;
    wire [31:0] o_dump_word;
    wire o_dump_last;
    wire [4095:0] o_block_flat;

    integer error_count;
    integer wait_count;
    integer q_req_seen_count;
    integer k_req_seen_count;
    integer v_req_seen_count;
    integer core_start_count;
    integer restore_start_count;
    integer row_i;
    integer col_i;
    reg expected_v_resp_valid_r;
    reg [511:0] expected_v_resp_data_r;
    reg [31:0] dense_qk_o_checksum;

    FA_OPTIM_4X4_WINDOWED_LOOP dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .causal_en(1'b0),
        .q_tile_req_valid(q_tile_req_valid),
        .q_tile_req_ready(q_tile_req_ready),
        .q_tile_req_q_idx(q_tile_req_q_idx),
        .q_tile_beat_valid(q_tile_beat_valid),
        .q_tile_beat_ready(q_tile_beat_ready),
        .q_tile_beat_row_idx(q_tile_beat_row_idx),
        .q_tile_beat_chunk_idx(q_tile_beat_chunk_idx),
        .q_tile_beat_data(q_tile_beat_data),
        .q_tile_beat_last(q_tile_beat_last),
        .k_tile_req_valid(k_tile_req_valid),
        .k_tile_req_ready(k_tile_req_ready),
        .k_tile_req_kv_idx(k_tile_req_kv_idx),
        .k_tile_beat_valid(k_tile_beat_valid),
        .k_tile_beat_ready(k_tile_beat_ready),
        .k_tile_beat_row_idx(k_tile_beat_row_idx),
        .k_tile_beat_chunk_idx(k_tile_beat_chunk_idx),
        .k_tile_beat_data(k_tile_beat_data),
        .k_tile_beat_last(k_tile_beat_last),
        .v_tile_req_valid(v_tile_req_valid),
        .v_tile_req_ready(v_tile_req_ready),
        .v_tile_req_kv_idx(v_tile_req_kv_idx),
        .v_tile_beat_valid(v_tile_beat_valid),
        .v_tile_beat_ready(v_tile_beat_ready),
        .v_tile_beat_row_idx(v_tile_beat_row_idx),
        .v_tile_beat_chunk_idx(v_tile_beat_chunk_idx),
        .v_tile_beat_data(v_tile_beat_data),
        .v_tile_beat_last(v_tile_beat_last),
        .busy(busy),
        .done(done),
        .error(error),
        .cycles(cycles),
        .micro_tile_count(micro_tile_count),
        .q_group_count(q_group_count),
        .kv_window_count(kv_window_count),
        .q_tile_visit_count(q_tile_visit_count),
        .kv_tile_count(kv_tile_count),
        .q_tile_req_count(q_tile_req_count),
        .q_tile_beat_count(q_tile_beat_count),
        .k_tile_req_count(k_tile_req_count),
        .k_tile_beat_count(k_tile_beat_count),
        .v_tile_req_count(v_tile_req_count),
        .v_tile_beat_count(v_tile_beat_count),
        .state_fill_count(state_fill_count),
        .state_spill_count(state_spill_count),
        .qk_task_count(qk_task_count),
        .pv_task_count(pv_task_count),
        .oacc_task_count(oacc_task_count),
        .o_dump_valid(o_dump_valid),
        .o_dump_ready(1'b1),
        .o_dump_group_idx(o_dump_group_idx),
        .o_dump_word_idx(o_dump_word_idx),
        .o_dump_word(o_dump_word),
        .o_dump_last(o_dump_last),
        .o_block_flat(o_block_flat)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task expect32;
        input [31:0] actual;
        input [31:0] expected;
        input [8*56-1:0] name;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %0d got %0d at %0t",
                         name, expected, actual, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task expect64;
        input [63:0] actual;
        input [63:0] expected;
        input [8*64-1:0] name;
        begin
            if (actual !== expected) begin
                if (error_count < 16) begin
                    $display("FAIL: %0s expected 0x%016h got 0x%016h at %0t",
                             name, expected, actual, $time);
                end
                error_count = error_count + 1;
            end
        end
    endtask

    function [5:0] expected_q_tile_idx;
        input integer req_index;
        integer group_idx;
        integer tile_in_group;
        begin
            group_idx = req_index / 64;
            tile_in_group = req_index % 16;
            expected_q_tile_idx = (group_idx * 16) + tile_in_group;
        end
    endfunction

    function [4:0] expected_kv_tile_idx;
        input integer req_index;
        integer group_idx;
        integer window_idx;
        integer slot_idx;
        begin
            group_idx = req_index / 16;
            window_idx = (req_index % 16) / 4;
            slot_idx = req_index % 4;
            expected_kv_tile_idx = (window_idx * 4) + slot_idx;
        end
    endfunction

    function [15:0] make_k_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input integer col_idx;
        begin
            if (NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) begin
                make_k_word = 16'h0001
                            + {13'd0, (row_idx[1:0] + kv_tile_idx[1:0])}
                            + {13'd0, col_idx[1:0]};
            end else begin
                make_k_word = 16'h2000
                            + ({12'd0, kv_tile_idx[3:0]} << 10)
                            + ({12'd0, row_idx} << 6)
                            + col_idx[15:0];
            end
        end
    endfunction

    function [63:0] make_k_beat;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [3:0] chunk_idx;
        integer base_col;
        begin
            base_col = chunk_idx * 4;
            make_k_beat = {
                make_k_word(kv_tile_idx, row_idx, base_col + 3),
                make_k_word(kv_tile_idx, row_idx, base_col + 2),
                make_k_word(kv_tile_idx, row_idx, base_col + 1),
                make_k_word(kv_tile_idx, row_idx, base_col + 0)
            };
        end
    endfunction

    function [15:0] make_v_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input integer col_idx;
        begin
            make_v_word = 16'h0010 + ({12'd0, kv_tile_idx[3:0]} << 4)
                        + {12'd0, row_idx} + col_idx[15:0];
        end
    endfunction

    function [63:0] make_v_beat;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [3:0] chunk_idx;
        integer base_col;
        begin
            base_col = chunk_idx * 4;
            make_v_beat = {
                make_v_word(kv_tile_idx, row_idx, base_col + 3),
                make_v_word(kv_tile_idx, row_idx, base_col + 2),
                make_v_word(kv_tile_idx, row_idx, base_col + 1),
                make_v_word(kv_tile_idx, row_idx, base_col + 0)
            };
        end
    endfunction

    function [63:0] make_zero_q_beat;
        input integer unused_tile_idx;
        input integer unused_row_idx;
        input integer unused_chunk_idx;
        begin
            make_zero_q_beat = 64'd0;
        end
    endfunction

    function [15:0] make_q_word;
        input [5:0] q_tile_idx;
        input integer row_idx;
        input integer col_idx;
        begin
            if (NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) begin
                make_q_word = 16'h0001
                            + {13'd0, (row_idx[1:0] + q_tile_idx[1:0])}
                            + {13'd0, col_idx[1:0]};
            end else begin
                make_q_word = 16'd0;
            end
        end
    endfunction

    function [63:0] make_q_beat;
        input [5:0] q_tile_idx;
        input integer row_idx;
        input [3:0] chunk_idx;
        integer base_col;
        begin
            base_col = chunk_idx * 4;
            make_q_beat = {
                make_q_word(q_tile_idx, row_idx, base_col + 3),
                make_q_word(q_tile_idx, row_idx, base_col + 2),
                make_q_word(q_tile_idx, row_idx, base_col + 1),
                make_q_word(q_tile_idx, row_idx, base_col + 0)
            };
        end
    endfunction

    function [63:0] k_window_word;
        input [3:0] bank_idx;
        input [7:0] addr;
        begin
            case (bank_idx)
                4'd0:  k_window_word = dut.gen_k_tile_sram_bank[0].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd1:  k_window_word = dut.gen_k_tile_sram_bank[1].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd2:  k_window_word = dut.gen_k_tile_sram_bank[2].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd3:  k_window_word = dut.gen_k_tile_sram_bank[3].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd4:  k_window_word = dut.gen_k_tile_sram_bank[4].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd5:  k_window_word = dut.gen_k_tile_sram_bank[5].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd6:  k_window_word = dut.gen_k_tile_sram_bank[6].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd7:  k_window_word = dut.gen_k_tile_sram_bank[7].u_k_tile_sram.u_sram.u_sram.mem[addr];
                default: k_window_word = 64'hxxxx_xxxx_xxxx_xxxx;
            endcase
        end
    endfunction

    task check_k_sram_window_layout;
        input [4:0] kv_tile_idx;
        integer check_row_i;
        integer check_chunk_i;
        reg [1:0] window_slot_idx;
        reg [3:0] check_row_idx;
        reg [3:0] check_chunk_idx;
        reg [7:0] window_addr;
        reg [3:0] row_pair_idx;
        reg [63:0] expected_row0_beat;
        reg [63:0] expected_row1_beat;
        reg [63:0] expected_pair0_word;
        reg [63:0] expected_pair1_word;
        begin
            window_slot_idx = kv_tile_idx[1:0];
            for (check_row_i = 0; check_row_i < 8; check_row_i = check_row_i + 1) begin
                for (check_chunk_i = 0; check_chunk_i < 16; check_chunk_i = check_chunk_i + 1) begin
                    row_pair_idx = check_row_i[3:0];
                    check_row_idx = {check_row_i[2:0], 1'b0};
                    check_chunk_idx = check_chunk_i[3:0];
                    window_addr = {1'b0, window_slot_idx, check_chunk_idx, 1'b0};
                    expected_row0_beat =
                        make_k_beat(kv_tile_idx, check_row_idx, check_chunk_idx);
                    expected_row1_beat =
                        make_k_beat(kv_tile_idx, check_row_idx + 4'd1, check_chunk_idx);
                    expected_pair0_word = {
                        expected_row1_beat[31:0],
                        expected_row0_beat[31:0]
                    };
                    expected_pair1_word = {
                        expected_row1_beat[63:32],
                        expected_row0_beat[63:32]
                    };
                    expect64(k_window_word(row_pair_idx, window_addr),
                             expected_pair0_word,
                             "k_window_word");
                    expect64(k_window_word(row_pair_idx, window_addr + 8'd1),
                             expected_pair1_word,
                             "k_window_word_pair1");
                end
            end
        end
    endtask

    task drive_q_tile_beats;
        reg [5:0] req_q_idx;
        reg [5:0] expected_idx;
        integer drive_row_i;
        integer drive_chunk_i;
        begin
            wait (q_tile_req_valid === 1'b1);
            req_q_idx = q_tile_req_q_idx;
            expected_idx = expected_q_tile_idx(q_req_seen_count);
            if (req_q_idx !== expected_idx) begin
                $display("FAIL: q request index expected %0d got %0d at request %0d",
                         expected_idx, req_q_idx, q_req_seen_count);
                error_count = error_count + 1;
            end
            q_req_seen_count = q_req_seen_count + 1;
            tick();
            for (drive_row_i = 0; drive_row_i < 4; drive_row_i = drive_row_i + 1) begin
                for (drive_chunk_i = 0; drive_chunk_i < 16; drive_chunk_i = drive_chunk_i + 1) begin
                    q_tile_beat_valid = 1'b1;
                    q_tile_beat_row_idx = drive_row_i[1:0];
                    q_tile_beat_chunk_idx = drive_chunk_i[3:0];
                    if (NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) begin
                        q_tile_beat_data = make_q_beat(req_q_idx, drive_row_i, drive_chunk_i[3:0]);
                    end else begin
                        q_tile_beat_data = make_zero_q_beat(req_q_idx, drive_row_i, drive_chunk_i);
                    end
                    q_tile_beat_last = (drive_row_i == 3) && (drive_chunk_i == 15);
                    while (q_tile_beat_ready !== 1'b1) begin
                        tick();
                    end
                    tick();
                end
            end
            q_tile_beat_valid = 1'b0;
            q_tile_beat_row_idx = 2'd0;
            q_tile_beat_chunk_idx = 4'd0;
            q_tile_beat_data = 64'd0;
            q_tile_beat_last = 1'b0;
        end
    endtask

    task drive_k_tile_beats;
        reg [4:0] req_kv_idx;
        reg [4:0] expected_idx;
        integer drive_row_i;
        integer drive_chunk_i;
        begin
            wait (k_tile_req_valid === 1'b1);
            req_kv_idx = k_tile_req_kv_idx;
            expected_idx = expected_kv_tile_idx(k_req_seen_count);
            if (req_kv_idx !== expected_idx) begin
                $display("FAIL: k request index expected %0d got %0d at request %0d",
                         expected_idx, req_kv_idx, k_req_seen_count);
                error_count = error_count + 1;
            end
            k_req_seen_count = k_req_seen_count + 1;
            tick();
            for (drive_row_i = 0; drive_row_i < 16; drive_row_i = drive_row_i + 1) begin
                for (drive_chunk_i = 0; drive_chunk_i < 16; drive_chunk_i = drive_chunk_i + 1) begin
                    k_tile_beat_valid = 1'b1;
                    k_tile_beat_row_idx = drive_row_i[3:0];
                    k_tile_beat_chunk_idx = drive_chunk_i[3:0];
                    k_tile_beat_data = make_k_beat(req_kv_idx, drive_row_i[3:0],
                                                   drive_chunk_i[3:0]);
                    k_tile_beat_last = (drive_row_i == 15) && (drive_chunk_i == 15);
                    while (k_tile_beat_ready !== 1'b1) begin
                        tick();
                    end
                    tick();
                end
            end
            k_tile_beat_valid = 1'b0;
            k_tile_beat_row_idx = 4'd0;
            k_tile_beat_chunk_idx = 4'd0;
            k_tile_beat_data = 64'd0;
            k_tile_beat_last = 1'b0;
            while (dut.k_pack_pending_r === 1'b1) begin
                tick();
            end
            check_k_sram_window_layout(req_kv_idx);
        end
    endtask

    task drive_v_tile_beats;
        reg [4:0] req_kv_idx;
        reg [4:0] expected_idx;
        integer drive_row_i;
        integer drive_chunk_i;
        begin
            wait (v_tile_req_valid === 1'b1);
            req_kv_idx = v_tile_req_kv_idx;
            expected_idx = expected_kv_tile_idx(v_req_seen_count);
            if (req_kv_idx !== expected_idx) begin
                $display("FAIL: v request index expected %0d got %0d at request %0d",
                         expected_idx, req_kv_idx, v_req_seen_count);
                error_count = error_count + 1;
            end
            v_req_seen_count = v_req_seen_count + 1;
            tick();
            for (drive_row_i = 0; drive_row_i < 16; drive_row_i = drive_row_i + 1) begin
                for (drive_chunk_i = 0; drive_chunk_i < 16; drive_chunk_i = drive_chunk_i + 1) begin
                    v_tile_beat_valid = 1'b1;
                    v_tile_beat_row_idx = drive_row_i[3:0];
                    v_tile_beat_chunk_idx = drive_chunk_i[3:0];
                    v_tile_beat_data = make_v_beat(req_kv_idx, drive_row_i[3:0],
                                                   drive_chunk_i[3:0]);
                    v_tile_beat_last = (drive_row_i == 15) && (drive_chunk_i == 15);
                    while (v_tile_beat_ready !== 1'b1) begin
                        tick();
                    end
                    tick();
                end
            end
            v_tile_beat_valid = 1'b0;
            v_tile_beat_row_idx = 4'd0;
            v_tile_beat_chunk_idx = 4'd0;
            v_tile_beat_data = 64'd0;
            v_tile_beat_last = 1'b0;
        end
    endtask

    task drive_all_tiles;
        begin
            while (done !== 1'b1) begin
                if (k_tile_req_valid === 1'b1) begin
                    drive_k_tile_beats();
                end else if (v_tile_req_valid === 1'b1) begin
                    drive_v_tile_beats();
                end else if (q_tile_req_valid === 1'b1) begin
                    drive_q_tile_beats();
                end else begin
                    tick();
                end
            end
        end
    endtask

    function [15:0] get_o_word;
        input integer row;
        input integer col;
        begin
            get_o_word = o_block_flat[(row * 1024) + (col * 16) +: 16];
        end
    endfunction

    function signed [31:0] tb_q16_add_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [32:0] sum_ext;
        begin
            sum_ext = lhs + rhs;
            if (sum_ext > 33'sh0_7FFF_FFFF) begin
                tb_q16_add_sat = 32'sh7FFF_FFFF;
            end else if (sum_ext < -33'sh0_8000_0000) begin
                tb_q16_add_sat = -32'sh8000_0000;
            end else begin
                tb_q16_add_sat = sum_ext[31:0];
            end
        end
    endfunction

    function signed [31:0] tb_q16_mul_rn_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [63:0] prod;
        reg signed [63:0] rounded;
        reg signed [63:0] shifted;
        begin
            prod = lhs * rhs;
            if (prod >= 0) begin
                rounded = prod + 64'sd32768;
            end else begin
                rounded = prod - 64'sd32768;
            end
            shifted = rounded >>> 16;
            if (shifted > 64'sh0000_0000_7FFF_FFFF) begin
                tb_q16_mul_rn_sat = 32'sh7FFF_FFFF;
            end else if (shifted < -64'sh0000_0000_8000_0000) begin
                tb_q16_mul_rn_sat = -32'sh8000_0000;
            end else begin
                tb_q16_mul_rn_sat = shifted[31:0];
            end
        end
    endfunction

    function signed [31:0] tb_q16_clamp_nonpos_neg8;
        input signed [31:0] value;
        begin
            if (value > 32'sd0) begin
                tb_q16_clamp_nonpos_neg8 = 32'sd0;
            end else if (value < -32'sd524288) begin
                tb_q16_clamp_nonpos_neg8 = -32'sd524288;
            end else begin
                tb_q16_clamp_nonpos_neg8 = value;
            end
        end
    endfunction

    function [8:0] tb_q16_delta_to_exp_idx;
        input signed [31:0] delta;
        reg signed [31:0] clamped;
        reg [31:0] abs_mag;
        reg [31:0] rounded;
        reg [31:0] shifted;
        begin
            clamped = tb_q16_clamp_nonpos_neg8(delta);
            abs_mag = -clamped;
            rounded = abs_mag + 32'd1024;
            shifted = rounded >> 11;
            if (shifted > 32'd256) begin
                tb_q16_delta_to_exp_idx = 9'd256;
            end else begin
                tb_q16_delta_to_exp_idx = shifted[8:0];
            end
        end
    endfunction

    function [31:0] fa_exp_lut_q16_16;
        input [8:0] idx;
        begin
            case (idx)
`include "fa_exp_lut_q16_16.vh"
                default: fa_exp_lut_q16_16 = 32'h00000016;
            endcase
        end
    endfunction

    function signed [15:0] tb_q16_to_q88_rn_sat;
        input signed [31:0] value;
        reg signed [31:0] rounded;
        reg signed [31:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 32'sd128;
            end else begin
                rounded = value - 32'sd128;
            end
            shifted = rounded >>> 8;
            if (shifted > 32'sd32767) begin
                tb_q16_to_q88_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                tb_q16_to_q88_rn_sat = -16'sh8000;
            end else begin
                tb_q16_to_q88_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function signed [15:0] tb_q16_to_q412_rn_sat;
        input signed [31:0] value;
        reg signed [31:0] rounded;
        reg signed [31:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 32'sd8;
            end else begin
                rounded = value - 32'sd8;
            end
            shifted = rounded >>> 4;
            if (shifted > 32'sd32767) begin
                tb_q16_to_q412_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                tb_q16_to_q412_rn_sat = -16'sh8000;
            end else begin
                tb_q16_to_q412_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function signed [15:0] tb_q16_16_to_q88_sat128;
        input signed [127:0] value;
        reg signed [127:0] rounded;
        reg signed [127:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 128'sd128;
            end else begin
                rounded = value - 128'sd128;
            end
            shifted = rounded >>> 8;
            if (shifted > 128'sd32767) begin
                tb_q16_16_to_q88_sat128 = 16'sh7FFF;
            end else if (shifted < -128'sd32768) begin
                tb_q16_16_to_q88_sat128 = -16'sh8000;
            end else begin
                tb_q16_16_to_q88_sat128 = shifted[15:0];
            end
        end
    endfunction

    function signed [31:0] tb_q88_to_q16;
        input signed [15:0] value;
        begin
            tb_q88_to_q16 = {{8{value[15]}}, value, 8'd0};
        end
    endfunction

    function signed [31:0] tb_q412_to_q16;
        input signed [15:0] value;
        begin
            tb_q412_to_q16 = {{12{value[15]}}, value, 4'd0};
        end
    endfunction

    function [31:0] tb_recip_q16_16;
        input [31:0] in_value;
        reg [63:0] dividend;
        reg [63:0] divisor;
        reg [63:0] quotient;
        begin
            dividend = 64'h1_0000_0000;
            divisor = {32'd0, in_value};
            if ((in_value[31] == 1'b1) || (in_value == 32'd0)) begin
                quotient = 64'd0;
            end else begin
                quotient = dividend / divisor;
            end
            if (quotient > 64'h7FFF_FFFF) begin
                tb_recip_q16_16 = 32'h7FFF_FFFF;
            end else begin
                tb_recip_q16_16 = quotient[31:0];
            end
        end
    endfunction

    function [15:0] tb_update_oacc_elem;
        input signed [15:0] old_q412_word;
        input signed [31:0] scale_word;
        input signed [15:0] partial_q88_word;
        reg signed [31:0] old_q16_v;
        reg signed [31:0] scaled_old_q16_v;
        reg signed [31:0] partial_q16_v;
        reg signed [31:0] next_q16_v;
        begin
            old_q16_v = tb_q412_to_q16(old_q412_word);
            scaled_old_q16_v = tb_q16_mul_rn_sat(old_q16_v, scale_word);
            partial_q16_v = tb_q88_to_q16(partial_q88_word);
            next_q16_v = tb_q16_add_sat(scaled_old_q16_v, partial_q16_v);
            tb_update_oacc_elem = tb_q16_to_q412_rn_sat(next_q16_v);
        end
    endfunction

    function signed [31:0] expected_score_q16;
        input integer q_tile_idx;
        input integer q_row;
        input integer kv_tile_idx;
        input integer kv_col;
        integer dim_i;
        reg signed [15:0] q_q88;
        reg signed [15:0] k_q88;
        reg signed [127:0] acc_q16;
        begin
            acc_q16 = 128'sd0;
            for (dim_i = 0; dim_i < 64; dim_i = dim_i + 1) begin
                q_q88 = make_q_word(q_tile_idx[5:0], q_row, dim_i);
                k_q88 = make_k_word(kv_tile_idx[4:0], kv_col[3:0], dim_i);
                acc_q16 = acc_q16 + ($signed(q_q88) * $signed(k_q88));
            end
            if (acc_q16 > 128'sh0000000000000000000000007FFF_FFFF) begin
                expected_score_q16 = 32'sh7FFF_FFFF;
            end else if (acc_q16 < -128'sh0000000000000000000000008000_0000) begin
                expected_score_q16 = -32'sh8000_0000;
            end else begin
                expected_score_q16 = acc_q16[31:0];
            end
        end
    endfunction

    function [15:0] expected_o_word_all_tiles;
        input integer col;
        integer kv_i;
        integer row_idx;
        reg signed [31:0] old_l_q16;
        reg signed [31:0] new_l_q16;
        reg signed [31:0] recip_q16;
        reg signed [31:0] scale_q16;
        reg signed [31:0] p_q16;
        reg signed [15:0] p_q88;
        reg signed [15:0] v_q88;
        reg signed [15:0] partial_q88;
        reg signed [15:0] old_o_q412;
        reg signed [127:0] partial_acc_q16;
        begin
            old_l_q16 = 32'sd0;
            old_o_q412 = 16'sd0;
            for (kv_i = 0; kv_i < 16; kv_i = kv_i + 1) begin
                new_l_q16 = old_l_q16 + 32'sd1048576;
                recip_q16 = tb_recip_q16_16(new_l_q16);
                p_q16 = tb_q16_mul_rn_sat(32'sh0001_0000, recip_q16);
                p_q88 = tb_q16_to_q88_rn_sat(p_q16);
                partial_acc_q16 = 128'sd0;
                for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
                    v_q88 = make_v_word(kv_i, row_idx, col);
                    partial_acc_q16 = partial_acc_q16 + ($signed(p_q88) * $signed(v_q88));
                end
                partial_q88 = tb_q16_16_to_q88_sat128(partial_acc_q16);
                if (old_l_q16 == 32'sd0) begin
                    scale_q16 = 32'sd0;
                end else begin
                    scale_q16 = tb_q16_mul_rn_sat(old_l_q16, recip_q16);
                end
                old_o_q412 = tb_update_oacc_elem(old_o_q412, scale_q16, partial_q88);
                old_l_q16 = new_l_q16;
            end
            expected_o_word_all_tiles = old_o_q412;
        end
    endfunction

    function [15:0] expected_o_word_dense_qk;
        input integer row;
        input integer col;
        integer kv_i;
        integer key_col_i;
        reg signed [31:0] old_m_q16;
        reg signed [31:0] old_l_q16;
        reg signed [31:0] new_m_q16;
        reg signed [31:0] old_score_q16;
        reg signed [31:0] score_q16;
        reg signed [31:0] alpha_q16;
        reg signed [31:0] alpha_l_old_q16;
        reg signed [31:0] beta_q16 [0:15];
        reg signed [31:0] beta_sum_q16;
        reg signed [31:0] new_l_q16;
        reg signed [31:0] recip_q16;
        reg signed [31:0] scale_q16;
        reg signed [31:0] p_q16;
        reg signed [15:0] p_q88;
        reg signed [15:0] v_q88;
        reg signed [15:0] partial_q88;
        reg signed [15:0] old_o_q412;
        reg signed [127:0] partial_acc_q16;
        begin
            old_m_q16 = 32'hffc0_0000;
            old_l_q16 = 32'sd0;
            old_o_q412 = 16'sd0;
            for (kv_i = 0; kv_i < 16; kv_i = kv_i + 1) begin
                new_m_q16 = expected_score_q16(63, row, kv_i, 0);
                for (key_col_i = 1; key_col_i < 16; key_col_i = key_col_i + 1) begin
                    score_q16 = expected_score_q16(63, row, kv_i, key_col_i);
                    if (score_q16 > new_m_q16) begin
                        new_m_q16 = score_q16;
                    end
                end
                if (old_l_q16 != 32'sd0) begin
                    if (old_m_q16 > new_m_q16) begin
                        new_m_q16 = old_m_q16;
                    end
                    alpha_q16 = fa_exp_lut_q16_16(
                        tb_q16_delta_to_exp_idx(old_m_q16 - new_m_q16));
                    alpha_l_old_q16 = tb_q16_mul_rn_sat(alpha_q16, old_l_q16);
                end else begin
                    alpha_l_old_q16 = 32'sd0;
                end

                beta_sum_q16 = 32'sd0;
                for (key_col_i = 0; key_col_i < 16; key_col_i = key_col_i + 1) begin
                    old_score_q16 = expected_score_q16(63, row, kv_i, key_col_i);
                    beta_q16[key_col_i] = fa_exp_lut_q16_16(
                        tb_q16_delta_to_exp_idx(old_score_q16 - new_m_q16));
                    beta_sum_q16 = tb_q16_add_sat(beta_sum_q16, beta_q16[key_col_i]);
                end
                new_l_q16 = tb_q16_add_sat(alpha_l_old_q16, beta_sum_q16);
                recip_q16 = tb_recip_q16_16(new_l_q16);

                if (old_l_q16 == 32'sd0) begin
                    scale_q16 = 32'sd0;
                end else begin
                    scale_q16 = tb_q16_mul_rn_sat(alpha_l_old_q16, recip_q16);
                end
                partial_acc_q16 = 128'sd0;
                for (key_col_i = 0; key_col_i < 16; key_col_i = key_col_i + 1) begin
                    p_q16 = tb_q16_mul_rn_sat(beta_q16[key_col_i], recip_q16);
                    p_q88 = tb_q16_to_q88_rn_sat(p_q16);
                    v_q88 = make_v_word(kv_i, key_col_i[3:0], col);
                    partial_acc_q16 = partial_acc_q16 + ($signed(p_q88) * $signed(v_q88));
                end
                partial_q88 = tb_q16_16_to_q88_sat128(partial_acc_q16);
                old_o_q412 = tb_update_oacc_elem(old_o_q412, scale_q16, partial_q88);
                old_m_q16 = new_m_q16;
                old_l_q16 = new_l_q16;
            end
            expected_o_word_dense_qk = old_o_q412;
        end
    endfunction

    task expect_o_word_all_tiles;
        input integer row;
        input integer col;
        reg [15:0] actual;
        reg [15:0] expected;
        begin
            actual = get_o_word(row, col);
            if (NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) begin
                expected = expected_o_word_dense_qk(row, col);
            end else begin
                expected = expected_o_word_all_tiles(col);
            end
            if (actual !== expected) begin
                if (error_count < 16) begin
                    $display("FAIL: full-window O[%0d,%0d] expected 0x%04h got 0x%04h at %0t",
                             row, col, expected, actual, $time);
                end
                error_count = error_count + 1;
            end
        end
    endtask

    function [511:0] expected_v_resp_data;
        input [4:0] kv_idx;
        input [2:0] pair_idx;
        input [1:0] wave_idx;
        integer word_idx;
        integer row_low_idx;
        integer row_high_idx;
        integer col_idx;
        reg [511:0] expected;
        begin
            expected = 512'd0;
            for (word_idx = 0; word_idx < 16; word_idx = word_idx + 1) begin
                row_low_idx = pair_idx * 2;
                row_high_idx = row_low_idx + 1;
                col_idx = (wave_idx * 16) + ((word_idx / 4) * 4) + (word_idx % 4);
                expected[(word_idx * 32) +: 32] = {
                    make_v_word(kv_idx, row_high_idx[3:0], col_idx),
                    make_v_word(kv_idx, row_low_idx[3:0], col_idx)
                };
            end
            expected_v_resp_data = expected;
        end
    endfunction

    always @(posedge clk) begin
        if (!rstn || clear) begin
            expected_v_resp_valid_r <= 1'b0;
            expected_v_resp_data_r <= 512'd0;
        end else begin
            expected_v_resp_valid_r <= dut.v_sram_rd_fire_w;
            if (dut.v_sram_rd_fire_w) begin
                expected_v_resp_data_r <= expected_v_resp_data(
                    dut.micro_v_rd_req_kv_idx_w,
                    dut.micro_v_rd_req_pair_idx_w,
                    dut.micro_v_rd_req_wave_idx_w);
            end
            if (expected_v_resp_valid_r && dut.micro_v_rd_resp_valid_w &&
                (dut.micro_v_rd_resp_data_w !== expected_v_resp_data_r)) begin
                if (error_count < 16) begin
                    $display("FAIL: v response mismatch expected=0x%0128h got=0x%0128h at %0t",
                             expected_v_resp_data_r,
                             dut.micro_v_rd_resp_data_w,
                             $time);
                end
                error_count = error_count + 1;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            core_start_count <= 0;
            restore_start_count <= 0;
        end else if (clear) begin
            core_start_count <= 0;
            restore_start_count <= 0;
        end else if (dut.core_start_r) begin
            core_start_count <= core_start_count + 1;
            if (!dut.core_first_kv_window_w) begin
                restore_start_count <= restore_start_count + 1;
            end
        end
    end

    initial begin
        q_tile_req_ready = 1'b1;
        q_tile_beat_valid = 1'b0;
        q_tile_beat_row_idx = 2'd0;
        q_tile_beat_chunk_idx = 4'd0;
        q_tile_beat_data = 64'd0;
        q_tile_beat_last = 1'b0;
        k_tile_req_ready = 1'b1;
        k_tile_beat_valid = 1'b0;
        k_tile_beat_row_idx = 4'd0;
        k_tile_beat_chunk_idx = 4'd0;
        k_tile_beat_data = 64'd0;
        k_tile_beat_last = 1'b0;
        v_tile_req_ready = 1'b1;
        v_tile_beat_valid = 1'b0;
        v_tile_beat_row_idx = 4'd0;
        v_tile_beat_chunk_idx = 4'd0;
        v_tile_beat_data = 64'd0;
        v_tile_beat_last = 1'b0;
        wait (rstn === 1'b1);
        drive_all_tiles();
    end

    initial begin
        error_count = 0;
        wait_count = 0;
        q_req_seen_count = 0;
        k_req_seen_count = 0;
        v_req_seen_count = 0;
        dense_qk_o_checksum = 32'd0;
        expected_v_resp_valid_r = 1'b0;
        expected_v_resp_data_r = 512'd0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;

        tick();
        tick();
        rstn = 1'b1;
        tick();

        start = 1'b1;
        tick();
        start = 1'b0;

        while ((done !== 1'b1) && (wait_count < 1200000)) begin
            wait_count = wait_count + 1;
            tick();
        end

        if (done !== 1'b1) begin
            $display("FAIL: timeout waiting for windowed loop done wait_count=%0d cycles=%0d q_visits=%0d kv_windows=%0d micro_tiles=%0d q_reqs=%0d q_beats=%0d k_reqs=%0d k_beats=%0d v_reqs=%0d v_beats=%0d",
                     wait_count, cycles, q_tile_visit_count, kv_window_count,
                     micro_tile_count, q_tile_req_count, q_tile_beat_count,
                     k_tile_req_count, k_tile_beat_count,
                     v_tile_req_count, v_tile_beat_count);
            $display("FAIL: state=%0d q_group=%0d kv_window=%0d q_tile_in_group=%0d kv_slot=%0d micro_busy=%0d micro_done=%0d micro_error=%0d",
                     dut.state_r, dut.q_group_idx_r, dut.kv_window_idx_r,
                     dut.q_tile_in_group_idx_r, dut.kv_load_slot_idx_r,
                     dut.micro_busy_w, dut.micro_done_w, dut.micro_error_w);
            $fatal(1);
        end

        if (error !== 1'b0) begin
            $display("FAIL: windowed loop error asserted");
            error_count = error_count + 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL: busy should be low after windowed loop done");
            error_count = error_count + 1;
        end
        if (cycles == 32'd0) begin
            $display("FAIL: cycles should be nonzero");
            error_count = error_count + 1;
        end
        if (cycles > MAX_EXPECTED_CYCLES[31:0]) begin
            $display("FAIL: cycles expected <= %0d got %0d", MAX_EXPECTED_CYCLES, cycles);
            error_count = error_count + 1;
        end

        expect32(q_group_count, 32'd4, "q_group_count");
        expect32(kv_window_count, 32'd16, "kv_window_count");
        expect32(q_tile_visit_count, 32'd256, "q_tile_visit_count");
        expect32(q_tile_req_count, 32'd256, "q_tile_req_count");
        expect32(q_tile_beat_count, 32'd16384, "q_tile_beat_count");
        expect32(k_tile_req_count, 32'd64, "k_tile_req_count");
        expect32(k_tile_beat_count, 32'd16384, "k_tile_beat_count");
        expect32(v_tile_req_count, 32'd64, "v_tile_req_count");
        expect32(v_tile_beat_count, 32'd16384, "v_tile_beat_count");
        expect32(micro_tile_count, 32'd1024, "micro_tile_count");
        expect32(kv_tile_count, 32'd1024, "kv_tile_count");
        expect32(state_fill_count, 32'd256, "state_fill_count");
        expect32(state_spill_count, 32'd256, "state_spill_count");
        expect32(qk_task_count, 32'd131072, "qk_task_count");
        expect32(pv_task_count, 32'd131072, "pv_task_count");
        expect32(oacc_task_count, 32'd1024, "oacc_task_count");
        expect32(core_start_count, 32'd256, "core_start_count");
        expect32(restore_start_count, 32'd192, "restore_start_count");

        for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
            for (col_i = 0; col_i < 64; col_i = col_i + 1) begin
                expect_o_word_all_tiles(row_i, col_i);
                if (NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) begin
                    dense_qk_o_checksum = dense_qk_o_checksum
                                         + ((row_i + 1) * (col_i + 1)
                                            * expected_o_word_dense_qk(row_i, col_i));
                end
            end
        end
        if ((NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) &&
            (dense_qk_o_checksum !== 32'h0373_5A74)) begin
            $display("FAIL: dense-QK fixed reference checksum expected 0x03735a74 got 0x%08h",
                     dense_qk_o_checksum);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            if (NUMERIC_MODE == NUMERIC_MODE_DENSE_QK) begin
                $display("PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 numeric=dense_qk_reference perf_max_cycles=%0d cycles=%0d q_groups=%0d kv_windows=%0d micro_tiles=%0d q_visits=%0d kv_tiles=%0d q_reqs=%0d q_beats=%0d k_reqs=%0d k_beats=%0d v_reqs=%0d v_beats=%0d qk_tasks=%0d pv_tasks=%0d restore_starts=%0d",
                         MAX_EXPECTED_CYCLES, cycles, q_group_count, kv_window_count,
                         micro_tile_count, q_tile_visit_count, kv_tile_count,
                         q_tile_req_count, q_tile_beat_count,
                         k_tile_req_count, k_tile_beat_count,
                         v_tile_req_count, v_tile_beat_count,
                         qk_task_count, pv_task_count, restore_start_count);
            end else begin
                $display("PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 numeric=uniform_q_mean_v perf_max_cycles=%0d cycles=%0d q_groups=%0d kv_windows=%0d micro_tiles=%0d q_visits=%0d kv_tiles=%0d q_reqs=%0d q_beats=%0d k_reqs=%0d k_beats=%0d v_reqs=%0d v_beats=%0d qk_tasks=%0d pv_tasks=%0d restore_starts=%0d",
                         MAX_EXPECTED_CYCLES, cycles, q_group_count, kv_window_count,
                         micro_tile_count, q_tile_visit_count, kv_tile_count,
                         q_tile_req_count, q_tile_beat_count,
                         k_tile_req_count, k_tile_beat_count,
                         v_tile_req_count, v_tile_beat_count,
                         qk_task_count, pv_task_count, restore_start_count);
            end
            $finish;
        end

        $display("FAIL: fa_optim_4x4_windowed_loop_tb errors=%0d cycles=%0d", error_count, cycles);
        $fatal(1);
    end
endmodule
