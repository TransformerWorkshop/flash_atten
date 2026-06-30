`timescale 1ns/1ps

module fa_optim_windowed_sched_contract_tb;
    reg clk;
    reg rstn;
    reg clear;
    reg start;
    reg causal_en;
    wire q_tile_req_valid;
    reg q_tile_req_ready;
    wire [5:0] q_tile_req_q_idx;
    wire k_tile_req_valid;
    reg k_tile_req_ready;
    wire [4:0] k_tile_req_kv_idx;
    wire v_tile_req_valid;
    reg v_tile_req_ready;
    wire [4:0] v_tile_req_kv_idx;
    wire busy;
    wire done;
    wire error;
    wire [31:0] cycles;
    wire [31:0] q_group_count;
    wire [31:0] kv_window_count;
    wire [31:0] q_tile_visit_count;
    wire [31:0] kv_tile_compute_count;
    wire [31:0] skipped_future_kv_tiles;
    wire [31:0] q_tile_req_count;
    wire [31:0] k_tile_req_count;
    wire [31:0] v_tile_req_count;
    wire [31:0] score_slice_count;
    wire [31:0] oacc_slice_count;
    wire [31:0] state_fill_count;
    wire [31:0] state_spill_count;

    integer error_count;
    integer wait_count;

    FA_OPTIM_WINDOWED_SCHED_CONTRACT dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .causal_en(causal_en),
        .q_tile_req_valid(q_tile_req_valid),
        .q_tile_req_ready(q_tile_req_ready),
        .q_tile_req_q_idx(q_tile_req_q_idx),
        .k_tile_req_valid(k_tile_req_valid),
        .k_tile_req_ready(k_tile_req_ready),
        .k_tile_req_kv_idx(k_tile_req_kv_idx),
        .v_tile_req_valid(v_tile_req_valid),
        .v_tile_req_ready(v_tile_req_ready),
        .v_tile_req_kv_idx(v_tile_req_kv_idx),
        .busy(busy),
        .done(done),
        .error(error),
        .cycles(cycles),
        .q_group_count(q_group_count),
        .kv_window_count(kv_window_count),
        .q_tile_visit_count(q_tile_visit_count),
        .kv_tile_compute_count(kv_tile_compute_count),
        .skipped_future_kv_tiles(skipped_future_kv_tiles),
        .q_tile_req_count(q_tile_req_count),
        .k_tile_req_count(k_tile_req_count),
        .v_tile_req_count(v_tile_req_count),
        .score_slice_count(score_slice_count),
        .oacc_slice_count(oacc_slice_count),
        .state_fill_count(state_fill_count),
        .state_spill_count(state_spill_count)
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
        input [8*48-1:0] name;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %0d got %0d at %0t",
                         name, expected, actual, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task run_case;
        input causal_case;
        begin
            clear = 1'b1;
            start = 1'b0;
            causal_en = causal_case;
            tick();
            clear = 1'b0;
            tick();
            start = 1'b1;
            tick();
            start = 1'b0;

            wait_count = 0;
            while (done !== 1'b1 && wait_count < 10000) begin
                wait_count = wait_count + 1;
                tick();
            end
            if (done !== 1'b1) begin
                $display("FAIL: timeout causal=%0d at %0t", causal_case, $time);
                error_count = error_count + 1;
            end
            if (error !== 1'b0) begin
                $display("FAIL: error asserted causal=%0d at %0t", causal_case, $time);
                error_count = error_count + 1;
            end

            expect32(q_group_count, 32'd4, "q_group_count");
            expect32(kv_window_count, 32'd16, "kv_window_count");
            expect32(q_tile_visit_count, 32'd256, "q_tile_visit_count");
            expect32(q_tile_req_count, 32'd256, "q_tile_req_count");
            expect32(k_tile_req_count, 32'd64, "k_tile_req_count");
            expect32(v_tile_req_count, 32'd64, "v_tile_req_count");
            expect32(state_fill_count, 32'd256, "state_fill_count");
            expect32(state_spill_count, 32'd256, "state_spill_count");
            if (causal_case) begin
                expect32(kv_tile_compute_count, 32'd544, "kv_tile_compute_count");
                expect32(skipped_future_kv_tiles, 32'd480, "skipped_future_kv_tiles");
                expect32(score_slice_count, 32'd2176, "score_slice_count");
                expect32(oacc_slice_count, 32'd2176, "oacc_slice_count");
            end else begin
                expect32(kv_tile_compute_count, 32'd1024, "kv_tile_compute_count");
                expect32(skipped_future_kv_tiles, 32'd0, "skipped_future_kv_tiles");
                expect32(score_slice_count, 32'd4096, "score_slice_count");
                expect32(oacc_slice_count, 32'd4096, "oacc_slice_count");
            end
        end
    endtask

    initial begin
        rstn = 1'b0;
        clear = 1'b0;
        start = 1'b0;
        causal_en = 1'b0;
        q_tile_req_ready = 1'b1;
        k_tile_req_ready = 1'b1;
        v_tile_req_ready = 1'b1;
        error_count = 0;
        wait_count = 0;
        repeat (4) tick();
        rstn = 1'b1;
        repeat (2) tick();

        run_case(1'b0);
        run_case(1'b1);

        if (error_count == 0) begin
            $display("PASS: fa_optim_windowed_sched_contract_tb");
        end else begin
            $display("FAIL: fa_optim_windowed_sched_contract_tb errors=%0d", error_count);
            $fatal(1);
        end
        $finish;
    end

endmodule
