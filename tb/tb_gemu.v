`timescale 1ns/1ps

module tb_gemu;

    localparam WIDTH = 32;

    reg                 clk;
    reg                 rstn;
    reg  [WIDTH-1:0]    a;
    reg                 a_valid;
    wire                a_ready;
    reg  [WIDTH-1:0]    b;
    reg                 b_valid;
    wire                b_ready;
    wire [4*WIDTH-1:0]  m;
    wire                m_valid;
    reg                 m_ready;
    reg                 start;
    reg                 clear;
    reg  [WIDTH-1:0]    num_acc;

    integer errors;

    GEMU #(
        .WIDTH(WIDTH)
    ) dut (
        .clk    (clk),
        .rstn   (rstn),
        .a      (a),
        .a_valid(a_valid),
        .a_ready(a_ready),
        .b      (b),
        .b_valid(b_valid),
        .b_ready(b_ready),
        .m      (m),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .start  (start),
        .clear  (clear),
        .num_acc(num_acc)
    );

    always #5 clk = ~clk;

    task automatic drive_pair(input [WIDTH-1:0] a_in, input [WIDTH-1:0] b_in);
        begin
            a <= a_in;
            b <= b_in;
            a_valid <= 1'b1;
            b_valid <= 1'b1;

            // Wait until both channels are accepted in the same cycle.
            while (!(a_ready && b_ready)) begin
                @(posedge clk);
            end
            @(posedge clk);
            a_valid <= 1'b0;
            b_valid <= 1'b0;
            a <= {WIDTH{1'b0}};
            b <= {WIDTH{1'b0}};
        end
    endtask

    task automatic wait_result(input [4*WIDTH-1:0] expected, input [255:0] name);
        begin
            while (!m_valid) begin
                @(posedge clk);
            end
            if (m !== expected) begin
                $display("[FAIL] %0s expected=%0h got=%0h at t=%0t", name, expected, m, $time);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s expected=%0h got=%0h at t=%0t", name, expected, m, $time);
            end
            @(posedge clk);
        end
    endtask

    initial begin
        clk     = 1'b0;
        rstn    = 1'b0;
        a       = {WIDTH{1'b0}};
        a_valid = 1'b0;
        b       = {WIDTH{1'b0}};
        b_valid = 1'b0;
        m_ready = 1'b1;
        start   = 1'b0;
        clear   = 1'b0;
        num_acc = {WIDTH{1'b0}};
        errors  = 0;

        repeat (4) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk);

        // Test 1: small values.
        num_acc = 32'd4;
        start   = 1'b1;
        @(posedge clk);
        start   = 1'b0;

        drive_pair(32'd1, 32'd5);
        drive_pair(32'd2, 32'd6);
        drive_pair(32'd3, 32'd7);
        drive_pair(32'd4, 32'd8);

        wait_result(128'd70, "small_dot");

        // Test 2: signed wide accumulation, also catches truncation bugs.
        num_acc = 32'd2;
        start   = 1'b1;
        @(posedge clk);
        start   = 1'b0;

        drive_pair(32'hFFFF0000, 32'hFFFF0000);
        drive_pair(32'hFFFF0000, 32'hFFFF0000);

        wait_result(128'h00000000000000000000000200000000, "signed_wide_accum");

        // Test 3: mixed signed inputs should support negative accumulation.
        num_acc = 32'd2;
        start   = 1'b1;
        @(posedge clk);
        start   = 1'b0;

        drive_pair(32'hFFFFFFFE, 32'd3);   // -2 * 3
        drive_pair(32'd1,        32'd4);   //  1 * 4

        wait_result(128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE, "negative_result");

        // Test 4: delay a – b arrives first, a comes a few cycles later.
        num_acc = 32'd2;
        start   = 1'b1;
        @(posedge clk);
        start   = 1'b0;

        // pair 1: b ready immediately, a delayed 3 cycles
        b <= 32'd3; b_valid <= 1'b1;
        a_valid <= 1'b0;
        repeat (3) @(posedge clk);
        a <= 32'd2; a_valid <= 1'b1;
        while (!(a_ready && b_ready)) @(posedge clk);
        @(posedge clk);
        a_valid <= 1'b0; b_valid <= 1'b0;
        a <= 0; b <= 0;

        // pair 2: b ready immediately, a delayed 2 cycles
        b <= 32'd4; b_valid <= 1'b1;
        a_valid <= 1'b0;
        repeat (2) @(posedge clk);
        a <= 32'd5; a_valid <= 1'b1;
        while (!(a_ready && b_ready)) @(posedge clk);
        @(posedge clk);
        a_valid <= 1'b0; b_valid <= 1'b0;
        a <= 0; b <= 0;

        // expected: 2*3 + 5*4 = 26
        wait_result(128'd26, "delay_a");

        // Test 5: delay b – a arrives first, b comes a few cycles later.
        num_acc = 32'd2;
        start   = 1'b1;
        @(posedge clk);
        start   = 1'b0;

        // pair 1: a ready immediately, b delayed 3 cycles
        a <= 32'd7; a_valid <= 1'b1;
        b_valid <= 1'b0;
        repeat (3) @(posedge clk);
        b <= 32'd3; b_valid <= 1'b1;
        while (!(a_ready && b_ready)) @(posedge clk);
        @(posedge clk);
        a_valid <= 1'b0; b_valid <= 1'b0;
        a <= 0; b <= 0;

        // pair 2: a ready immediately, b delayed 2 cycles
        a <= 32'd4; a_valid <= 1'b1;
        b_valid <= 1'b0;
        repeat (2) @(posedge clk);
        b <= 32'd6; b_valid <= 1'b1;
        while (!(a_ready && b_ready)) @(posedge clk);
        @(posedge clk);
        a_valid <= 1'b0; b_valid <= 1'b0;
        a <= 0; b <= 0;

        // expected: 7*3 + 4*6 = 45
        wait_result(128'd45, "delay_b");

        // Test 6: delay both – both a and b arrive with staggered delays.
        num_acc = 32'd2;
        start   = 1'b1;
        @(posedge clk);
        start   = 1'b0;

        // pair 1: a delayed 2 cycles, b delayed 4 cycles
        a_valid <= 1'b0; b_valid <= 1'b0;
        repeat (2) @(posedge clk);
        a <= 32'd10; a_valid <= 1'b1;
        repeat (2) @(posedge clk);
        b <= 32'd20; b_valid <= 1'b1;
        while (!(a_ready && b_ready)) @(posedge clk);
        @(posedge clk);
        a_valid <= 1'b0; b_valid <= 1'b0;
        a <= 0; b <= 0;

        // pair 2: b delayed 2 cycles, a delayed 4 cycles
        a_valid <= 1'b0; b_valid <= 1'b0;
        repeat (2) @(posedge clk);
        b <= 32'd30; b_valid <= 1'b1;
        repeat (2) @(posedge clk);
        a <= 32'd40; a_valid <= 1'b1;
        while (!(a_ready && b_ready)) @(posedge clk);
        @(posedge clk);
        a_valid <= 1'b0; b_valid <= 1'b0;
        a <= 0; b <= 0;

        // expected: 10*20 + 40*30 = 1400
        wait_result(128'd1400, "delay_both");

        if (errors == 0) begin
            $display("TB RESULT: PASS");
        end else begin
            $display("TB RESULT: FAIL (errors=%0d)", errors);
        end

        #20;
        $finish;
    end

endmodule
