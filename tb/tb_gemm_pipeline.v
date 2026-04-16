`timescale 1ns/1ps

// Pipeline-specific testbench: verifies that the 2-state GEMM streams
// results directly from PE FIFOs without a multi-cycle collect gap.
module tb_gemm_pipeline #(
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
	wire a_ready, b_ready;

	reg [WIDTH-1:0] a_matrix [0:X_DIM*NUM_ACC-1];
	reg [WIDTH-1:0] b_matrix [0:NUM_ACC*Y_DIM-1];
	reg [4*WIDTH-1:0] expected_matrix [0:X_DIM*Y_DIM-1];

	integer errors, g, k, wait_cycles, handshake_seen;
	integer last_input_cycle, first_valid_cycle, latency;
	integer prev_handshake_cycle, cur_handshake_cycle, gap;
	integer total_gaps, max_gap;

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

	// Cycle counter for latency measurement
	integer cycle_cnt;
	always @(posedge clk) begin
		if (!rstn) cycle_cnt <= 0;
		else cycle_cnt <= cycle_cnt + 1;
	end

	initial begin
		clk = 0; rstn = 0; clear = 0; start = 0;
		num_acc = 0; a_valid = 0; b_valid = 0;
		a = 0; b = 0; m_group_ready = 0;
		errors = 0; last_input_cycle = 0; first_valid_cycle = 0;
		total_gaps = 0; max_gap = 0;
		init_matrices();
		repeat (4) @(posedge clk);
		rstn = 1; @(posedge clk);

		// ===== Test 1: Measure latency from last input to first m_group_valid =====
		$display("[INFO] Test 1: Measure input-to-output latency");
		num_acc = NUM_ACC[WIDTH-1:0];
		start = 1; @(posedge clk); start = 0;
		for (k = 0; k < NUM_ACC; k = k + 1) begin
			a = pack_a_col(k); b = pack_b_row(k);
			a_valid = 1; b_valid = 1;
			while (!(a_valid && b_valid && a_ready && b_ready)) @(posedge clk);
			if (k == NUM_ACC - 1) last_input_cycle = cycle_cnt;
			@(posedge clk);
			a_valid = 0; b_valid = 0; a = 0; b = 0;
		end

		// Wait for first valid
		wait_cycles = 0;
		while (m_group_valid !== 1'b1 && wait_cycles < 2000) begin
			@(posedge clk);
			wait_cycles = wait_cycles + 1;
		end
		first_valid_cycle = cycle_cnt;
		latency = first_valid_cycle - last_input_cycle;
		$display("[INFO] Last input accepted at cycle %0d, first m_group_valid at cycle %0d, latency = %0d cycles",
			last_input_cycle, first_valid_cycle, latency);

		// The pipelined design should have no collect gap.
		// GEMU: 1 cycle to push result into FIFO. FIFO: 1 cycle output latency.
		// Allow up to 4 cycles for PE FIFO pipeline.
		if (latency > 4) begin
			$display("[FAIL] latency %0d cycles exceeds pipeline expectation (max 4)", latency);
			errors = errors + 1;
		end else begin
			$display("[PASS] latency %0d cycles is within pipeline expectation", latency);
		end

		// ===== Test 2: Sustained streaming (m_group_ready always high) =====
		$display("[INFO] Test 2: Check sustained streaming throughput");
		m_group_ready = 1;
		prev_handshake_cycle = cycle_cnt;

		for (g = 0; g < GROUP_COUNT; g = g + 1) begin
			wait_cycles = 0; handshake_seen = 0;
			while (wait_cycles < 2000 && handshake_seen == 0) begin
				@(posedge clk); wait_cycles = wait_cycles + 1;
				if (m_group_valid && m_group_ready) begin
					cur_handshake_cycle = cycle_cnt;
					if (g > 0) begin
						gap = cur_handshake_cycle - prev_handshake_cycle;
						if (gap > 1) begin
							total_gaps = total_gaps + 1;
							$display("[INFO] Gap of %0d cycles between group %0d and %0d", gap, g-1, g);
						end
						if (gap > max_gap) max_gap = gap;
					end
					prev_handshake_cycle = cur_handshake_cycle;
					// Also verify data correctness
					if (m_group_data !== expected_group(g[31:0])) begin
						$display("[FAIL] pipeline: group %0d data mismatch t=%0t", g, $time);
						errors = errors + 1;
					end
					handshake_seen = 1;
				end
			end
			if (!handshake_seen) begin
				$display("[FAIL] pipeline: timeout at group %0d t=%0t", g, $time);
				errors = errors + 1; $finish;
			end
		end

		$display("[INFO] Sustained streaming: max_gap=%0d, total_gaps=%0d out of %0d groups",
			max_gap, total_gaps, GROUP_COUNT);

		// With pipelined design and all PEs finishing simultaneously,
		// groups should stream back-to-back (gap=1) since all PE results
		// are available in their FIFOs.
		if (max_gap > 1) begin
			$display("[WARN] Non-zero inter-group gaps detected (max=%0d). Expected 1-cycle per group.", max_gap);
		end

		m_group_ready = 0;

		if (errors == 0) $display("TB RESULT (PIPELINE): PASS");
		else $display("TB RESULT (PIPELINE): FAIL (errors=%0d)", errors);
		#20; $finish;
	end
endmodule
