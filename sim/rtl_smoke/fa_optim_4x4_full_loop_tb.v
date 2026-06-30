`timescale 1ns/1ps

module fa_optim_4x4_full_loop_tb;
    localparam integer EXPECTED_Q_TILES = 64;
    localparam integer EXPECTED_KV_TILES = 1024;
    localparam integer EXPECTED_MICRO_TILES = 1024;
    localparam integer EXPECTED_QK_TASKS = 131072;
    localparam integer EXPECTED_PV_TASKS = 131072;
    localparam integer EXPECTED_OACC_TASKS = 1024;
    localparam integer EXPECTED_Q_TILE_REQS = 64;
    localparam integer EXPECTED_Q_TILE_BEATS = 4096;
    localparam integer EXPECTED_K_TILE_REQS = 16;
    localparam integer EXPECTED_K_TILE_BEATS = 4096;
    localparam integer EXPECTED_V_TILE_REQS = 16;
    localparam integer EXPECTED_V_TILE_BEATS = 4096;
    localparam integer MAX_EXPECTED_CYCLES = 123202;

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
    wire [31:0] q_tile_count;
    wire [31:0] kv_tile_count;
    wire [31:0] q_tile_req_count;
    wire [31:0] q_tile_beat_count;
    wire [31:0] k_tile_req_count;
    wire [31:0] k_tile_beat_count;
    wire [31:0] v_tile_req_count;
    wire [31:0] v_tile_beat_count;
    wire [31:0] qk_task_count;
    wire [31:0] pv_task_count;
    wire [31:0] oacc_task_count;
    wire [4095:0] o_block_flat;

    integer error_count;
    integer wait_count;
    integer row_i;
    integer col_i;

    FA_OPTIM_4X4_FULL_LOOP dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
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
        .q_tile_count(q_tile_count),
        .kv_tile_count(kv_tile_count),
        .q_tile_req_count(q_tile_req_count),
        .q_tile_beat_count(q_tile_beat_count),
        .k_tile_req_count(k_tile_req_count),
        .k_tile_beat_count(k_tile_beat_count),
        .v_tile_req_count(v_tile_req_count),
        .v_tile_beat_count(v_tile_beat_count),
        .qk_task_count(qk_task_count),
        .pv_task_count(pv_task_count),
        .oacc_task_count(oacc_task_count),
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
        input [8*48-1:0] name;
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

    function [15:0] make_k_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input integer col_idx;
        begin
            make_k_word = 16'h2000
                        + ({12'd0, kv_tile_idx[3:0]} << 10)
                        + ({12'd0, row_idx} << 6)
                        + col_idx[15:0];
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
            make_v_word = 16'h0100 + ({11'd0, kv_tile_idx} << 8)
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

    function [63:0] make_zero_beat;
        input integer unused_tile_idx;
        input integer unused_row_idx;
        input integer unused_chunk_idx;
        begin
            make_zero_beat = 64'd0;
        end
    endfunction

    function [63:0] k_folded_word;
        input [3:0] bank_idx;
        input [7:0] addr;
        begin
            case (bank_idx)
                4'd0:  k_folded_word = dut.gen_k_tile_sram_bank[0].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd1:  k_folded_word = dut.gen_k_tile_sram_bank[1].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd2:  k_folded_word = dut.gen_k_tile_sram_bank[2].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd3:  k_folded_word = dut.gen_k_tile_sram_bank[3].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd4:  k_folded_word = dut.gen_k_tile_sram_bank[4].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd5:  k_folded_word = dut.gen_k_tile_sram_bank[5].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd6:  k_folded_word = dut.gen_k_tile_sram_bank[6].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd7:  k_folded_word = dut.gen_k_tile_sram_bank[7].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd8:  k_folded_word = dut.gen_k_tile_sram_bank[8].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd9:  k_folded_word = dut.gen_k_tile_sram_bank[9].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd10: k_folded_word = dut.gen_k_tile_sram_bank[10].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd11: k_folded_word = dut.gen_k_tile_sram_bank[11].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd12: k_folded_word = dut.gen_k_tile_sram_bank[12].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd13: k_folded_word = dut.gen_k_tile_sram_bank[13].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd14: k_folded_word = dut.gen_k_tile_sram_bank[14].u_k_tile_sram.u_sram.u_sram.mem[addr];
                4'd15: k_folded_word = dut.gen_k_tile_sram_bank[15].u_k_tile_sram.u_sram.u_sram.mem[addr];
                default: k_folded_word = 64'hxxxx_xxxx_xxxx_xxxx;
            endcase
        end
    endfunction

    task check_k_sram_folded_layout;
        input [4:0] kv_tile_idx;
        integer check_row_i;
        integer check_chunk_i;
        reg [3:0] check_row_idx;
        reg [3:0] check_chunk_idx;
        reg [7:0] folded_addr;
        begin
            for (check_row_i = 0; check_row_i < 16; check_row_i = check_row_i + 1) begin
                for (check_chunk_i = 0; check_chunk_i < 16; check_chunk_i = check_chunk_i + 1) begin
                    check_row_idx = check_row_i[3:0];
                    check_chunk_idx = check_chunk_i[3:0];
                    folded_addr = {kv_tile_idx[3:0], check_chunk_idx};
                    expect64(k_folded_word(check_row_idx, folded_addr),
                             make_k_beat(kv_tile_idx, check_row_idx, check_chunk_idx),
                             "k_folded_word");
                end
            end
        end
    endtask

    task drive_q_tile_beats;
        reg [5:0] req_q_idx;
        integer drive_row_i;
        integer drive_chunk_i;
        begin
            wait (q_tile_req_valid === 1'b1);
            req_q_idx = q_tile_req_q_idx;
            tick();
            for (drive_row_i = 0; drive_row_i < 4; drive_row_i = drive_row_i + 1) begin
                for (drive_chunk_i = 0; drive_chunk_i < 16; drive_chunk_i = drive_chunk_i + 1) begin
                    q_tile_beat_valid = 1'b1;
                    q_tile_beat_row_idx = drive_row_i[1:0];
                    q_tile_beat_chunk_idx = drive_chunk_i[3:0];
                    q_tile_beat_data = make_zero_beat(req_q_idx, drive_row_i, drive_chunk_i);
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
        integer drive_row_i;
        integer drive_chunk_i;
        begin
            wait (k_tile_req_valid === 1'b1);
            req_kv_idx = k_tile_req_kv_idx;
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
            check_k_sram_folded_layout(req_kv_idx);
        end
    endtask

    task drive_v_tile_beats;
        reg [4:0] req_kv_idx;
        integer drive_row_i;
        integer drive_chunk_i;
        begin
            wait (v_tile_req_valid === 1'b1);
            req_kv_idx = v_tile_req_kv_idx;
            tick();
            for (drive_row_i = 0; drive_row_i < 16; drive_row_i = drive_row_i + 1) begin
                for (drive_chunk_i = 0; drive_chunk_i < 16; drive_chunk_i = drive_chunk_i + 1) begin
                    v_tile_beat_valid = 1'b1;
                    v_tile_beat_row_idx = drive_row_i[3:0];
                    v_tile_beat_chunk_idx = drive_chunk_i[3:0];
                    v_tile_beat_data = make_v_beat(req_kv_idx, drive_row_i[3:0], drive_chunk_i[3:0]);
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
        integer q_i;
        integer kv_i;
        begin
            for (kv_i = 0; kv_i < EXPECTED_K_TILE_REQS; kv_i = kv_i + 1) begin
                drive_k_tile_beats();
                drive_v_tile_beats();
            end
            for (q_i = 0; q_i < EXPECTED_Q_TILE_REQS; q_i = q_i + 1) begin
                drive_q_tile_beats();
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

        while ((done !== 1'b1) && (wait_count < 400000)) begin
            wait_count = wait_count + 1;
            tick();
        end

        if (done !== 1'b1) begin
            $display("FAIL: timeout waiting for full loop done wait_count=%0d cycles=%0d q_tiles=%0d kv_tiles=%0d micro_tiles=%0d q_reqs=%0d q_beats=%0d k_reqs=%0d k_beats=%0d v_reqs=%0d v_beats=%0d",
                     wait_count, cycles, q_tile_count, kv_tile_count,
                     micro_tile_count, q_tile_req_count, q_tile_beat_count,
                     k_tile_req_count, k_tile_beat_count,
                     v_tile_req_count, v_tile_beat_count);
            $display("FAIL: state=%0d q_idx=%0d kv_idx=%0d micro_busy=%0d micro_done=%0d micro_error=%0d",
                     dut.state_r, dut.q_tile_idx_r, dut.kv_tile_idx_r,
                     dut.micro_busy_w, dut.micro_done_w, dut.micro_error_w);
            $fatal(1);
        end

        if (error !== 1'b0) begin
            $display("FAIL: full loop error asserted");
            error_count = error_count + 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL: busy should be low after full loop done");
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

        expect32(micro_tile_count, 32'd1024, "micro_tile_count");
        expect32(q_tile_count, 32'd64, "q_tile_count");
        expect32(kv_tile_count, 32'd1024, "kv_tile_count");
        expect32(q_tile_req_count, 32'd64, "q_tile_req_count");
        expect32(q_tile_beat_count, 32'd4096, "q_tile_beat_count");
        expect32(k_tile_req_count, 32'd16, "k_tile_req_count");
        expect32(k_tile_beat_count, 32'd4096, "k_tile_beat_count");
        expect32(v_tile_req_count, 32'd16, "v_tile_req_count");
        expect32(v_tile_beat_count, 32'd4096, "v_tile_beat_count");
        expect32(qk_task_count, 32'd131072, "qk_task_count");
        expect32(pv_task_count, 32'd131072, "pv_task_count");
        expect32(oacc_task_count, 32'd1024, "oacc_task_count");

        for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
            for (col_i = 0; col_i < 64; col_i = col_i + 1) begin
                if (get_o_word(row_i, col_i) === 16'd0) begin
                    if (error_count < 8) begin
                        $display("FAIL: final O[%0d,%0d] should be nonzero", row_i, col_i);
                    end
                    error_count = error_count + 1;
                end
            end
        end

        if (error_count == 0) begin
            $display("PASS: fa_optim_4x4_full_loop_tb shape=S256_D64_B1_H1 perf_max_cycles=%0d cycles=%0d micro_tiles=%0d q_tiles=%0d kv_tiles=%0d q_reqs=%0d q_beats=%0d k_reqs=%0d k_beats=%0d v_reqs=%0d v_beats=%0d qk_tasks=%0d pv_tasks=%0d",
                     MAX_EXPECTED_CYCLES, cycles, micro_tile_count, q_tile_count, kv_tile_count,
                     q_tile_req_count, q_tile_beat_count,
                     k_tile_req_count, k_tile_beat_count,
                     v_tile_req_count, v_tile_beat_count, qk_task_count, pv_task_count);
            $finish;
        end

        $display("FAIL: fa_optim_4x4_full_loop_tb errors=%0d cycles=%0d", error_count, cycles);
        $fatal(1);
    end
endmodule
