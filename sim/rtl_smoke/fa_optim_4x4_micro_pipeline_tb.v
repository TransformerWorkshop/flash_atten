`timescale 1ns/1ps

module fa_optim_4x4_micro_pipeline_tb;
    reg          clk;
    reg          rstn;
    reg          clear;
    reg          start;
    reg          first_kv_tile;
    reg  [4095:0] q_block_flat;
    reg  [16383:0] k_tile_flat;
    reg  [16383:0] v_tile_flat;
    wire         k_rd_req_valid;
    reg          k_rd_req_ready;
    wire [4:0]   k_rd_req_pair_idx;
    reg          k_rd_resp_valid;
    reg  [511:0] k_rd_resp_data;
    wire         v_rd_req_valid;
    reg          v_rd_req_ready;
    wire [1:0]   v_rd_req_wave_idx;
    wire [2:0]   v_rd_req_pair_idx;
    reg          v_rd_resp_valid;
    reg  [511:0] v_rd_resp_data;
    wire         busy;
    wire         done;
    wire         error;
    wire [4095:0] o_tile_flat;
    wire [31:0] cycles;
    wire [31:0] qk_task_count;
    wire [31:0] score_task_count;
    wire [31:0] row_state_task_count;
    wire [31:0] pv_task_count;
    wire [31:0] oacc_task_count;

    integer error_count;
    integer wait_count;
    integer row_i;
    integer col_i;
    reg [31:0] first_tile_cycles;
    reg [31:0] second_tile_cycles;
    integer idle_state_cycles;
    integer row_init_state_cycles;
    integer qk_req_state_cycles;
    integer qk_wait_state_cycles;
    integer qk_send_state_cycles;
    integer qk_drain_state_cycles;
    integer score_state_cycles;
    integer row_state_cycles;
    integer pv_req_state_cycles;
    integer pv_wait_state_cycles;
    integer pv_send_state_cycles;
    integer pv_drain_state_cycles;
    integer oacc_state_cycles;
    integer done_state_cycles;
    integer other_state_cycles;

    FA_OPTIM_4X4_MICRO_PIPELINE dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .first_kv_tile(first_kv_tile),
        .q_block_flat(q_block_flat),
        .k_rd_req_valid(k_rd_req_valid),
        .k_rd_req_ready(k_rd_req_ready),
        .k_rd_req_pair_idx(k_rd_req_pair_idx),
        .k_rd_resp_valid(k_rd_resp_valid),
        .k_rd_resp_data(k_rd_resp_data),
        .v_rd_req_valid(v_rd_req_valid),
        .v_rd_req_ready(v_rd_req_ready),
        .v_rd_req_wave_idx(v_rd_req_wave_idx),
        .v_rd_req_pair_idx(v_rd_req_pair_idx),
        .v_rd_resp_valid(v_rd_resp_valid),
        .v_rd_resp_data(v_rd_resp_data),
        .busy(busy),
        .done(done),
        .error(error),
        .o_tile_flat(o_tile_flat),
        .cycles(cycles),
        .qk_task_count(qk_task_count),
        .score_task_count(score_task_count),
        .row_state_task_count(row_state_task_count),
        .pv_task_count(pv_task_count),
        .oacc_task_count(oacc_task_count)
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

    task set_v_elem;
        input integer row;
        input integer col;
        input [15:0] value;
        integer word_idx;
        begin
            word_idx = row * 32 + (col >> 1);
            v_tile_flat[(word_idx * 32) + ((col & 1) * 16) +: 16] = value;
        end
    endtask

    task load_v_tile;
        input integer base_value;
        begin
            for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
                for (col_i = 0; col_i < 64; col_i = col_i + 1) begin
                    set_v_elem(row_i, col_i, base_value[15:0] + row_i[15:0] + col_i[15:0]);
                end
            end
        end
    endtask

    function [15:0] get_o_word;
        input integer row;
        input integer col;
        begin
            get_o_word = o_tile_flat[(row * 1024) + (col * 16) +: 16];
        end
    endfunction

    function [31:0] get_v_pair_word;
        input integer pair_idx;
        input integer col;
        integer lo_word_idx;
        integer hi_word_idx;
        reg [15:0] lo_value;
        reg [15:0] hi_value;
        begin
            lo_word_idx = (pair_idx * 2) * 32 + (col >> 1);
            hi_word_idx = ((pair_idx * 2) + 1) * 32 + (col >> 1);
            if ((col & 1) == 0) begin
                lo_value = v_tile_flat[(lo_word_idx * 32) +: 16];
                hi_value = v_tile_flat[(hi_word_idx * 32) +: 16];
            end else begin
                lo_value = v_tile_flat[(lo_word_idx * 32 + 16) +: 16];
                hi_value = v_tile_flat[(hi_word_idx * 32 + 16) +: 16];
            end
            get_v_pair_word = {hi_value, lo_value};
        end
    endfunction

    function [31:0] get_k_pair_word;
        input integer row_idx;
        input integer pair_idx;
        begin
            get_k_pair_word = k_tile_flat[((row_idx * 32 + pair_idx) * 32) +: 32];
        end
    endfunction

    function [511:0] make_k_read_data;
        input [4:0] pair_idx;
        integer make_row_i;
        reg [511:0] read_value;
        begin
            read_value = 512'd0;
            for (make_row_i = 0; make_row_i < 16; make_row_i = make_row_i + 1) begin
                read_value[(make_row_i * 32) +: 32] =
                    get_k_pair_word(make_row_i, pair_idx);
            end
            make_k_read_data = read_value;
        end
    endfunction

    function [511:0] make_v_read_data;
        input [1:0] wave_idx;
        input [2:0] pair_idx;
        integer make_lane_i;
        integer make_col_i;
        integer make_col_global;
        reg [511:0] read_value;
        begin
            read_value = 512'd0;
            for (make_lane_i = 0; make_lane_i < 4; make_lane_i = make_lane_i + 1) begin
                for (make_col_i = 0; make_col_i < 4; make_col_i = make_col_i + 1) begin
                    make_col_global = (wave_idx * 16) + (make_lane_i * 4) + make_col_i;
                    read_value[((make_lane_i * 4 + make_col_i) * 32) +: 32] =
                        get_v_pair_word(pair_idx, make_col_global);
                end
            end
            make_v_read_data = read_value;
        end
    endfunction

    function [15:0] expected_o_word;
        input integer col;
        begin
            expected_o_word = (16'd264 + col[15:0]) << 4;
        end
    endfunction

    function [15:0] expected_o_word_two_tiles;
        input integer col;
        reg [15:0] rounded_q88_shifted;
        begin
            // OACC emits Q4.12, so it can preserve the half-Q8.8 step left by
            // splitting the uniform 32-key average across two 16-key tiles.
            rounded_q88_shifted = (16'd392 + col[15:0]) << 4;
            expected_o_word_two_tiles = rounded_q88_shifted -
                (((col & 1) != 0) ? 16'd8 : 16'd0);
        end
    endfunction

    task expect32;
        input [31:0] actual;
        input [31:0] expected;
        input [8*48-1:0] name;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %0d got %0d at %0t", name, expected, actual, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task expect_o_word;
        input integer row;
        input integer col;
        reg [15:0] actual;
        reg [15:0] expected;
        begin
            actual = get_o_word(row, col);
            expected = expected_o_word(col);
            if (actual !== expected) begin
                $display("FAIL: O[%0d,%0d] expected 0x%04h got 0x%04h at %0t",
                         row, col, expected, actual, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task expect_o_word_two_tiles;
        input integer row;
        input integer col;
        reg [15:0] actual;
        reg [15:0] expected;
        begin
            actual = get_o_word(row, col);
            expected = expected_o_word_two_tiles(col);
            if (actual !== expected) begin
                $display("FAIL: two-tile O[%0d,%0d] expected 0x%04h got 0x%04h at %0t",
                         row, col, expected, actual, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task clear_state_counters;
        begin
            idle_state_cycles = 0;
            row_init_state_cycles = 0;
            qk_req_state_cycles = 0;
            qk_wait_state_cycles = 0;
            qk_send_state_cycles = 0;
            qk_drain_state_cycles = 0;
            score_state_cycles = 0;
            row_state_cycles = 0;
            pv_req_state_cycles = 0;
            pv_wait_state_cycles = 0;
            pv_send_state_cycles = 0;
            pv_drain_state_cycles = 0;
            oacc_state_cycles = 0;
            done_state_cycles = 0;
            other_state_cycles = 0;
        end
    endtask

    task sample_state_counter;
        begin
            case (dut.state_r)
                4'd0: idle_state_cycles = idle_state_cycles + 1;
                4'd1: row_init_state_cycles = row_init_state_cycles + 1;
                4'd2: qk_req_state_cycles = qk_req_state_cycles + 1;
                4'd3: qk_wait_state_cycles = qk_wait_state_cycles + 1;
                4'd4: qk_send_state_cycles = qk_send_state_cycles + 1;
                4'd5: qk_drain_state_cycles = qk_drain_state_cycles + 1;
                4'd6: score_state_cycles = score_state_cycles + 1;
                4'd7: row_state_cycles = row_state_cycles + 1;
                4'd8: pv_req_state_cycles = pv_req_state_cycles + 1;
                4'd9: pv_wait_state_cycles = pv_wait_state_cycles + 1;
                4'd10: pv_send_state_cycles = pv_send_state_cycles + 1;
                4'd11: pv_drain_state_cycles = pv_drain_state_cycles + 1;
                4'd12: oacc_state_cycles = oacc_state_cycles + 1;
                4'd13: done_state_cycles = done_state_cycles + 1;
                default: other_state_cycles = other_state_cycles + 1;
            endcase
        end
    endtask

    task run_tile;
        input first_tile;
        input integer timeout_limit;
        begin
            wait_count = 0;
            clear_state_counters();
            first_kv_tile = first_tile;
            start = 1'b1;
            tick();
            start = 1'b0;

            while ((done !== 1'b1) && (wait_count < timeout_limit)) begin
                wait_count = wait_count + 1;
                tick();
                sample_state_counter();
            end

            if (done !== 1'b1) begin
                $display("FAIL: timeout waiting for 4x4 micro pipeline done, first_tile=%0d wait_count=%0d cycles=%0d", first_tile, wait_count, cycles);
                $display("FAIL: state=%0d feed=%0d qk_group=%0d pv_wave=%0d qk_tasks=%0d score_tasks=%0d row_tasks=%0d pv_tasks=%0d oacc_tasks=%0d",
                         dut.state_r, dut.feed_count_r, dut.qk_key_group_r, dut.pv_wave_r,
                         qk_task_count, score_task_count, row_state_task_count, pv_task_count, oacc_task_count);
                $display("FAIL: gemm_valid=%b gemm_lane_ready=%b gemm_group_valid=%b gemm_last=%b score_req_ready=%b score_resp_valid=%b row_ready=%b row_done=%b oacc_ready=%b oacc_done=%b",
                         dut.gemm_valid_r, dut.gemm_lane_ready_w, dut.gemm_group_valid_w, dut.gemm_last_w,
                         dut.score_req_ready_w, dut.score_resp_valid_w, dut.row_update_ready_w, dut.row_done_pulse_w,
                         dut.oacc_req_ready_w, dut.oacc_done_pulse_w);
                $fatal(1);
            end
            $display("INFO: micro_state_cycles first_tile=%0d idle=%0d row_init=%0d qk_req=%0d qk_wait=%0d qk_send=%0d qk_drain=%0d score=%0d row_state=%0d pv_req=%0d pv_wait=%0d pv_send=%0d pv_drain=%0d oacc=%0d done=%0d other=%0d",
                     first_tile, idle_state_cycles, row_init_state_cycles,
                     qk_req_state_cycles, qk_wait_state_cycles, qk_send_state_cycles,
                     qk_drain_state_cycles, score_state_cycles, row_state_cycles,
                     pv_req_state_cycles, pv_wait_state_cycles, pv_send_state_cycles,
                     pv_drain_state_cycles, oacc_state_cycles, done_state_cycles,
                     other_state_cycles);
        end
    endtask

    initial begin
        error_count = 0;
        wait_count = 0;
        first_tile_cycles = 32'd0;
        second_tile_cycles = 32'd0;
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        first_kv_tile = 1'b0;
        q_block_flat = 4096'd0;
        k_tile_flat = 16384'd0;
        v_tile_flat = 16384'd0;
        k_rd_req_ready = 1'b1;
        k_rd_resp_valid = 1'b0;
        k_rd_resp_data = 512'd0;
        v_rd_req_ready = 1'b1;
        v_rd_resp_valid = 1'b0;
        v_rd_resp_data = 512'd0;
        clear_state_counters();

        load_v_tile(16'h0100);

        tick();
        tick();
        rstn = 1'b1;
        tick();

        run_tile(1'b1, 5000);
        first_tile_cycles = cycles;

        if (error !== 1'b0) begin
            $display("FAIL: dut error asserted");
            error_count = error_count + 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL: busy should be low after done");
            error_count = error_count + 1;
        end

        expect32(score_task_count, 32'd1, "score_task_count");
        expect32(row_state_task_count, 32'd1, "row_state_task_count");
        expect32(qk_task_count, 32'd128, "qk_task_count");
        expect32(pv_task_count, 32'd128, "pv_task_count");
        expect32(oacc_task_count, 32'd1, "oacc_task_count");

        for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
            for (col_i = 0; col_i < 64; col_i = col_i + 1) begin
                expect_o_word(row_i, col_i);
            end
        end

        load_v_tile(16'h0200);
        run_tile(1'b0, 5000);
        second_tile_cycles = cycles;

        expect32(score_task_count, 32'd1, "second_score_task_count");
        expect32(row_state_task_count, 32'd1, "second_row_state_task_count");
        expect32(qk_task_count, 32'd128, "second_qk_task_count");
        expect32(pv_task_count, 32'd128, "second_pv_task_count");
        expect32(oacc_task_count, 32'd1, "second_oacc_task_count");

        for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
            for (col_i = 0; col_i < 64; col_i = col_i + 1) begin
                expect_o_word_two_tiles(row_i, col_i);
            end
        end

        if (cycles == 32'd0) begin
            $display("FAIL: cycles should be nonzero");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: fa_optim_4x4_micro_pipeline_tb first_cycles=%0d second_cycles=%0d qk_tasks=%0d pv_tasks=%0d two_tile=1",
                     first_tile_cycles, second_tile_cycles, qk_task_count, pv_task_count);
            $finish;
        end

        $display("FAIL: fa_optim_4x4_micro_pipeline_tb errors=%0d cycles=%0d", error_count, cycles);
        $fatal(1);
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            k_rd_resp_valid <= 1'b0;
            k_rd_resp_data <= 512'd0;
            v_rd_resp_valid <= 1'b0;
            v_rd_resp_data <= 512'd0;
        end else if (clear) begin
            k_rd_resp_valid <= 1'b0;
            k_rd_resp_data <= 512'd0;
            v_rd_resp_valid <= 1'b0;
            v_rd_resp_data <= 512'd0;
        end else begin
            k_rd_resp_valid <= k_rd_req_valid && k_rd_req_ready;
            if (k_rd_req_valid && k_rd_req_ready) begin
                k_rd_resp_data <= make_k_read_data(k_rd_req_pair_idx);
            end else begin
                k_rd_resp_data <= 512'd0;
            end
            v_rd_resp_valid <= v_rd_req_valid && v_rd_req_ready;
            if (v_rd_req_valid && v_rd_req_ready) begin
                v_rd_resp_data <= make_v_read_data(v_rd_req_wave_idx, v_rd_req_pair_idx);
            end else begin
                v_rd_resp_data <= 512'd0;
            end
        end
    end
endmodule
