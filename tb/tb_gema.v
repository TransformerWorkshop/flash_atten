`timescale 1ns/1ps

module tb_gema;
	localparam DATA_WIDTH = 8;
	localparam GEMM_Y_DIM = 4;
	localparam EXPECT_DEPTH = 16;

	reg clk;
	reg rstn;
	reg clear;

	reg                              in_valid;
	wire                             in_ready;
	reg  [GEMM_Y_DIM*DATA_WIDTH-1:0] lhs_data;
	reg  [GEMM_Y_DIM*DATA_WIDTH-1:0] rhs_data;
	reg  [31:0]                      in_idx;
	reg                              in_last;
	wire                             out_valid;
	reg                              out_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] out_data;
	wire [31:0]                      out_idx;
	wire                             out_last;

	integer errors;
	integer cycles;
	integer exp_head;
	integer exp_tail;
	integer exp_count;
	integer lane_idx;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_data_q [0:EXPECT_DEPTH-1];
	reg [31:0]                      exp_idx_q [0:EXPECT_DEPTH-1];
	reg                             exp_last_q [0:EXPECT_DEPTH-1];
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] stable_data;
	reg [31:0]                      stable_idx;
	reg                             stable_last;

	always #5 clk = ~clk;

	GEMA #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) dut (
		.clk      (clk      ),
		.rstn     (rstn     ),
		.clear    (clear    ),
		.in_valid (in_valid ),
		.in_ready (in_ready ),
		.lhs_data (lhs_data ),
		.rhs_data (rhs_data ),
		.in_idx   (in_idx   ),
		.in_last  (in_last  ),
		.out_valid(out_valid),
		.out_ready(out_ready),
		.out_data (out_data ),
		.out_idx  (out_idx  ),
		.out_last (out_last )
	);

	function signed [DATA_WIDTH-1:0] sat_add_ref;
		input signed [DATA_WIDTH-1:0] lhs;
		input signed [DATA_WIDTH-1:0] rhs;
		reg signed [DATA_WIDTH:0] sum_ext;
		integer sat_max;
		integer sat_min;
		begin
			sum_ext = lhs + rhs;
			sat_max = (1 << (DATA_WIDTH - 1)) - 1;
			sat_min = -(1 << (DATA_WIDTH - 1));
			if (sum_ext > sat_max) begin
				sat_add_ref = {1'b0, {(DATA_WIDTH-1){1'b1}}};
			end else if (sum_ext < sat_min) begin
				sat_add_ref = {1'b1, {(DATA_WIDTH-1){1'b0}}};
			end else begin
				sat_add_ref = sum_ext[DATA_WIDTH-1:0];
			end
		end
	endfunction

	task automatic set_rows;
		input signed [31:0] lhs0;
		input signed [31:0] lhs1;
		input signed [31:0] lhs2;
		input signed [31:0] lhs3;
		input signed [31:0] rhs0;
		input signed [31:0] rhs1;
		input signed [31:0] rhs2;
		input signed [31:0] rhs3;
		begin
			lhs_data = {lhs3[DATA_WIDTH-1:0], lhs2[DATA_WIDTH-1:0], lhs1[DATA_WIDTH-1:0], lhs0[DATA_WIDTH-1:0]};
			rhs_data = {rhs3[DATA_WIDTH-1:0], rhs2[DATA_WIDTH-1:0], rhs1[DATA_WIDTH-1:0], rhs0[DATA_WIDTH-1:0]};
		end
	endtask

	task automatic push_expected;
		input [31:0] row_idx;
		input row_last;
		reg [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_row;
		begin
			if (exp_count >= EXPECT_DEPTH) begin
				$display("[FAIL] expectation queue overflow");
				errors = errors + 1;
			end else begin
				exp_row = {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
				for (lane_idx = 0; lane_idx < GEMM_Y_DIM; lane_idx = lane_idx + 1) begin
					exp_row[lane_idx*DATA_WIDTH +: DATA_WIDTH] =
						sat_add_ref(
							$signed(lhs_data[lane_idx*DATA_WIDTH +: DATA_WIDTH]),
							$signed(rhs_data[lane_idx*DATA_WIDTH +: DATA_WIDTH])
						);
				end
				exp_data_q[exp_tail] = exp_row;
				exp_idx_q[exp_tail] = row_idx;
				exp_last_q[exp_tail] = row_last;
				exp_tail = (exp_tail + 1) % EXPECT_DEPTH;
				exp_count = exp_count + 1;
			end
		end
	endtask

	task automatic drive_row;
		input [31:0] row_idx;
		input row_last;
		reg handshake_seen;
		begin
			@(negedge clk);
			push_expected(row_idx, row_last);
			in_idx = row_idx;
			in_last = row_last;
			in_valid = 1'b1;
			handshake_seen = 1'b0;
			while (!handshake_seen) begin
				@(posedge clk);
				handshake_seen = in_ready;
			end
			#1;
			in_valid = 1'b0;
		end
	endtask

	task automatic wait_for_expected_drain;
		begin
			while (exp_count != 0) begin
				@(posedge clk);
			end
			repeat (2) begin
				@(posedge clk);
			end
		end
	endtask

	task automatic backpressure_check;
		begin
			out_ready = 1'b0;
			set_rows(32'sd12, -32'sd9, 32'sd3, -32'sd2, 32'sd4, 32'sd5, -32'sd7, 32'sd6);
			drive_row(32'd4, 1'b0);
			@(negedge clk);
			#1;
			if (!out_valid) begin
				$display("[FAIL] expected held output under backpressure");
				errors = errors + 1;
			end
			if (in_ready) begin
				$display("[FAIL] expected input stall while output is blocked");
				errors = errors + 1;
			end
			stable_data = out_data;
			stable_idx = out_idx;
			stable_last = out_last;
			repeat (3) begin
				@(posedge clk);
				#1;
				if (!out_valid || out_data !== stable_data || out_idx !== stable_idx || out_last !== stable_last) begin
					$display("[FAIL] output changed while backpressured");
					errors = errors + 1;
				end
				if (in_ready) begin
					$display("[FAIL] input ready reasserted before output drain");
					errors = errors + 1;
				end
			end

			@(negedge clk);
			out_ready = 1'b1;
			wait_for_expected_drain();
			set_rows(-32'sd7, 32'sd6, -32'sd5, 32'sd4, 32'sd3, -32'sd2, 32'sd1, -32'sd8);
			drive_row(32'd5, 1'b1);
			wait_for_expected_drain();
		end
	endtask

	always @(posedge clk) begin
		if (!rstn || clear) begin
			exp_head <= 0;
			exp_tail <= 0;
			exp_count <= 0;
			cycles <= 0;
		end else begin
			cycles <= cycles + 1;
			if (out_valid && out_ready) begin
				if (exp_count == 0) begin
					$display("[FAIL] unexpected output row idx=%0d", out_idx);
					errors = errors + 1;
				end else begin
					if (out_data !== exp_data_q[exp_head]) begin
						$display("[FAIL] out_data mismatch exp=%0h got=%0h", exp_data_q[exp_head], out_data);
						errors = errors + 1;
					end
					if (out_idx !== exp_idx_q[exp_head]) begin
						$display("[FAIL] out_idx mismatch exp=%0d got=%0d", exp_idx_q[exp_head], out_idx);
						errors = errors + 1;
					end
					if (out_last !== exp_last_q[exp_head]) begin
						$display("[FAIL] out_last mismatch exp=%0d got=%0d", exp_last_q[exp_head], out_last);
						errors = errors + 1;
					end
					exp_head <= (exp_head + 1) % EXPECT_DEPTH;
					exp_count <= exp_count - 1;
				end
			end

			if (cycles > 300) begin
				$display("[FAIL] timeout");
				errors = errors + 1;
				$finish;
			end
		end
	end

	initial begin
		clk = 1'b0;
		rstn = 1'b0;
		clear = 1'b0;
		in_valid = 1'b0;
		lhs_data = {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
		rhs_data = {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
		in_idx = 32'd0;
		in_last = 1'b0;
		out_ready = 1'b1;
		errors = 0;
		cycles = 0;
		exp_head = 0;
		exp_tail = 0;
		exp_count = 0;

		repeat (4) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		set_rows(32'sd1, 32'sd2, 32'sd3, 32'sd4, 32'sd5, 32'sd6, 32'sd7, 32'sd8);
		drive_row(32'd0, 1'b0);

		set_rows(32'sd10, -32'sd20, 32'sd30, -32'sd40, -32'sd3, 32'sd4, -32'sd5, 32'sd6);
		drive_row(32'd1, 1'b0);

		set_rows(32'sd120, 32'sd80, 32'sd50, 32'sd127, 32'sd20, 32'sd70, 32'sd90, 32'sd1);
		drive_row(32'd2, 1'b0);

		set_rows(-32'sd120, -32'sd100, -32'sd70, -32'sd128, -32'sd20, -32'sd60, -32'sd80, -32'sd1);
		drive_row(32'd3, 1'b0);
		wait_for_expected_drain();

		backpressure_check();

		if (errors == 0) begin
			$display("TB RESULT: PASS");
		end else begin
			$display("TB RESULT: FAIL (errors=%0d)", errors);
		end

		#20;
		$finish;
	end

endmodule
