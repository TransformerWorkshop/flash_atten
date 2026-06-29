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

    FA_OPTIM_4X4_MICRO_PIPELINE dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .first_kv_tile(first_kv_tile),
        .q_block_flat(q_block_flat),
        .k_tile_flat(k_tile_flat),
        .v_tile_flat(v_tile_flat),
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

    task run_tile;
        input first_tile;
        input integer timeout_limit;
        begin
            wait_count = 0;
            first_kv_tile = first_tile;
            start = 1'b1;
            tick();
            start = 1'b0;

            while ((done !== 1'b1) && (wait_count < timeout_limit)) begin
                wait_count = wait_count + 1;
                tick();
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
endmodule
