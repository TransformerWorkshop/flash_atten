`timescale 1ns/1ps
`include "param.vh"

module tb_pt_numeric;
	localparam DATA_WIDTH = 32;
	localparam X_DIM = 8;
	localparam Y_DIM = 8;
	localparam ELEMENTS = X_DIM * Y_DIM;
	localparam [31:0] A_BASE = 32'h0000_1000;
	localparam [31:0] B_BASE = 32'h0000_2000;
	localparam [1:0] MATRIX_A = 2'b01;
	localparam [1:0] MATRIX_B = 2'b10;
	localparam integer EXP_MISS = 0;
	localparam integer EXP_HIT = 1;
	localparam integer EXP_MWIN = 2;

	reg clk;
	reg rstn;
	reg clear;

	reg                    s_axis_tvalid;
	wire                   s_axis_tready;
	reg  [DATA_WIDTH-1:0]  s_axis_tdata;
	reg  [DATA_WIDTH/8-1:0] s_axis_tstrb;
	reg                    s_axis_tlast;
	reg                    s_axis_tkeep;
	reg                    s_axis_tid;
	reg                    s_axis_tdest;
	reg  [1:0]             s_axis_tuser;

	wire                   m_axis_tvalid;
	reg                    m_axis_tready;
	wire [DATA_WIDTH-1:0]  m_axis_tdata;
	wire [DATA_WIDTH/8-1:0] m_axis_tstrb;
	wire                   m_axis_tlast;
	wire                   m_axis_tkeep;
	wire                   m_axis_tid;
	wire                   m_axis_tdest;
	wire [1:0]             m_axis_tuser;

	reg                    ctrl_valid;
	wire                   ctrl_ready;
	reg  [`INST_WIDTH-1:0] ctrl_inst;
	reg  [31:0]            ctrl_id;
	wire [31:0]            ctrl_resp;
	wire                   ctrl_resp_valid;

	wire                   dma_req_valid;
	reg                    dma_req_ready;
	wire [1:0]             dma_req_tuser;
	wire [31:0]            dma_req_id;
	wire [31:0]            dma_req_ext_addr;
	wire [9:0]             dma_req_local_addr;
	wire [15:0]            dma_req_beats;
	reg                    dma_done;
	reg                    dma_error;

	wire                   m_dma_req_valid;
	reg                    m_dma_req_ready;
	wire [31:0]            m_dma_req_id;
	wire                   m_dma_req_buf;
	wire [15:0]            m_dma_req_beats;
	reg                    m_dma_done;
	reg                    m_dma_error;

	wire                   irq;

	reg [DATA_WIDTH-1:0] a_matrix [0:ELEMENTS-1];
	reg [DATA_WIDTH-1:0] b_matrix [0:ELEMENTS-1];
	reg [DATA_WIDTH-1:0] m1_matrix [0:ELEMENTS-1];
	reg [DATA_WIDTH-1:0] m2_matrix [0:ELEMENTS-1];

	integer errors;
	integer cycles;
	integer dma_req_count;
	integer m_export_req_count;
	integer m_export_done_count;
	integer irq_count;
	integer dma_req_before;
	integer export_before;
	integer irq_before;

	reg        dma_stream_active;
	reg [1:0]  dma_stream_tuser;
	reg        dma_stream_is_b;
	reg [15:0] dma_stream_remaining;
	integer    dma_stream_idx;

	reg        m_export_active;
	reg        m_export_buf;
	reg [31:0] m_export_id;
	integer    m_export_remaining;
	integer    m_export_idx;
	integer    pending_export_case;
	integer    active_export_case;

	PT #(
		.DATA_WIDTH  (DATA_WIDTH),
		.GEMM_X_DIM  (X_DIM),
		.GEMM_Y_DIM  (Y_DIM),
		.EXT_ADDR_W  (32),
		.DMA_BEATS_W (16),
		.LUT_DEPTH   (8),
		.A_BANK_DEPTH(8),
		.B_BANK_DEPTH(8)
	) dut (
		.clk(clk),
		.rstn(rstn),
		.clear(clear),
		.s_axis_tvalid(s_axis_tvalid),
		.s_axis_tready(s_axis_tready),
		.s_axis_tdata(s_axis_tdata),
		.s_axis_tstrb(s_axis_tstrb),
		.s_axis_tlast(s_axis_tlast),
		.s_axis_tkeep(s_axis_tkeep),
		.s_axis_tid(s_axis_tid),
		.s_axis_tdest(s_axis_tdest),
		.s_axis_tuser(s_axis_tuser),
		.m_axis_tvalid(m_axis_tvalid),
		.m_axis_tready(m_axis_tready),
		.m_axis_tdata(m_axis_tdata),
		.m_axis_tstrb(m_axis_tstrb),
		.m_axis_tlast(m_axis_tlast),
		.m_axis_tkeep(m_axis_tkeep),
		.m_axis_tid(m_axis_tid),
		.m_axis_tdest(m_axis_tdest),
		.m_axis_tuser(m_axis_tuser),
		.ctrl_valid(ctrl_valid),
		.ctrl_ready(ctrl_ready),
		.ctrl_inst(ctrl_inst),
		.ctrl_id(ctrl_id),
		.ctrl_resp(ctrl_resp),
		.ctrl_resp_valid(ctrl_resp_valid),
		.dma_req_valid(dma_req_valid),
		.dma_req_ready(dma_req_ready),
		.dma_req_tuser(dma_req_tuser),
		.dma_req_id(dma_req_id),
		.dma_req_ext_addr(dma_req_ext_addr),
		.dma_req_local_addr(dma_req_local_addr),
		.dma_req_beats(dma_req_beats),
		.dma_done(dma_done),
		.dma_error(dma_error),
		.m_dma_req_valid(m_dma_req_valid),
		.m_dma_req_ready(m_dma_req_ready),
		.m_dma_req_id(m_dma_req_id),
		.m_dma_req_buf(m_dma_req_buf),
		.m_dma_req_beats(m_dma_req_beats),
		.m_dma_done(m_dma_done),
		.m_dma_error(m_dma_error),
		.irq(irq)
	);

	always #5 clk = ~clk;

	function [`INST_WIDTH-1:0] build_matmul_inst;
		input [3:0] op;
		input [1:0] m;
		input [1:0] n;
		input [1:0] k;
		input [9:0] a_off;
		input [9:0] b_off;
		begin
			build_matmul_inst = {op, m, n, k, a_off, b_off, 2'b00};
		end
	endfunction

	function [9:0] build_mwin_off;
		input buf_sel;
		input [7:0] elem_off;
		begin
			build_mwin_off = {1'b1, buf_sel, elem_off};
		end
	endfunction

	function [`INST_WIDTH-1:0] build_qcfg_header;
		input [2:0] gran;
		begin
			build_qcfg_header = {`PT_OP_QCFG, `PT_QCFG_CMD_HDR, `PT_QTYPE_SYMMETRIC, gran, 19'd0};
		end
	endfunction

	function [31:0] pack_resp;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp = {err, m_buf, id[29:0]};
		end
	endfunction

	function [DATA_WIDTH-1:0] dma_word;
		input is_b;
		input integer idx;
		begin
			if (is_b) begin
				dma_word = b_matrix[idx];
			end else begin
				dma_word = a_matrix[idx];
			end
		end
	endfunction

	function [DATA_WIDTH-1:0] expected_export_word;
		input integer exp_case;
		input integer idx;
		begin
			case (exp_case)
				EXP_HIT: expected_export_word = m1_matrix[idx];
				EXP_MWIN: expected_export_word = m2_matrix[idx];
				default: expected_export_word = m1_matrix[idx];
			endcase
		end
	endfunction

	task automatic init_matrices;
		integer row_idx;
		integer col_idx;
		integer acc_idx;
		integer sum;
		begin
			for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
				for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
					a_matrix[row_idx*Y_DIM + col_idx] =
						((row_idx + 1) * 2 + col_idx + 1);
					b_matrix[row_idx*Y_DIM + col_idx] =
						(((row_idx * 3) + col_idx) % 7) + 1;
				end
			end

			for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
				for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
					sum = 0;
					for (acc_idx = 0; acc_idx < Y_DIM; acc_idx = acc_idx + 1) begin
						sum = sum +
						      (a_matrix[row_idx*Y_DIM + acc_idx] *
						       b_matrix[acc_idx*Y_DIM + col_idx]);
					end
					m1_matrix[row_idx*Y_DIM + col_idx] = sum[DATA_WIDTH-1:0];
				end
			end

			for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
				for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
					sum = 0;
					for (acc_idx = 0; acc_idx < Y_DIM; acc_idx = acc_idx + 1) begin
						sum = sum +
						      (m1_matrix[row_idx*Y_DIM + acc_idx] *
						       m1_matrix[acc_idx*Y_DIM + col_idx]);
					end
					m2_matrix[row_idx*Y_DIM + col_idx] = sum[DATA_WIDTH-1:0];
				end
			end
		end
	endtask

	task automatic send_ctrl_inst;
		input [`INST_WIDTH-1:0] inst;
		input [31:0] id;
		begin
			ctrl_inst  = inst;
			ctrl_id    = id;
			ctrl_valid = 1'b1;
			while (!ctrl_ready) begin
				@(posedge clk);
			end
			@(posedge clk);
			ctrl_valid = 1'b0;
		end
	endtask

	task automatic wait_ctrl_resp;
		input [31:0] exp;
		input integer timeout;
		reg got;
		begin
			cycles = 0;
			got = 1'b0;
			while ((cycles < timeout) && !got) begin
				@(posedge clk);
				if (ctrl_resp_valid) begin
					got = 1'b1;
					if (ctrl_resp !== exp) begin
						$display("[FAIL] ctrl_resp mismatch exp=%h got=%h", exp, ctrl_resp);
						errors = errors + 1;
					end
				end
				cycles = cycles + 1;
			end
			if (!got) begin
				$display("[FAIL] ctrl_resp timeout exp=%h last=%h", exp, ctrl_resp);
				errors = errors + 1;
			end
		end
	endtask

	task automatic expect_no_ctrl_resp;
		input integer wait_cycles;
		integer wi;
		begin
			for (wi = 0; wi < wait_cycles; wi = wi + 1) begin
				@(posedge clk);
				if (ctrl_resp_valid) begin
					$display("[FAIL] unexpected ctrl_resp during no-response window got=%h", ctrl_resp);
					errors = errors + 1;
				end
			end
		end
	endtask

	task automatic wait_export_done;
		input integer exp_done_count;
		input integer timeout;
		begin
			cycles = 0;
			while ((cycles < timeout) && (m_export_done_count < exp_done_count)) begin
				@(posedge clk);
				cycles = cycles + 1;
			end
			if (m_export_done_count < exp_done_count) begin
				$display("[FAIL] export completion timeout exp=%0d got=%0d",
					exp_done_count, m_export_done_count);
				errors = errors + 1;
			end
		end
	endtask

	always @(posedge clk) begin
		dma_done <= 1'b0;
		dma_error <= 1'b0;
		m_dma_done <= 1'b0;
		m_dma_error <= 1'b0;
		s_axis_tlast <= 1'b0;

		if (!rstn || clear) begin
			dma_stream_active <= 1'b0;
			dma_stream_tuser <= 2'b00;
			dma_stream_is_b <= 1'b0;
			dma_stream_remaining <= 16'd0;
			dma_stream_idx <= 0;
			s_axis_tvalid <= 1'b0;
			s_axis_tuser <= 2'b00;
			s_axis_tdata <= {DATA_WIDTH{1'b0}};
			m_export_active <= 1'b0;
			m_export_buf <= 1'b0;
			m_export_id <= 32'd0;
			m_export_remaining <= 0;
			m_export_idx <= 0;
			active_export_case <= EXP_MISS;
		end else begin
			if (dma_req_valid && dma_req_ready && !dma_stream_active) begin
				dma_req_count <= dma_req_count + 1;
				if (dma_req_beats !== ELEMENTS[15:0]) begin
					$display("[FAIL] dma_req_beats mismatch exp=%0d got=%0d", ELEMENTS, dma_req_beats);
					errors = errors + 1;
				end
				if (dma_req_tuser == MATRIX_A) begin
					if (dma_req_ext_addr !== A_BASE) begin
						$display("[FAIL] A dma ext addr mismatch exp=%h got=%h", A_BASE, dma_req_ext_addr);
						errors = errors + 1;
					end
					dma_stream_is_b <= 1'b0;
				end else if (dma_req_tuser == MATRIX_B) begin
					if (dma_req_ext_addr !== B_BASE) begin
						$display("[FAIL] B dma ext addr mismatch exp=%h got=%h", B_BASE, dma_req_ext_addr);
						errors = errors + 1;
					end
					dma_stream_is_b <= 1'b1;
				end else begin
					$display("[FAIL] unexpected dma_req_tuser=%b", dma_req_tuser);
					errors = errors + 1;
					dma_stream_is_b <= 1'b0;
				end

				dma_stream_active <= 1'b1;
				dma_stream_tuser <= dma_req_tuser;
				dma_stream_remaining <= ELEMENTS[15:0];
				dma_stream_idx <= 0;
				s_axis_tvalid <= 1'b1;
				s_axis_tuser <= dma_req_tuser;
				s_axis_tdata <= (dma_req_tuser == MATRIX_B) ? b_matrix[0] : a_matrix[0];
			end else if (dma_stream_active) begin
				s_axis_tvalid <= 1'b1;
				s_axis_tuser <= dma_stream_tuser;
				if (s_axis_tready) begin
					if (dma_stream_remaining == 16'd1) begin
						dma_stream_active <= 1'b0;
						dma_stream_remaining <= 16'd0;
						dma_stream_idx <= 0;
						s_axis_tvalid <= 1'b0;
						dma_done <= 1'b1;
						s_axis_tlast <= 1'b1;
					end else begin
						dma_stream_remaining <= dma_stream_remaining - 1'b1;
						dma_stream_idx <= dma_stream_idx + 1;
						s_axis_tdata <= dma_word(dma_stream_is_b, dma_stream_idx + 1);
					end
				end
			end else begin
				s_axis_tvalid <= 1'b0;
				s_axis_tuser <= 2'b00;
			end

			if (m_dma_req_valid && m_dma_req_ready && !m_export_active) begin
				m_export_active <= 1'b1;
				m_export_buf <= m_dma_req_buf;
				m_export_id <= m_dma_req_id;
				m_export_remaining <= ELEMENTS;
				m_export_idx <= 0;
				active_export_case <= pending_export_case;
				m_export_req_count <= m_export_req_count + 1;
				if (m_dma_req_beats !== ELEMENTS[15:0]) begin
					$display("[FAIL] m_dma_req_beats mismatch exp=%0d got=%0d", ELEMENTS, m_dma_req_beats);
					errors = errors + 1;
				end
			end

			if (m_export_active && m_axis_tvalid && m_axis_tready) begin
				if (m_axis_tdata !== expected_export_word(active_export_case, m_export_idx)) begin
					$display("[FAIL] export data mismatch case=%0d idx=%0d exp=%h got=%h",
						active_export_case, m_export_idx,
						expected_export_word(active_export_case, m_export_idx), m_axis_tdata);
					errors = errors + 1;
				end
				if (m_axis_tuser[0] !== m_export_buf) begin
					$display("[FAIL] m_axis_tuser buf mismatch exp=%0d got=%0d",
						m_export_buf, m_axis_tuser[0]);
					errors = errors + 1;
				end
				if (m_export_remaining == 1) begin
					if (!m_axis_tlast) begin
						$display("[FAIL] expected m_axis_tlast on final beat (id=%h)", m_export_id);
						errors = errors + 1;
					end
					m_export_active <= 1'b0;
					m_export_remaining <= 0;
					m_export_idx <= 0;
					m_dma_done <= 1'b1;
					m_export_done_count <= m_export_done_count + 1;
				end else begin
					if (m_axis_tlast) begin
						$display("[FAIL] early m_axis_tlast on beat %0d", m_export_idx);
						errors = errors + 1;
					end
					m_export_remaining <= m_export_remaining - 1;
					m_export_idx <= m_export_idx + 1;
				end
			end
		end
	end

	always @(posedge clk) begin
		if (!rstn || clear) begin
			irq_count <= 0;
		end else if (irq) begin
			irq_count <= irq_count + 1;
		end
	end

	initial begin
		clk = 1'b0;
		rstn = 1'b0;
		clear = 1'b0;
		s_axis_tvalid = 1'b0;
		s_axis_tdata = {DATA_WIDTH{1'b0}};
		s_axis_tstrb = {DATA_WIDTH/8{1'b1}};
		s_axis_tlast = 1'b0;
		s_axis_tkeep = 1'b1;
		s_axis_tid = 1'b0;
		s_axis_tdest = 1'b0;
		s_axis_tuser = 2'b00;
		m_axis_tready = 1'b1;
		ctrl_valid = 1'b0;
		ctrl_inst = {`INST_WIDTH{1'b0}};
		ctrl_id = 32'd0;
		dma_req_ready = 1'b1;
		dma_done = 1'b0;
		dma_error = 1'b0;
		m_dma_req_ready = 1'b1;
		m_dma_done = 1'b0;
		m_dma_error = 1'b0;
		errors = 0;
		cycles = 0;
		dma_req_count = 0;
		m_export_req_count = 0;
		m_export_done_count = 0;
		irq_count = 0;
		dma_stream_active = 1'b0;
		dma_stream_tuser = 2'b00;
		dma_stream_is_b = 1'b0;
		dma_stream_remaining = 16'd0;
		dma_stream_idx = 0;
		m_export_active = 1'b0;
		m_export_buf = 1'b0;
		m_export_id = 32'd0;
		m_export_remaining = 0;
		m_export_idx = 0;
		pending_export_case = EXP_MISS;
		active_export_case = EXP_MISS;

		init_matrices();

		repeat (5) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		send_ctrl_inst({`PT_OP_CFG, `PT_CFG_A_BASE_LO, 8'h00, A_BASE[15:0]}, 32'h10);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h10), 200);
		send_ctrl_inst({`PT_OP_CFG, `PT_CFG_B_BASE_LO, 8'h00, B_BASE[15:0]}, 32'h11);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h11), 200);

		send_ctrl_inst(build_qcfg_header(`PT_QGRAN_PER_TENSOR), 32'h20);
		expect_no_ctrl_resp(4);
		send_ctrl_inst(32'h0001_0000, 32'h20);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h20), 200);

		// 1) row-major miss path
		dma_req_before = dma_req_count;
		export_before = m_export_req_count;
		irq_before = irq_count;
		pending_export_case = EXP_MISS;
		send_ctrl_inst(
			build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL,
			                 10'h000, 10'h000),
			32'h1
		);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h1), 4000);
		wait_export_done(export_before + 1, 4000);
		repeat (10) @(posedge clk);
		if (dma_req_count != (dma_req_before + 2)) begin
			$display("[FAIL] miss path should issue two DMA requests, before=%0d after=%0d",
				dma_req_before, dma_req_count);
			errors = errors + 1;
		end
		if (m_export_req_count != (export_before + 1)) begin
			$display("[FAIL] miss path should issue one export request");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] miss path should raise one completion irq");
			errors = errors + 1;
		end

		// 2) cache hit path, same row-major payload contract, no new DMA
		dma_req_before = dma_req_count;
		export_before = m_export_req_count;
		irq_before = irq_count;
		pending_export_case = EXP_HIT;
		send_ctrl_inst(
			build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL,
			                 10'h000, 10'h000),
			32'h1
		);
		wait_ctrl_resp(pack_resp(1'b0, 1'b1, 32'h1), 4000);
		wait_export_done(export_before + 1, 4000);
		repeat (10) @(posedge clk);
		if (dma_req_count != dma_req_before) begin
			$display("[FAIL] hit path should not issue DMA, before=%0d after=%0d",
				dma_req_before, dma_req_count);
			errors = errors + 1;
		end
		if (m_export_req_count != (export_before + 1)) begin
			$display("[FAIL] hit path should issue one export request");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] hit path should raise one completion irq");
			errors = errors + 1;
		end

		// 3) M-window reuse path from buffer=1, no DMA, export M1*M1
		dma_req_before = dma_req_count;
		export_before = m_export_req_count;
		irq_before = irq_count;
		pending_export_case = EXP_MWIN;
		send_ctrl_inst(
			build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL,
			                 build_mwin_off(1'b1, 8'h00), build_mwin_off(1'b1, 8'h00)),
			32'h3
		);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h3), 4000);
		wait_export_done(export_before + 1, 4000);
		repeat (10) @(posedge clk);
		if (dma_req_count != dma_req_before) begin
			$display("[FAIL] M-window path should not issue DMA, before=%0d after=%0d",
				dma_req_before, dma_req_count);
			errors = errors + 1;
		end
		if (m_export_req_count != (export_before + 1)) begin
			$display("[FAIL] M-window path should issue one export request");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] M-window path should raise one completion irq");
			errors = errors + 1;
		end

		if (errors == 0) begin
			$display("TB RESULT (PT_NUMERIC): PASS");
		end else begin
			$display("TB RESULT (PT_NUMERIC): FAIL (errors=%0d)", errors);
		end

		#20;
		$finish;
	end

endmodule
