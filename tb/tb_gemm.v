`timescale 1ns/1ps

module tb_gemm_base #(
	parameter WIDTH = 16,
	parameter X_DIM = 8,
	parameter Y_DIM = 8,
	parameter OUTPUT_BY_ROW = 1
);
	localparam integer NUM_ACC = 8;
	localparam integer GROUP_SIZE = (OUTPUT_BY_ROW != 0) ? Y_DIM : X_DIM;
	localparam integer GROUP_COUNT = (OUTPUT_BY_ROW != 0) ? X_DIM : Y_DIM;
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

	reg [WIDTH-1:0] a_matrix [0:X_DIM*NUM_ACC-1];
	reg [WIDTH-1:0] b_matrix [0:NUM_ACC*Y_DIM-1];
	reg [4*WIDTH-1:0] expected_matrix [0:X_DIM*Y_DIM-1];

	integer errors;
	integer g;
	integer k;
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

	function [X_DIM*WIDTH-1:0] pack_a_col;
		input integer col_idx;
		integer row_idx;
		begin
			pack_a_col = {X_DIM*WIDTH{1'b0}};
			for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
				pack_a_col[row_idx*WIDTH +: WIDTH] = a_matrix[row_idx*NUM_ACC + col_idx];
			end
		end
	endfunction

	function [Y_DIM*WIDTH-1:0] pack_b_row;
		input integer row_idx;
		integer col_idx;
		begin
			pack_b_row = {Y_DIM*WIDTH{1'b0}};
			for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
				pack_b_row[col_idx*WIDTH +: WIDTH] = b_matrix[row_idx*Y_DIM + col_idx];
			end
		end
	endfunction

	function [GROUP_WIDTH-1:0] expected_group;
		input [31:0] idx;
		integer lane_idx;
		begin
			expected_group = {GROUP_WIDTH{1'b0}};
			if (OUTPUT_BY_ROW != 0) begin
				for (lane_idx = 0; lane_idx < Y_DIM; lane_idx = lane_idx + 1) begin
					expected_group[lane_idx*4*WIDTH +: 4*WIDTH] =
						expected_matrix[idx*Y_DIM + lane_idx];
				end
			end else begin
				for (lane_idx = 0; lane_idx < X_DIM; lane_idx = lane_idx + 1) begin
					expected_group[lane_idx*4*WIDTH +: 4*WIDTH] =
						expected_matrix[lane_idx*Y_DIM + idx];
				end
			end
		end
	endfunction

	task automatic init_matrices;
		integer row_idx;
		integer col_idx;
		integer acc_idx;
		integer sum;
		begin
			for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
				for (col_idx = 0; col_idx < NUM_ACC; col_idx = col_idx + 1) begin
					a_matrix[row_idx*NUM_ACC + col_idx] =
						((row_idx + 1) * 3 + col_idx + 1);
				end
			end

			for (row_idx = 0; row_idx < NUM_ACC; row_idx = row_idx + 1) begin
				for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
					b_matrix[row_idx*Y_DIM + col_idx] =
						(((row_idx * 2) + col_idx) % 5) + 1;
				end
			end

			for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
				for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
					sum = 0;
					for (acc_idx = 0; acc_idx < NUM_ACC; acc_idx = acc_idx + 1) begin
						sum = sum +
						      (a_matrix[row_idx*NUM_ACC + acc_idx] *
						       b_matrix[acc_idx*Y_DIM + col_idx]);
					end
					expected_matrix[row_idx*Y_DIM + col_idx] =
						{{(4*WIDTH-32){1'b0}}, sum[31:0]};
				end
			end
		end
	endtask

	task automatic drive_k_pair;
		input integer acc_idx;
		begin
			a = pack_a_col(acc_idx);
			b = pack_b_row(acc_idx);
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
					$display("[FAIL] idx mismatch exp=%0d got=%0d ready_tiles=%0d stream_idx=%0d t=%0t",
						exp_idx, m_group_idx, dut.ready_tile_count_r, dut.stream_idx, $time);
					errors = errors + 1;
				end
				if (m_last !== exp_last) begin
					$display("[FAIL] last mismatch exp=%0d got=%0d idx=%0d ready_tiles=%0d stream_idx=%0d t=%0t",
						exp_last, m_last, m_group_idx, dut.ready_tile_count_r, dut.stream_idx, $time);
					errors = errors + 1;
				end
				if (m_group_data !== exp_data) begin
					$display("[FAIL] data mismatch idx=%0d exp=%0h got=%0h ready_tiles=%0d stream_idx=%0d t=%0t",
						exp_idx, exp_data, m_group_data, dut.ready_tile_count_r, dut.stream_idx, $time);
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

		init_matrices();

		repeat (4) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		num_acc = NUM_ACC[WIDTH-1:0];
		start = 1'b1;
		@(posedge clk);
		start = 1'b0;

		for (k = 0; k < NUM_ACC; k = k + 1) begin
			drive_k_pair(k);
		end

		wait_cycles = 0;
		while (m_group_valid !== 1'b1 && wait_cycles < 2000) begin
			@(posedge clk);
			wait_cycles = wait_cycles + 1;
		end
			if (m_group_valid !== 1'b1) begin
				$display("[FAIL] timeout waiting first m_group_valid, ready_tiles=%0d stream_idx=%0d t=%0t",
					dut.ready_tile_count_r, dut.stream_idx, $time);
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
					$display("[FAIL] timeout waiting handshake for group %0d, ready_tiles=%0d idx=%0d t=%0t",
						g, dut.ready_tile_count_r, dut.stream_idx, $time);
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

// ---------- tb_gemm_small: 2x2 tile ----------
module tb_gemm_small;
	tb_gemm_base #(
		.WIDTH(16),
		.X_DIM(2),
		.Y_DIM(2),
		.OUTPUT_BY_ROW(1)
	) u_tb_gemm_base ();
endmodule

// ---------- tb_gemm_backpressure: intermittent m_group_ready ----------
module tb_gemm_backpressure #(
	parameter WIDTH = 16,
	parameter X_DIM = 4,
	parameter Y_DIM = 4
);
	localparam integer NUM_ACC = 4;
	localparam integer GROUP_SIZE = Y_DIM;
	localparam integer GROUP_COUNT = X_DIM;
	localparam integer GROUP_WIDTH = GROUP_SIZE * 4 * WIDTH;

	reg clk, rstn, clear, start;
	reg [WIDTH-1:0] num_acc;
	reg a_valid, b_valid;
	reg [X_DIM*WIDTH-1:0] a;
	reg [Y_DIM*WIDTH-1:0] b;
	wire [GROUP_WIDTH-1:0] m_group_data;
	wire m_group_valid;
	reg m_group_ready;
	wire [31:0] m_group_idx;
	wire m_last;

	reg [WIDTH-1:0] a_matrix [0:X_DIM*NUM_ACC-1];
	reg [WIDTH-1:0] b_matrix [0:NUM_ACC*Y_DIM-1];
	reg [4*WIDTH-1:0] expected_matrix [0:X_DIM*Y_DIM-1];

	integer errors, g, k, wait_cycles, handshake_seen, bp_cnt;
	wire a_ready, b_ready;

	GEMM #(.WIDTH(WIDTH), .X_DIM(X_DIM), .Y_DIM(Y_DIM), .OUTPUT_BY_ROW(1)) dut (
		.clk(clk), .rstn(rstn), .clear(clear), .start(start), .num_acc(num_acc),
		.a_valid(a_valid), .a_ready(a_ready), .a(a),
		.b_valid(b_valid), .b_ready(b_ready), .b(b),
		.m_group_data(m_group_data), .m_group_valid(m_group_valid),
		.m_group_ready(m_group_ready), .m_group_idx(m_group_idx), .m_last(m_last)
	);

	always #5 clk = ~clk;

	function [X_DIM*WIDTH-1:0] pack_a_col;
		input integer col_idx;
		integer ri;
		begin
			pack_a_col = {X_DIM*WIDTH{1'b0}};
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				pack_a_col[ri*WIDTH +: WIDTH] = a_matrix[ri*NUM_ACC + col_idx];
		end
	endfunction

	function [Y_DIM*WIDTH-1:0] pack_b_row;
		input integer row_idx;
		integer ci;
		begin
			pack_b_row = {Y_DIM*WIDTH{1'b0}};
			for (ci = 0; ci < Y_DIM; ci = ci + 1)
				pack_b_row[ci*WIDTH +: WIDTH] = b_matrix[row_idx*Y_DIM + ci];
		end
	endfunction

	function [GROUP_WIDTH-1:0] expected_group;
		input [31:0] idx;
		integer li;
		begin
			expected_group = {GROUP_WIDTH{1'b0}};
			for (li = 0; li < Y_DIM; li = li + 1)
				expected_group[li*4*WIDTH +: 4*WIDTH] = expected_matrix[idx*Y_DIM + li];
		end
	endfunction

	task automatic init_matrices;
		integer ri, ci, ai, s;
		begin
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				for (ci = 0; ci < NUM_ACC; ci = ci + 1)
					a_matrix[ri*NUM_ACC + ci] = ((ri + 1) * 3 + ci + 1);
			for (ri = 0; ri < NUM_ACC; ri = ri + 1)
				for (ci = 0; ci < Y_DIM; ci = ci + 1)
					b_matrix[ri*Y_DIM + ci] = (((ri * 2) + ci) % 5) + 1;
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				for (ci = 0; ci < Y_DIM; ci = ci + 1) begin
					s = 0;
					for (ai = 0; ai < NUM_ACC; ai = ai + 1)
						s = s + (a_matrix[ri*NUM_ACC + ai] * b_matrix[ai*Y_DIM + ci]);
					expected_matrix[ri*Y_DIM + ci] = {{(4*WIDTH-32){1'b0}}, s[31:0]};
				end
		end
	endtask

	initial begin
		clk = 0; rstn = 0; clear = 0; start = 0;
		num_acc = 0; a_valid = 0; b_valid = 0;
		a = 0; b = 0; m_group_ready = 0;
		errors = 0; bp_cnt = 0;
		init_matrices();
		repeat (4) @(posedge clk);
		rstn = 1; @(posedge clk);
		num_acc = NUM_ACC[WIDTH-1:0];
		start = 1; @(posedge clk); start = 0;
		for (k = 0; k < NUM_ACC; k = k + 1) begin
			a = pack_a_col(k); b = pack_b_row(k);
			a_valid = 1; b_valid = 1;
			while (!(a_ready && b_ready)) @(posedge clk);
			@(posedge clk);
			a_valid = 0; b_valid = 0; a = 0; b = 0;
		end

		// Intermittent backpressure: 1 cycle ready, 2 cycles not ready
		for (g = 0; g < GROUP_COUNT; g = g + 1) begin
			wait_cycles = 0; handshake_seen = 0;
			while (wait_cycles < 2000 && handshake_seen == 0) begin
				m_group_ready = (bp_cnt == 0) ? 1'b1 : 1'b0;
				@(posedge clk);
				wait_cycles = wait_cycles + 1;
				if (m_group_valid && m_group_ready) begin
					if (m_group_idx !== g[31:0] || m_group_data !== expected_group(g[31:0])) begin
						$display("[FAIL] backpressure: data/idx mismatch at group %0d t=%0t", g, $time);
						errors = errors + 1;
					end
					if (m_last !== ((g == GROUP_COUNT - 1) ? 1'b1 : 1'b0)) begin
						$display("[FAIL] backpressure: last mismatch at group %0d t=%0t", g, $time);
						errors = errors + 1;
					end
					handshake_seen = 1;
				end
				bp_cnt = (bp_cnt == 2) ? 0 : bp_cnt + 1;
			end
			if (handshake_seen == 0) begin
				$display("[FAIL] backpressure: timeout at group %0d t=%0t", g, $time);
				errors = errors + 1; $finish;
			end
		end
		m_group_ready = 0;
		if (errors == 0) $display("TB RESULT (BACKPRESSURE): PASS");
		else $display("TB RESULT (BACKPRESSURE): FAIL (errors=%0d)", errors);
		#20; $finish;
	end
endmodule

// ---------- tb_gemm_back2back: two consecutive GEMMs without reset ----------
module tb_gemm_back2back #(
	parameter WIDTH = 16,
	parameter X_DIM = 4,
	parameter Y_DIM = 4
);
	localparam integer NUM_ACC = 4;
	localparam integer GROUP_SIZE = Y_DIM;
	localparam integer GROUP_COUNT = X_DIM;
	localparam integer GROUP_WIDTH = GROUP_SIZE * 4 * WIDTH;

	reg clk, rstn, clear, start;
	reg [WIDTH-1:0] num_acc;
	reg a_valid, b_valid;
	reg [X_DIM*WIDTH-1:0] a;
	reg [Y_DIM*WIDTH-1:0] b;
	wire [GROUP_WIDTH-1:0] m_group_data;
	wire m_group_valid;
	reg m_group_ready;
	wire [31:0] m_group_idx;
	wire m_last;

	reg [WIDTH-1:0] a_matrix [0:X_DIM*NUM_ACC-1];
	reg [WIDTH-1:0] b_matrix [0:NUM_ACC*Y_DIM-1];
	reg [4*WIDTH-1:0] expected_matrix [0:X_DIM*Y_DIM-1];

	integer errors, g, k, wait_cycles, handshake_seen, run_idx;
	wire a_ready, b_ready;

	GEMM #(.WIDTH(WIDTH), .X_DIM(X_DIM), .Y_DIM(Y_DIM), .OUTPUT_BY_ROW(1)) dut (
		.clk(clk), .rstn(rstn), .clear(clear), .start(start), .num_acc(num_acc),
		.a_valid(a_valid), .a_ready(a_ready), .a(a),
		.b_valid(b_valid), .b_ready(b_ready), .b(b),
		.m_group_data(m_group_data), .m_group_valid(m_group_valid),
		.m_group_ready(m_group_ready), .m_group_idx(m_group_idx), .m_last(m_last)
	);

	always #5 clk = ~clk;

	function [X_DIM*WIDTH-1:0] pack_a_col;
		input integer col_idx;
		integer ri;
		begin
			pack_a_col = {X_DIM*WIDTH{1'b0}};
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				pack_a_col[ri*WIDTH +: WIDTH] = a_matrix[ri*NUM_ACC + col_idx];
		end
	endfunction

	function [Y_DIM*WIDTH-1:0] pack_b_row;
		input integer row_idx;
		integer ci;
		begin
			pack_b_row = {Y_DIM*WIDTH{1'b0}};
			for (ci = 0; ci < Y_DIM; ci = ci + 1)
				pack_b_row[ci*WIDTH +: WIDTH] = b_matrix[row_idx*Y_DIM + ci];
		end
	endfunction

	function [GROUP_WIDTH-1:0] expected_group;
		input [31:0] idx;
		integer li;
		begin
			expected_group = {GROUP_WIDTH{1'b0}};
			for (li = 0; li < Y_DIM; li = li + 1)
				expected_group[li*4*WIDTH +: 4*WIDTH] = expected_matrix[idx*Y_DIM + li];
		end
	endfunction

	task automatic init_matrices;
		input integer offset;
		integer ri, ci, ai, s;
		begin
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				for (ci = 0; ci < NUM_ACC; ci = ci + 1)
					a_matrix[ri*NUM_ACC + ci] = ((ri + 1) * 3 + ci + 1 + offset);
			for (ri = 0; ri < NUM_ACC; ri = ri + 1)
				for (ci = 0; ci < Y_DIM; ci = ci + 1)
					b_matrix[ri*Y_DIM + ci] = (((ri * 2) + ci + offset) % 5) + 1;
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				for (ci = 0; ci < Y_DIM; ci = ci + 1) begin
					s = 0;
					for (ai = 0; ai < NUM_ACC; ai = ai + 1)
						s = s + (a_matrix[ri*NUM_ACC + ai] * b_matrix[ai*Y_DIM + ci]);
					expected_matrix[ri*Y_DIM + ci] = {{(4*WIDTH-32){1'b0}}, s[31:0]};
				end
		end
	endtask

	initial begin
		clk = 0; rstn = 0; clear = 0; start = 0;
		num_acc = 0; a_valid = 0; b_valid = 0;
		a = 0; b = 0; m_group_ready = 0;
		errors = 0;
		repeat (4) @(posedge clk);
		rstn = 1; @(posedge clk);

		for (run_idx = 0; run_idx < 2; run_idx = run_idx + 1) begin
			init_matrices(run_idx * 7);
			num_acc = NUM_ACC[WIDTH-1:0];
			start = 1; @(posedge clk); start = 0;
			for (k = 0; k < NUM_ACC; k = k + 1) begin
				a = pack_a_col(k); b = pack_b_row(k);
				a_valid = 1; b_valid = 1;
				while (!(a_ready && b_ready)) @(posedge clk);
				@(posedge clk);
				a_valid = 0; b_valid = 0; a = 0; b = 0;
			end
			m_group_ready = 1;
			for (g = 0; g < GROUP_COUNT; g = g + 1) begin
				wait_cycles = 0; handshake_seen = 0;
				while (wait_cycles < 2000 && handshake_seen == 0) begin
					@(posedge clk); wait_cycles = wait_cycles + 1;
					if (m_group_valid && m_group_ready) begin
						if (m_group_data !== expected_group(g[31:0])) begin
							$display("[FAIL] back2back run %0d group %0d data mismatch t=%0t",
								run_idx, g, $time);
							errors = errors + 1;
						end
						handshake_seen = 1;
					end
				end
				if (!handshake_seen) begin
					$display("[FAIL] back2back run %0d timeout at group %0d t=%0t", run_idx, g, $time);
					errors = errors + 1; $finish;
				end
			end
			m_group_ready = 0;
			@(posedge clk);
		end

		if (errors == 0) $display("TB RESULT (BACK2BACK): PASS");
		else $display("TB RESULT (BACK2BACK): FAIL (errors=%0d)", errors);
		#20; $finish;
	end
endmodule

// ---------- tb_gemm_clear: clear mid-computation, then restart ----------
module tb_gemm_clear #(
	parameter WIDTH = 16,
	parameter X_DIM = 4,
	parameter Y_DIM = 4
);
	localparam integer NUM_ACC = 4;
	localparam integer GROUP_SIZE = Y_DIM;
	localparam integer GROUP_COUNT = X_DIM;
	localparam integer GROUP_WIDTH = GROUP_SIZE * 4 * WIDTH;

	reg clk, rstn, clear, start;
	reg [WIDTH-1:0] num_acc;
	reg a_valid, b_valid;
	reg [X_DIM*WIDTH-1:0] a;
	reg [Y_DIM*WIDTH-1:0] b;
	wire [GROUP_WIDTH-1:0] m_group_data;
	wire m_group_valid;
	reg m_group_ready;
	wire [31:0] m_group_idx;
	wire m_last;

	reg [WIDTH-1:0] a_matrix [0:X_DIM*NUM_ACC-1];
	reg [WIDTH-1:0] b_matrix [0:NUM_ACC*Y_DIM-1];
	reg [4*WIDTH-1:0] expected_matrix [0:X_DIM*Y_DIM-1];

	integer errors, g, k, wait_cycles, handshake_seen;
	wire a_ready, b_ready;

	GEMM #(.WIDTH(WIDTH), .X_DIM(X_DIM), .Y_DIM(Y_DIM), .OUTPUT_BY_ROW(1)) dut (
		.clk(clk), .rstn(rstn), .clear(clear), .start(start), .num_acc(num_acc),
		.a_valid(a_valid), .a_ready(a_ready), .a(a),
		.b_valid(b_valid), .b_ready(b_ready), .b(b),
		.m_group_data(m_group_data), .m_group_valid(m_group_valid),
		.m_group_ready(m_group_ready), .m_group_idx(m_group_idx), .m_last(m_last)
	);

	always #5 clk = ~clk;

	function [X_DIM*WIDTH-1:0] pack_a_col;
		input integer col_idx;
		integer ri;
		begin
			pack_a_col = {X_DIM*WIDTH{1'b0}};
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				pack_a_col[ri*WIDTH +: WIDTH] = a_matrix[ri*NUM_ACC + col_idx];
		end
	endfunction

	function [Y_DIM*WIDTH-1:0] pack_b_row;
		input integer row_idx;
		integer ci;
		begin
			pack_b_row = {Y_DIM*WIDTH{1'b0}};
			for (ci = 0; ci < Y_DIM; ci = ci + 1)
				pack_b_row[ci*WIDTH +: WIDTH] = b_matrix[row_idx*Y_DIM + ci];
		end
	endfunction

	function [GROUP_WIDTH-1:0] expected_group;
		input [31:0] idx;
		integer li;
		begin
			expected_group = {GROUP_WIDTH{1'b0}};
			for (li = 0; li < Y_DIM; li = li + 1)
				expected_group[li*4*WIDTH +: 4*WIDTH] = expected_matrix[idx*Y_DIM + li];
		end
	endfunction

	task automatic init_matrices;
		integer ri, ci, ai, s;
		begin
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				for (ci = 0; ci < NUM_ACC; ci = ci + 1)
					a_matrix[ri*NUM_ACC + ci] = ((ri + 1) * 3 + ci + 1);
			for (ri = 0; ri < NUM_ACC; ri = ri + 1)
				for (ci = 0; ci < Y_DIM; ci = ci + 1)
					b_matrix[ri*Y_DIM + ci] = (((ri * 2) + ci) % 5) + 1;
			for (ri = 0; ri < X_DIM; ri = ri + 1)
				for (ci = 0; ci < Y_DIM; ci = ci + 1) begin
					s = 0;
					for (ai = 0; ai < NUM_ACC; ai = ai + 1)
						s = s + (a_matrix[ri*NUM_ACC + ai] * b_matrix[ai*Y_DIM + ci]);
					expected_matrix[ri*Y_DIM + ci] = {{(4*WIDTH-32){1'b0}}, s[31:0]};
				end
		end
	endtask

	initial begin
		clk = 0; rstn = 0; clear = 0; start = 0;
		num_acc = 0; a_valid = 0; b_valid = 0;
		a = 0; b = 0; m_group_ready = 0;
		errors = 0;
		init_matrices();
		repeat (4) @(posedge clk);
		rstn = 1; @(posedge clk);

		// Start first GEMM, feed half data, then clear
		num_acc = NUM_ACC[WIDTH-1:0];
		start = 1; @(posedge clk); start = 0;
		for (k = 0; k < NUM_ACC / 2; k = k + 1) begin
			a = pack_a_col(k); b = pack_b_row(k);
			a_valid = 1; b_valid = 1;
			while (!(a_ready && b_ready)) @(posedge clk);
			@(posedge clk);
			a_valid = 0; b_valid = 0; a = 0; b = 0;
		end
		clear = 1; @(posedge clk); clear = 0;
		repeat (2) @(posedge clk);

		// Restart fresh GEMM — should produce correct results
		start = 1; @(posedge clk); start = 0;
		for (k = 0; k < NUM_ACC; k = k + 1) begin
			a = pack_a_col(k); b = pack_b_row(k);
			a_valid = 1; b_valid = 1;
			while (!(a_ready && b_ready)) @(posedge clk);
			@(posedge clk);
			a_valid = 0; b_valid = 0; a = 0; b = 0;
		end
		m_group_ready = 1;
		for (g = 0; g < GROUP_COUNT; g = g + 1) begin
			wait_cycles = 0; handshake_seen = 0;
			while (wait_cycles < 2000 && handshake_seen == 0) begin
				@(posedge clk); wait_cycles = wait_cycles + 1;
				if (m_group_valid && m_group_ready) begin
					if (m_group_data !== expected_group(g[31:0])) begin
						$display("[FAIL] clear: group %0d data mismatch t=%0t", g, $time);
						errors = errors + 1;
					end
					handshake_seen = 1;
				end
			end
			if (!handshake_seen) begin
				$display("[FAIL] clear: timeout at group %0d t=%0t", g, $time);
				errors = errors + 1; $finish;
			end
		end
		m_group_ready = 0;

		if (errors == 0) $display("TB RESULT (CLEAR): PASS");
		else $display("TB RESULT (CLEAR): FAIL (errors=%0d)", errors);
		#20; $finish;
	end
endmodule
