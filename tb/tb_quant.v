`timescale 1ns/1ps
`include "param.vh"

module tb_quant;
	localparam DATA_WIDTH = 8;
	localparam GEMM_X_DIM = 4;
	localparam GEMM_Y_DIM = 4;
	localparam MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam IN_W = 4 * DATA_WIDTH;
	localparam PROD_W = IN_W + 32;
	localparam EXPECT_DEPTH = 32;

	reg clk;
	reg rstn;
	reg clear;

	reg                               in_valid;
	wire                              in_ready;
	reg  [GEMM_Y_DIM*IN_W-1:0]        in_data;
	reg  [31:0]                       in_idx;
	reg                               in_last;
	reg  [2:0]                        quant_mode;
	reg  [MAX_DIM*32-1:0]             quant_inv_scale;
	wire                              out_valid;
	reg                               out_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0]  out_data;
	wire [31:0]                       out_idx;
	wire                              out_last;

	integer errors;
	integer cycles;
	integer li;
	integer exp_head;
	integer exp_tail;
	integer exp_count;
	reg signed [31:0] lane_in [0:GEMM_Y_DIM-1];
	reg signed [31:0] inv_lut [0:MAX_DIM-1];
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_data_q [0:EXPECT_DEPTH-1];
	reg [31:0]                      exp_idx_q [0:EXPECT_DEPTH-1];
	reg                             exp_last_q [0:EXPECT_DEPTH-1];
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] stable_data;
	reg [31:0]                      stable_idx;
	reg                             stable_last;

	always #5 clk = ~clk;

	QUANT #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) dut (
		.clk(clk),
		.rstn(rstn),
		.clear(clear),
		.in_valid(in_valid),
		.in_ready(in_ready),
		.in_data(in_data),
		.in_idx(in_idx),
		.in_last(in_last),
		.quant_mode(quant_mode),
		.quant_inv_scale(quant_inv_scale),
		.out_valid(out_valid),
		.out_ready(out_ready),
		.out_data(out_data),
		.out_idx(out_idx),
		.out_last(out_last)
	);

	function signed [DATA_WIDTH-1:0] quant_ref;
		input signed [IN_W-1:0] x;
		input signed [31:0] inv_scale_q16_16;
		reg signed [PROD_W-1:0] prod;
		reg [PROD_W:0] prod_mag;
		reg [PROD_W:0] prod_mag_round;
		reg [PROD_W:0] q_mag;
		reg signed [PROD_W:0] q_signed;
		reg signed [PROD_W:0] sat_max_ext;
		reg signed [PROD_W:0] sat_min_ext;
		begin
			prod = x * inv_scale_q16_16;
			if (prod[PROD_W-1]) begin
				prod_mag = {1'b0, ~prod} + 1'b1;
			end else begin
				prod_mag = {1'b0, prod};
			end
			prod_mag_round = prod_mag + {{(PROD_W-15){1'b0}}, 16'h8000};
			q_mag = prod_mag_round >> 16;
			if (prod[PROD_W-1]) begin
				q_signed = -$signed(q_mag);
			end else begin
				q_signed = $signed(q_mag);
			end

			sat_max_ext = {{(PROD_W+1-DATA_WIDTH){1'b0}}, {1'b0, {(DATA_WIDTH-1){1'b1}}}};
			sat_min_ext = {{(PROD_W+1-DATA_WIDTH){1'b1}}, {1'b1, {(DATA_WIDTH-1){1'b0}}}};

			if (q_signed > sat_max_ext) begin
				quant_ref = {1'b0, {(DATA_WIDTH-1){1'b1}}};
			end else if (q_signed < sat_min_ext) begin
				quant_ref = {1'b1, {(DATA_WIDTH-1){1'b0}}};
			end else begin
				quant_ref = q_signed[DATA_WIDTH-1:0];
			end
		end
	endfunction

	function signed [31:0] select_inv_scale;
		input [2:0] mode;
		input [31:0] row_idx;
		input integer lane_idx;
		integer sidx;
		begin
			sidx = 0;
			case (mode)
				`PT_QGRAN_X_WISE: sidx = row_idx;
				`PT_QGRAN_Y_WISE: sidx = lane_idx;
				`PT_QGRAN_X_WISE_DIV2: sidx = row_idx >> 1;
				`PT_QGRAN_Y_WISE_DIV2: sidx = lane_idx >> 1;
				default: sidx = 0;
			endcase
			if (sidx < 0) sidx = 0;
			if (sidx >= MAX_DIM) sidx = MAX_DIM - 1;
			select_inv_scale = inv_lut[sidx];
		end
	endfunction

	task automatic set_inv_scales;
		input [31:0] s0;
		input [31:0] s1;
		input [31:0] s2;
		input [31:0] s3;
		begin
			inv_lut[0] = s0;
			inv_lut[1] = s1;
			inv_lut[2] = s2;
			inv_lut[3] = s3;
			quant_inv_scale = {s3, s2, s1, s0};
		end
	endtask

	task automatic set_row_inputs;
		input signed [31:0] d0;
		input signed [31:0] d1;
		input signed [31:0] d2;
		input signed [31:0] d3;
		begin
			lane_in[0] = d0;
			lane_in[1] = d1;
			lane_in[2] = d2;
			lane_in[3] = d3;
			in_data = {d3[IN_W-1:0], d2[IN_W-1:0], d1[IN_W-1:0], d0[IN_W-1:0]};
		end
	endtask

	task automatic push_expected;
		input [2:0] mode;
		input [31:0] row_idx;
		input row_last;
		integer lane_idx;
		reg signed [DATA_WIDTH-1:0] exp_lane;
		reg [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_row;
		begin
			if (exp_count >= EXPECT_DEPTH) begin
				$display("[FAIL] expectation queue overflow");
				errors = errors + 1;
			end else begin
				exp_row = {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
				for (lane_idx = 0; lane_idx < GEMM_Y_DIM; lane_idx = lane_idx + 1) begin
					exp_lane = quant_ref(lane_in[lane_idx][IN_W-1:0], select_inv_scale(mode, row_idx, lane_idx));
					exp_row[lane_idx*DATA_WIDTH +: DATA_WIDTH] = exp_lane;
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
		input [2:0] mode;
		input [31:0] row_idx;
		input row_last;
		reg handshake_seen;
		begin
			@(negedge clk);
			push_expected(mode, row_idx, row_last);
			quant_mode = mode;
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
			set_inv_scales(32'h0001_0000, 32'h0001_0000, 32'h0001_0000, 32'h0001_0000);
			set_row_inputs(32'sd12, -32'sd9, 32'sd3, -32'sd2);
			drive_row(`PT_QGRAN_PER_TENSOR, 32'd2, 1'b0);
			set_row_inputs(-32'sd7, 32'sd6, -32'sd5, 32'sd4);
			drive_row(`PT_QGRAN_PER_TENSOR, 32'd3, 1'b1);
			@(negedge clk);
			#1;
			if (!out_valid) begin
				$display("[FAIL] expected held output under backpressure");
				errors = errors + 1;
			end
			if (in_ready) begin
				$display("[FAIL] expected input stall when both pipeline stages are full");
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
			if (cycles > 400) begin
				$display("[FAIL] timeout waiting for QUANT traffic to drain");
				errors <= errors + 1;
				$finish;
			end

			if (out_valid && out_ready) begin
				if (exp_count == 0) begin
					$display("[FAIL] unexpected QUANT output idx=%0d last=%0d data=%h", out_idx, out_last, out_data);
					errors <= errors + 1;
				end else begin
					if (out_data !== exp_data_q[exp_head]) begin
						$display("[FAIL] output data mismatch exp=%h got=%h", exp_data_q[exp_head], out_data);
						errors <= errors + 1;
					end
					if (out_idx !== exp_idx_q[exp_head] || out_last !== exp_last_q[exp_head]) begin
						$display("[FAIL] output metadata mismatch exp_idx=%0d got_idx=%0d exp_last=%0d got_last=%0d",
						         exp_idx_q[exp_head], out_idx, exp_last_q[exp_head], out_last);
						errors <= errors + 1;
					end
					exp_head <= (exp_head + 1) % EXPECT_DEPTH;
					exp_count <= exp_count - 1;
				end
			end
		end
	end

	initial begin
		clk = 1'b0;
		rstn = 1'b0;
		clear = 1'b0;
		in_valid = 1'b0;
		in_data = {GEMM_Y_DIM*IN_W{1'b0}};
		in_idx = 32'd0;
		in_last = 1'b0;
		quant_mode = `PT_QGRAN_PER_TENSOR;
		quant_inv_scale = {MAX_DIM{32'h0001_0000}};
		out_ready = 1'b1;
		errors = 0;
		cycles = 0;
		exp_head = 0;
		exp_tail = 0;
		exp_count = 0;
		stable_data = {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
		stable_idx = 32'd0;
		stable_last = 1'b0;

		repeat (2) begin
			@(posedge clk);
		end
		rstn = 1'b1;
		@(posedge clk);

		// Continuous input with no backpressure.
		set_inv_scales(32'h0001_0000, 32'h0001_0000, 32'h0001_0000, 32'h0001_0000);
		set_row_inputs(32'sd10, -32'sd11, 32'sd130, -32'sd200);
		drive_row(`PT_QGRAN_PER_TENSOR, 32'd0, 1'b0);

		set_inv_scales(32'h0001_0000, 32'h0000_8000, 32'h0002_0000, 32'h0001_8000);
		set_row_inputs(32'sd4, 32'sd3, -32'sd4, -32'sd3);
		drive_row(`PT_QGRAN_Y_WISE, 32'd3, 1'b0);

		set_inv_scales(32'h0001_0000, 32'h0000_8000, 32'h0002_0000, 32'h0000_4000);
		set_row_inputs(32'sd2, -32'sd2, 32'sd40, -32'sd40);
		drive_row(`PT_QGRAN_X_WISE, 32'd2, 1'b0);

		set_inv_scales(32'h0001_0000, 32'h0000_8000, 32'h0002_0000, 32'h0000_4000);
		set_row_inputs(32'sd8, -32'sd8, 32'sd6, -32'sd6);
		drive_row(`PT_QGRAN_X_WISE_DIV2, 32'd3, 1'b0);

		set_inv_scales(32'h0001_0000, 32'h0002_0000, 32'h0000_8000, 32'h0001_0000);
		set_row_inputs(32'sd3, 32'sd5, -32'sd3, -32'sd5);
		drive_row(`PT_QGRAN_Y_WISE_DIV2, 32'd1, 1'b1);

		set_inv_scales(32'h0000_8000, 32'h0000_8000, 32'h0000_8000, 32'h0000_8000);
		set_row_inputs(32'sd1, -32'sd1, 32'sd5, -32'sd5);
		drive_row(`PT_QGRAN_PER_TENSOR, 32'd0, 1'b0);

		wait_for_expected_drain();

		// Intermittent input plus output-ready jitter.
		set_inv_scales(32'h0001_0000, 32'h0001_0000, 32'h0001_0000, 32'h0001_0000);
		set_row_inputs(32'sd9, -32'sd7, 32'sd5, -32'sd3);
		drive_row(`PT_QGRAN_PER_TENSOR, 32'd4, 1'b0);
		repeat (2) begin
			@(posedge clk);
		end
		@(negedge clk);
		out_ready = 1'b0;
		repeat (1) begin
			@(posedge clk);
		end
		@(negedge clk);
		out_ready = 1'b1;
		set_inv_scales(32'h0001_0000, 32'h0002_0000, 32'h0001_0000, 32'h0002_0000);
		set_row_inputs(-32'sd8, 32'sd6, -32'sd4, 32'sd2);
		drive_row(`PT_QGRAN_Y_WISE, 32'd5, 1'b1);
		repeat (1) begin
			@(posedge clk);
		end
		@(negedge clk);
		out_ready = 1'b0;
		repeat (2) begin
			@(posedge clk);
		end
		@(negedge clk);
		out_ready = 1'b1;
		wait_for_expected_drain();

		backpressure_check();

		if (errors == 0) begin
			$display("TB RESULT (QUANT): PASS");
		end else begin
			$display("TB RESULT (QUANT): FAIL (errors=%0d)", errors);
		end

		#20;
		$finish;
	end

endmodule
