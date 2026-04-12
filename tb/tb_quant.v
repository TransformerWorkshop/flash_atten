`timescale 1ns/1ps
`include "param.vh"

module tb_quant;
	localparam DATA_WIDTH = 8;
	localparam GEMM_X_DIM = 4;
	localparam GEMM_Y_DIM = 4;
	localparam MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam IN_W = 4 * DATA_WIDTH;
	localparam PROD_W = IN_W + 32;

	reg in_valid;
	wire in_ready;
	reg [GEMM_Y_DIM*IN_W-1:0] in_data;
	reg [31:0] in_idx;
	reg in_last;
	reg [2:0] quant_mode;
	reg [MAX_DIM*32-1:0] quant_inv_scale;
	wire out_valid;
	reg out_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] out_data;
	wire [31:0] out_idx;
	wire out_last;

	integer errors;
	integer li;
	reg signed [31:0] lane_in [0:GEMM_Y_DIM-1];
	reg signed [31:0] inv_lut [0:MAX_DIM-1];
	reg signed [DATA_WIDTH-1:0] act_lane;
	reg signed [DATA_WIDTH-1:0] exp_lane;
	reg [31:0] stable_data;
	reg [31:0] stable_idx;
	reg stable_last;

	QUANT #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) dut (
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

	task automatic fire_and_check;
		input [2:0] mode;
		input [31:0] row_idx;
		input row_last;
		begin
			quant_mode = mode;
			in_idx = row_idx;
			in_last = row_last;
			in_valid = 1'b1;
			out_ready = 1'b1;
			#1;
			if (!(out_valid && in_ready)) begin
				$display("[FAIL] expected immediate handshake");
				errors = errors + 1;
			end
			if (out_idx !== row_idx || out_last !== row_last) begin
				$display("[FAIL] metadata mismatch exp_idx=%0d got_idx=%0d exp_last=%0d got_last=%0d", row_idx, out_idx, row_last, out_last);
				errors = errors + 1;
			end
			for (li = 0; li < GEMM_Y_DIM; li = li + 1) begin
				act_lane = $signed(out_data[li*DATA_WIDTH +: DATA_WIDTH]);
				exp_lane = quant_ref(lane_in[li][IN_W-1:0], select_inv_scale(mode, row_idx, li));
				if (act_lane !== exp_lane) begin
					$display("[FAIL] lane=%0d exp=%0d got=%0d mode=%0d idx=%0d", li, exp_lane, act_lane, mode, row_idx);
					errors = errors + 1;
				end
			end
			in_valid = 1'b0;
		end
	endtask

	task automatic backpressure_check;
		begin
			quant_mode = `PT_QGRAN_PER_TENSOR;
			set_inv_scales(32'h0001_0000, 32'h0001_0000, 32'h0001_0000, 32'h0001_0000);
			set_row_inputs(32'sd12, -32'sd9, 32'sd3, -32'sd2);
			in_idx = 32'd2;
			in_last = 1'b1;
			out_ready = 1'b0;
			in_valid = 1'b1;
			#1;
			if (!out_valid || in_ready) begin
				$display("[FAIL] backpressure handshake flags mismatch");
				errors = errors + 1;
			end
			stable_data = out_data;
			stable_idx = out_idx;
			stable_last = out_last;
			repeat (3) begin
				#1;
				if (!out_valid || out_data !== stable_data || out_idx !== stable_idx || out_last !== stable_last) begin
					$display("[FAIL] output changed under backpressure");
					errors = errors + 1;
				end
			end
			out_ready = 1'b1;
			#1;
			if (!in_ready) begin
				$display("[FAIL] in_ready not released after backpressure");
				errors = errors + 1;
			end
			in_valid = 1'b0;
		end
	endtask

	initial begin
		errors = 0;
		in_valid = 1'b0;
		in_data = {GEMM_Y_DIM*IN_W{1'b0}};
		in_idx = 32'd0;
		in_last = 1'b0;
		quant_mode = `PT_QGRAN_PER_TENSOR;
		quant_inv_scale = {MAX_DIM{32'h0001_0000}};
		out_ready = 1'b1;

		// per-tensor + saturation
		set_inv_scales(32'h0001_0000, 32'h0001_0000, 32'h0001_0000, 32'h0001_0000);
		set_row_inputs(32'sd10, -32'sd11, 32'sd130, -32'sd200);
		fire_and_check(`PT_QGRAN_PER_TENSOR, 32'd0, 1'b0);

		// y-wise mapping + rounding check
		set_inv_scales(32'h0001_0000, 32'h0000_8000, 32'h0002_0000, 32'h0001_8000);
		set_row_inputs(32'sd4, 32'sd3, -32'sd4, -32'sd3);
		fire_and_check(`PT_QGRAN_Y_WISE, 32'd3, 1'b0);

		// x-wise mapping
		set_inv_scales(32'h0001_0000, 32'h0000_8000, 32'h0002_0000, 32'h0000_4000);
		set_row_inputs(32'sd2, -32'sd2, 32'sd40, -32'sd40);
		fire_and_check(`PT_QGRAN_X_WISE, 32'd2, 1'b0);

		// x-wise/2 mapping
		set_inv_scales(32'h0001_0000, 32'h0000_8000, 32'h0002_0000, 32'h0000_4000);
		set_row_inputs(32'sd8, -32'sd8, 32'sd6, -32'sd6);
		fire_and_check(`PT_QGRAN_X_WISE_DIV2, 32'd3, 1'b0);

		// y-wise/2 mapping
		set_inv_scales(32'h0001_0000, 32'h0002_0000, 32'h0000_8000, 32'h0001_0000);
		set_row_inputs(32'sd3, 32'sd5, -32'sd3, -32'sd5);
		fire_and_check(`PT_QGRAN_Y_WISE_DIV2, 32'd1, 1'b1);

		// explicit tie-away-from-zero check
		set_inv_scales(32'h0000_8000, 32'h0000_8000, 32'h0000_8000, 32'h0000_8000);
		set_row_inputs(32'sd1, -32'sd1, 32'sd5, -32'sd5);
		fire_and_check(`PT_QGRAN_PER_TENSOR, 32'd0, 1'b0);

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
