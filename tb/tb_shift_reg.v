`timescale 1ns/1ps

module tb_shift_reg;

    localparam WIDTH = 8;
    localparam DEPTH = 4;

    reg clk;
    reg rstn;

    // ---------------- SISO-mode DUT (USE_SIPO=0) ----------------
    reg  [WIDTH-1:0] siso_in_data;
    reg              siso_in_valid;
    wire             siso_in_ready;
    wire [DEPTH*WIDTH-1:0] siso_dummy_sipo_data;
    reg  [DEPTH-1:0]       siso_dummy_sipo_ready;
    wire [DEPTH-1:0]       siso_dummy_sipo_valid;
    wire [WIDTH-1:0]       siso_out_data;
    reg                    siso_out_ready;
    wire                   siso_out_valid;

    // ---------------- SIPO-mode DUT (USE_SIPO=1) ----------------
    reg  [WIDTH-1:0] sipo_in_data;
    reg              sipo_in_valid;
    wire             sipo_in_ready;
    wire [DEPTH*WIDTH-1:0] sipo_out_data;
    reg  [DEPTH-1:0]       sipo_out_ready;
    wire [DEPTH-1:0]       sipo_out_valid;
    wire [WIDTH-1:0]       sipo_dummy_siso_data;
    reg                    sipo_dummy_siso_ready;
    wire                   sipo_dummy_siso_valid;

    integer errors;
    integer siso_in_cnt;
    integer siso_out_cnt;

    reg [WIDTH-1:0] held_siso_data;
    reg [DEPTH*WIDTH-1:0] held_sipo_data;
    reg [DEPTH-1:0] held_sipo_valid;

    SHIFT_REG #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH),
        .USE_SIPO(0)
    ) dut_siso (
        .clk(clk),
        .rstn(rstn),
        .data_in(siso_in_data),
        .valid_in(siso_in_valid),
        .ready_in(siso_in_ready),
        .sipo_data_out(siso_dummy_sipo_data),
        .sipo_ready(siso_dummy_sipo_ready),
        .sipo_valid(siso_dummy_sipo_valid),
        .siso_data_out(siso_out_data),
        .siso_ready(siso_out_ready),
        .siso_valid(siso_out_valid)
    );

    SHIFT_REG #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH),
        .USE_SIPO(1)
    ) dut_sipo (
        .clk(clk),
        .rstn(rstn),
        .data_in(sipo_in_data),
        .valid_in(sipo_in_valid),
        .ready_in(sipo_in_ready),
        .sipo_data_out(sipo_out_data),
        .sipo_ready(sipo_out_ready),
        .sipo_valid(sipo_out_valid),
        .siso_data_out(sipo_dummy_siso_data),
        .siso_ready(sipo_dummy_siso_ready),
        .siso_valid(sipo_dummy_siso_valid)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rstn && siso_in_valid && siso_in_ready) begin
            siso_in_cnt <= siso_in_cnt + 1;
        end
        if (rstn && siso_out_valid && siso_out_ready) begin
            siso_out_cnt <= siso_out_cnt + 1;
        end
    end

    task automatic push_siso(input [WIDTH-1:0] d);
        begin
            siso_in_data  <= d;
            siso_in_valid <= 1'b1;
            while (!siso_in_ready) begin
                @(posedge clk);
            end
            @(posedge clk);
            siso_in_valid <= 1'b0;
            siso_in_data  <= {WIDTH{1'b0}};
        end
    endtask

    task automatic push_sipo(input [WIDTH-1:0] d);
        begin
            sipo_in_data  <= d;
            sipo_in_valid <= 1'b1;
            while (!sipo_in_ready) begin
                @(posedge clk);
            end
            @(posedge clk);
            sipo_in_valid <= 1'b0;
            sipo_in_data  <= {WIDTH{1'b0}};
        end
    endtask

    task automatic expect(input cond, input [8*80-1:0] msg);
        begin
            if (!cond) begin
                $display("[FAIL] %0s (t=%0t)", msg, $time);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s (t=%0t)", msg, $time);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rstn = 1'b0;

        siso_in_data = {WIDTH{1'b0}};
        siso_in_valid = 1'b0;
        siso_dummy_sipo_ready = {DEPTH{1'b1}};
        siso_out_ready = 1'b1;

        sipo_in_data = {WIDTH{1'b0}};
        sipo_in_valid = 1'b0;
        sipo_out_ready = {DEPTH{1'b1}};
        sipo_dummy_siso_ready = 1'b1;

        errors = 0;
        siso_in_cnt = 0;
        siso_out_cnt = 0;

        repeat (4) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk);

        // -------- Test 1: SISO valid independent from ready and no double-read --------
        // Apply backpressure before the token reaches the output stage.
        siso_out_ready = 1'b0;
        push_siso(8'hA1);

        while (!siso_out_valid) begin
            @(posedge clk);
        end
        expect(siso_out_data == 8'hA1, "SISO first token visible under stall");

        held_siso_data = siso_out_data;
        repeat (3) begin
            @(posedge clk);
            expect(siso_out_valid == 1'b1, "SISO valid stays high while ready low");
            expect(siso_out_data == held_siso_data, "SISO data stable while stalled");
        end

        // Consume once.
        siso_out_ready = 1'b1;
        repeat (2) @(posedge clk);
        expect(siso_out_cnt == 1, "SISO token consumed exactly once");

        // Keep ready high for extra cycles: the same token must not be observed again.
        repeat (2) @(posedge clk);
        expect(!(siso_out_valid && (siso_out_data == 8'hA1)), "SISO token not double-read");

        // -------- Test 2: SIPO valid independent from ready and no repeated consumption --------
        // Stall one lane before valid reaches it, then verify stable presentation.
        sipo_out_ready = {DEPTH{1'b1}};
        sipo_out_ready[2] = 1'b0;

        push_sipo(8'h11);
        push_sipo(8'h22);
        push_sipo(8'h33);

        while (!sipo_out_valid[2]) begin
            @(posedge clk);
        end

        held_sipo_data = sipo_out_data;
        held_sipo_valid = sipo_out_valid;

        repeat (3) begin
            @(posedge clk);
            expect(sipo_out_valid[2] == 1'b1, "SIPO valid lane stays high while lane ready low");
            expect(sipo_out_data == held_sipo_data, "SIPO data stable while stalled");
            expect(sipo_out_valid == held_sipo_valid, "SIPO valid vector stable while stalled");
        end

        // Release stall and verify the output view can progress.
        sipo_out_ready = {DEPTH{1'b1}};
        begin : check_sipo_progress
            integer k;
            reg progressed;
            progressed = 1'b0;
            for (k = 0; k < (DEPTH + 2); k = k + 1) begin
                @(posedge clk);
                if ((sipo_out_data != held_sipo_data) || (sipo_out_valid != held_sipo_valid)) begin
                    progressed = 1'b1;
                end
            end
            expect(progressed, "SIPO view progresses after stall is released");
        end

        if (errors == 0) begin
            $display("TB RESULT: PASS");
        end else begin
            $display("TB RESULT: FAIL (errors=%0d)", errors);
        end

        #20;
        $finish;
    end

endmodule
