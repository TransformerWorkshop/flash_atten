`timescale 1ns/1ps

module tb_gemm_base #(
	parameter WIDTH = 16,
	parameter X_DIM = 2,
	parameter Y_DIM = 3,
	parameter OUTPUT_BY_ROW = 1
);
	localparam integer GROUP_SIZE = (OUTPUT_BY_ROW != 0) ? Y_DIM : X_DIM;
	localparam integer GROUP_COUNT = (OUTPUT_BY_ROW != 0) ? X_DIM : Y_DIM;
	localparam integer NUM_ACC = 3;
	localparam integer GROUP_WIDTH = GROUP_SIZE * 4 * WIDTH;

	reg clk;
	reg rstn;
	reg clear;
	reg start;
	reg [WIDTH-1:0] num_acc;

	reg a_valid;
	wire a_ready;
	reg [X_DIM*WIDTH-1:0] a;

	reg b_valid;
	wire b_ready;
	reg [Y_DIM*WIDTH-1:0] b;

	wire [GROUP_WIDTH-1:0] m_group_data;
	wire m_group_valid;
	reg m_group_ready;
	wire [31:0] m_group_idx;
	wire m_last;

	integer errors;
	integer g;
	integer wait_cycles;
	integer handshake_seen;
	reg [31:0] hold_idx;
	reg [GROUP_WIDTH-1:0] hold_data;
	reg hold_last;

	GEMM #(
		.WIDTH(WIDTH),
		.X_DIM(X_DIM),
		.Y_DIM(Y_DIM),
		.OUTPUT_BY_ROW(OUTPUT_BY_ROW)
	) dut (
		.clk(clk),
		.rstn(rstn),
		.clear(clear),
		.start(start),
		.num_acc(num_acc),
		.a_valid(a_valid),
		.a_ready(a_ready),
		.a(a),
		.b_valid(b_valid),
		.b_ready(b_ready),
		.b(b),
		.m_group_data(m_group_data),
		.m_group_valid(m_group_valid),
		.m_group_ready(m_group_ready),
		.m_group_idx(m_group_idx),
		.m_last(m_last)
	);

	always #5 clk = ~clk;

	function [GROUP_WIDTH-1:0] expected_group;
		input [31:0] idx;
		begin
			expected_group = {GROUP_WIDTH{1'b0}};
			if (OUTPUT_BY_ROW != 0) begin
				case (idx)
					32'd0: expected_group = {64'd78, 64'd72, 64'd66};
					32'd1: expected_group = {64'd186, 64'd171, 64'd156};
					default: expected_group = {GROUP_WIDTH{1'b0}};
				endcase
			end else begin
				case (idx)
					32'd0: expected_group = {64'd156, 64'd66};
					32'd1: expected_group = {64'd171, 64'd72};
					32'd2: expected_group = {64'd186, 64'd78};
					default: expected_group = {GROUP_WIDTH{1'b0}};
				endcase
			end
		end
	endfunction

	task automatic drive_k_pair;
		input [WIDTH-1:0] a0;
		input [WIDTH-1:0] a1;
		input [WIDTH-1:0] b0;
		input [WIDTH-1:0] b1;
		input [WIDTH-1:0] b2;
		begin
			a = {a1, a0};
			b = {b2, b1, b0};
			a_valid = 1'b1;
			b_valid = 1'b1;
			while (!(a_ready && b_ready)) begin
				@(posedge clk);
			end
			@(posedge clk);
			a_valid = 1'b0;
			b_valid = 1'b0;
			a = {X_DIM*WIDTH{1'b0}};
			b = {Y_DIM*WIDTH{1'b0}};
		end
	endtask

	task automatic check_group;
		input [31:0] exp_idx;
		input exp_last;
		input [GROUP_WIDTH-1:0] exp_data;
		begin
			if (m_group_idx !== exp_idx) begin
				$display("[FAIL] idx mismatch exp=%0d got=%0d state=%0d stream_idx=%0d collected=%0h t=%0t", exp_idx, m_group_idx, dut.state, dut.stream_idx, dut.collected, $time);
				errors = errors + 1;
			end
			if (m_last !== exp_last) begin
				$display("[FAIL] last mismatch exp=%0d got=%0d idx=%0d state=%0d stream_idx=%0d t=%0t", exp_last, m_last, m_group_idx, dut.state, dut.stream_idx, $time);
				errors = errors + 1;
			end
			if (m_group_data !== exp_data) begin
				$display("[FAIL] data mismatch idx=%0d exp=%0h got=%0h state=%0d stream_idx=%0d collected=%0h buf0=%0h buf1=%0h t=%0t",
					exp_idx, exp_data, m_group_data, dut.state, dut.stream_idx, dut.collected, dut.result_buf[0], dut.result_buf[1], $time);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		clk = 1'b0;
		rstn = 1'b0;
		clear = 1'b0;
		start = 1'b0;
		num_acc = {WIDTH{1'b0}};
		a_valid = 1'b0;
		b_valid = 1'b0;
		a = {X_DIM*WIDTH{1'b0}};
		b = {Y_DIM*WIDTH{1'b0}};
		m_group_ready = 1'b0;
		errors = 0;

		repeat (4) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		num_acc = NUM_ACC[WIDTH-1:0];
		start = 1'b1;
		@(posedge clk);
		start = 1'b0;

		drive_k_pair(16'd1, 16'd4, 16'd7, 16'd8, 16'd9);
		drive_k_pair(16'd2, 16'd5, 16'd10, 16'd11, 16'd12);
		drive_k_pair(16'd3, 16'd6, 16'd13, 16'd14, 16'd15);

		wait_cycles = 0;
		while (m_group_valid !== 1'b1 && wait_cycles < 2000) begin
			@(posedge clk);
			wait_cycles = wait_cycles + 1;
		end
		if (m_group_valid !== 1'b1) begin
			$display("[FAIL] timeout waiting first m_group_valid, state=%0d collected=%0h t=%0t", dut.state, dut.collected, $time);
			errors = errors + 1;
			$finish;
		end

		hold_idx = m_group_idx;
		hold_data = m_group_data;
		hold_last = m_last;
		repeat (3) begin
			@(posedge clk);
			if (m_group_valid !== 1'b1) begin
				$display("[FAIL] valid dropped during backpressure t=%0t", $time);
				errors = errors + 1;
			end
			if (m_group_idx !== hold_idx || m_group_data !== hold_data || m_last !== hold_last) begin
				$display("[FAIL] group changed during backpressure t=%0t", $time);
				errors = errors + 1;
			end
		end
		m_group_ready = 1'b1;

		for (g = 0; g < GROUP_COUNT; g = g + 1) begin
			wait_cycles = 0;
			handshake_seen = 0;
			while (wait_cycles < 2000 && handshake_seen == 0) begin
				@(posedge clk);
				wait_cycles = wait_cycles + 1;
				if ((m_group_valid === 1'b1) && (m_group_ready === 1'b1)) begin
					check_group(g[31:0], (g == GROUP_COUNT - 1), expected_group(g[31:0]));
					handshake_seen = 1;
				end
			end
			if (handshake_seen == 0) begin
				$display("[FAIL] timeout waiting handshake for group %0d, state=%0d idx=%0d t=%0t", g, dut.state, dut.stream_idx, $time);
				errors = errors + 1;
				$finish;
			end
		end

		if (errors == 0) begin
			if (OUTPUT_BY_ROW != 0) begin
				$display("TB RESULT (ROW): PASS");
			end else begin
				$display("TB RESULT (COL): PASS");
			end
		end else begin
			if (OUTPUT_BY_ROW != 0) begin
				$display("TB RESULT (ROW): FAIL (errors=%0d)", errors);
			end else begin
				$display("TB RESULT (COL): FAIL (errors=%0d)", errors);
			end
		end

		#20;
		$finish;
	end

endmodule

module tb_gemm;
	tb_gemm_base #(
		.OUTPUT_BY_ROW(1)
	) u_tb_gemm_base ();
endmodule

module tb_gemm_col;
	tb_gemm_base #(
		.OUTPUT_BY_ROW(0)
	) u_tb_gemm_base ();
endmodule
