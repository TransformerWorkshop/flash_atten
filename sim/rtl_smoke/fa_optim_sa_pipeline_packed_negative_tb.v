`timescale 1ns/1ps

module fa_optim_sa_pipeline_packed_negative_tb;
    reg         clk;
    reg         rstn;
    reg         clear;
    reg         start;
    wire        busy;
    wire        done;
    wire [31:0] cycles;
    wire [31:0] sa_busy_cycles;
    wire [31:0] feeder_busy_cycles;
    wire [31:0] row_state_busy_cycles;
    wire [31:0] qk_task_count;
    wire [31:0] pv_task_count;
    wire [31:0] oacc_task_count;
    wire [31:0] row_update_task_count;
    wire [31:0] qk_feed_count;
    wire [31:0] pv_feed_count;
    wire [31:0] cluster_wait_task_count;
    wire [31:0] feeder_wait_slot_count;
    wire [31:0] pv_wait_row_update_count;
    wire [31:0] active0_count;
    wire [31:0] active1_count;
    wire [31:0] active2_count;
    wire [31:0] active3_count;
    wire [31:0] active4_count;
    wire [63:0] packed_buffer_probe_data;

    integer error_count;
    integer wait_count;

    FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE #(
        .PV_FEED_CYCLES(16)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .busy(busy),
        .done(done),
        .cycles(cycles),
        .sa_busy_cycles(sa_busy_cycles),
        .feeder_busy_cycles(feeder_busy_cycles),
        .row_state_busy_cycles(row_state_busy_cycles),
        .qk_task_count(qk_task_count),
        .pv_task_count(pv_task_count),
        .oacc_task_count(oacc_task_count),
        .row_update_task_count(row_update_task_count),
        .qk_feed_count(qk_feed_count),
        .pv_feed_count(pv_feed_count),
        .cluster_wait_task_count(cluster_wait_task_count),
        .feeder_wait_slot_count(feeder_wait_slot_count),
        .pv_wait_row_update_count(pv_wait_row_update_count),
        .active0_count(active0_count),
        .active1_count(active1_count),
        .active2_count(active2_count),
        .active3_count(active3_count),
        .active4_count(active4_count),
        .packed_buffer_probe_data(packed_buffer_probe_data)
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
        input [8*64-1:0] name;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %0d got %0d at %0t", name, expected, actual, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        error_count = 0;
        wait_count = 0;
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

        while ((done !== 1'b1) && (wait_count < 9000)) begin
            wait_count = wait_count + 1;
            tick();
        end

        if (done !== 1'b1) begin
            $display("FAIL: timeout waiting for packed negative done, wait_count=%0d cycles=%0d",
                     wait_count, cycles);
            $fatal(1);
        end

        expect32(cycles, 32'd4418, "cycles");
        expect32(sa_busy_cycles, 32'd8704, "sa_busy_cycles");
        expect32(feeder_busy_cycles, 32'd4352, "feeder_busy_cycles");
        expect32(row_state_busy_cycles, 32'd136, "row_state_busy_cycles");
        expect32(qk_task_count, 32'd136, "qk_task_count");
        expect32(pv_task_count, 32'd136, "pv_task_count");
        expect32(oacc_task_count, 32'd136, "oacc_task_count");
        expect32(row_update_task_count, 32'd136, "row_update_task_count");
        expect32(qk_feed_count, 32'd136, "qk_feed_count");
        expect32(pv_feed_count, 32'd136, "pv_feed_count");
        expect32(cluster_wait_task_count, 32'd8968, "cluster_wait_task_count");
        expect32(feeder_wait_slot_count, 32'd66, "feeder_wait_slot_count");
        expect32(pv_wait_row_update_count, 32'd136, "pv_wait_row_update_count");
        expect32(active0_count, 32'd18, "active0_count");
        expect32(active1_count, 32'd1536, "active1_count");
        expect32(active2_count, 32'd1424, "active2_count");
        expect32(active3_count, 32'd1440, "active3_count");
        expect32(active4_count, 32'd0, "active4_count");

        if (busy !== 1'b0) begin
            $display("FAIL: packed negative busy should be low after done");
            error_count = error_count + 1;
        end
        if (^packed_buffer_probe_data === 1'bx) begin
            $display("FAIL: packed negative buffer probe contains X");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: fa_optim_sa_pipeline_packed_negative_tb cycles=%0d sa_busy=%0d feeder_busy=%0d pv_feeds=%0d",
                     cycles, sa_busy_cycles, feeder_busy_cycles, pv_feed_count);
            $finish;
        end

        $display("FAIL: fa_optim_sa_pipeline_packed_negative_tb errors=%0d", error_count);
        $fatal(1);
    end
endmodule
