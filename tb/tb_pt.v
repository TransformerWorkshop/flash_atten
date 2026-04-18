`timescale 1ns/1ps
`include "param.vh"

module tb_pt;
	localparam DATA_WIDTH = 32;
	localparam X_DIM      = 2 ;
	localparam Y_DIM      = 2 ;
	localparam EXPORT_BEATS = X_DIM * Y_DIM;

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
	wire [`PT_DMA_KIND_W-1:0] dma_req_kind;
	wire [1:0]             dma_req_tuser;
	wire [31:0]            dma_req_id;
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

	PT #(
		.DATA_WIDTH  (DATA_WIDTH),
		.GEMM_X_DIM  (X_DIM),
		.GEMM_Y_DIM  (Y_DIM),
		.EXT_ADDR_W  (32),
		.DMA_BEATS_W (16),
		.LUT_DEPTH   (8),
		.A_BANK_DEPTH(8),
		.B_BANK_DEPTH(8),
		.M_BANK_DEPTH(8),
		.A_LOAD_LANES(1),
		.B_LOAD_LANES(1),
		.M_WRITE_LANES(1),
		.M_EXPORT_LANES(1)
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
		.dma_req_kind(dma_req_kind),
		.dma_req_id(dma_req_id),
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

	assign dma_req_tuser = (dma_req_kind == `PT_DMA_KIND_A) ? `PT_STREAM_KIND_A :
	                       (dma_req_kind == `PT_DMA_KIND_B) ? `PT_STREAM_KIND_B :
	                       (dma_req_kind == `PT_DMA_KIND_C) ? `PT_STREAM_KIND_C :
	                       2'b00;
	assign dma_req_beats = (dma_req_kind == `PT_DMA_KIND_A) ? (X_DIM * X_DIM) :
	                       (dma_req_kind == `PT_DMA_KIND_B) ? (Y_DIM * Y_DIM) :
	                       (dma_req_kind == `PT_DMA_KIND_C) ? (Y_DIM * Y_DIM) :
	                       16'd0;

	always #5 clk = ~clk;

	integer errors;
	integer cycles;
	integer dma_req_count;
	integer gemm_start_count;
	integer irq_count;
	integer irq_before;
	integer dma_req_before;
	integer gemm_before;
	integer m_export_req_before;
	integer m_export_req_count;
	integer m_export_done_count;
	integer m_export_error_count;
	integer m_axis_beat_count;
	integer m_axis_last_count;

	reg        dma_stream_active;
	reg [1:0]  dma_stream_tuser;
	reg [15:0] dma_stream_remaining;
	reg [DATA_WIDTH-1:0] data_seed;
	reg        inject_dma_error_once;
	reg        dma_error_pending;
	reg        force_bad_tuser_once;

	reg        m_export_active;
	reg [15:0] m_export_remaining;
	reg        m_export_buf;
	reg [31:0] m_export_id;
	reg        inject_m_dma_error_once;

	function [`INST_WIDTH-1:0] build_matmul_inst;
		input [3:0] op;
		input [3:0] m_tiles;
		input [3:0] n_tiles;
		input [3:0] k_tiles;
		input [7:0] reserved_a;
		input [7:0] reserved_b;
		begin
			build_matmul_inst = {op, m_tiles, n_tiles, k_tiles, reserved_a, reserved_b};
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

	function [`INST_WIDTH-1:0] build_load_inst;
		input need_a;
		input need_b;
		input [9:0] a_off;
		input [9:0] b_off;
		begin
			build_load_inst = {`PT_OP_LOAD, need_a, need_b, 4'b0000, a_off, b_off, 2'b00};
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

	always @(posedge clk) begin
		dma_done <= 1'b0;
		dma_error <= 1'b0;
		m_dma_done <= 1'b0;
		m_dma_error <= 1'b0;
		s_axis_tlast <= 1'b0;

		if (!rstn || clear) begin
			dma_stream_active    <= 1'b0;
			dma_stream_tuser     <= 2'b00;
			dma_stream_remaining <= 16'd0;
			s_axis_tvalid        <= 1'b0;
			s_axis_tuser         <= 2'b00;
			s_axis_tdata         <= {DATA_WIDTH{1'b0}};
			data_seed            <= 32'h100;
			dma_error_pending    <= 1'b0;
			inject_dma_error_once <= 1'b0;
			force_bad_tuser_once <= 1'b0;
			m_export_active      <= 1'b0;
			m_export_remaining   <= 16'd0;
			m_export_buf         <= 1'b0;
			m_export_id          <= 32'd0;
			inject_m_dma_error_once <= 1'b0;
		end else begin
			if (dma_error_pending) begin
				dma_error <= 1'b1;
				dma_error_pending <= 1'b0;
			end

			if (dma_req_valid && dma_req_ready) begin
				dma_req_count <= dma_req_count + 1;
				if (inject_dma_error_once) begin
					inject_dma_error_once <= 1'b0;
					dma_error_pending <= 1'b1;
					dma_stream_active <= 1'b0;
					dma_stream_remaining <= 16'd0;
				end else begin
					dma_stream_active <= 1'b1;
					if (force_bad_tuser_once) begin
						force_bad_tuser_once <= 1'b0;
						dma_stream_tuser <= (dma_req_tuser == 2'b01) ? 2'b10 : 2'b01;
						dma_stream_remaining <= 16'd1;
					end else begin
						dma_stream_tuser <= dma_req_tuser;
						dma_stream_remaining <= dma_req_beats;
					end
				end
			end

			if (dma_stream_active) begin
				s_axis_tvalid <= 1'b1;
				s_axis_tuser  <= dma_stream_tuser;
				if (s_axis_tvalid && s_axis_tready) begin
					s_axis_tdata <= data_seed;
					data_seed    <= data_seed + 1;
					if (dma_stream_remaining == 16'd1) begin
						dma_stream_active    <= 1'b0;
						dma_stream_remaining <= 16'd0;
						dma_done             <= 1'b1;
						s_axis_tlast         <= 1'b1;
					end else begin
						dma_stream_remaining <= dma_stream_remaining - 1'b1;
					end
				end
			end else begin
				s_axis_tvalid <= 1'b0;
				s_axis_tuser  <= 2'b00;
			end

			if (m_dma_req_valid && m_dma_req_ready && !m_export_active) begin
				m_export_active    <= 1'b1;
				m_export_remaining <= m_dma_req_beats;
				m_export_buf       <= m_dma_req_buf;
				m_export_id        <= m_dma_req_id;
				m_export_req_count <= m_export_req_count + 1;
				if (m_dma_req_beats !== EXPORT_BEATS[15:0]) begin
					$display("[FAIL] m_dma_req_beats mismatch exp=%0d got=%0d", EXPORT_BEATS, m_dma_req_beats);
					errors = errors + 1;
				end
			end

			if (m_export_active) begin
				if (m_axis_tvalid && m_axis_tready) begin
					m_axis_beat_count <= m_axis_beat_count + 1;
					if (m_axis_tuser[0] !== m_export_buf) begin
						$display("[FAIL] m_axis_tuser buf mismatch exp=%0d got=%0d", m_export_buf, m_axis_tuser[0]);
						errors = errors + 1;
					end
					if (m_export_remaining == 16'd1) begin
						if (!m_axis_tlast) begin
							$display("[FAIL] m_axis_tlast expected at final beat (id=%h)", m_export_id);
							errors = errors + 1;
						end
						m_axis_last_count <= m_axis_last_count + 1;
						m_export_active <= 1'b0;
						m_export_remaining <= 16'd0;
						if (inject_m_dma_error_once) begin
							inject_m_dma_error_once <= 1'b0;
							m_dma_error <= 1'b1;
							m_export_error_count <= m_export_error_count + 1;
						end else begin
							m_dma_done <= 1'b1;
							m_export_done_count <= m_export_done_count + 1;
						end
					end else begin
						if (m_axis_tlast) begin
							$display("[FAIL] m_axis_tlast asserted early (remaining=%0d)", m_export_remaining);
							errors = errors + 1;
						end
						m_export_remaining <= m_export_remaining - 1'b1;
					end
				end
			end
		end
	end

	always @(posedge clk) begin
		if (!rstn || clear) begin
			gemm_start_count <= 0;
			irq_count        <= 0;
		end else begin
			if (dut.u_pt_v2.gemm_start)
				gemm_start_count <= gemm_start_count + 1;
			if (irq)
				irq_count <= irq_count + 1;
		end
	end

	initial begin
		clk           = 1'b0;
		rstn          = 1'b0;
		clear         = 1'b0;
		s_axis_tvalid = 1'b0;
		s_axis_tdata  = 0;
		s_axis_tstrb  = {DATA_WIDTH/8{1'b1}};
		s_axis_tlast  = 1'b0;
		s_axis_tkeep  = 1'b1;
		s_axis_tid    = 1'b0;
		s_axis_tdest  = 1'b0;
		s_axis_tuser  = 2'b00;
		m_axis_tready = 1'b1;
		ctrl_valid    = 1'b0;
		ctrl_inst     = 0;
		ctrl_id       = 0;
		dma_req_ready = 1'b1;
		dma_done      = 1'b0;
		dma_error     = 1'b0;
		m_dma_req_ready = 1'b1;
		m_dma_done    = 1'b0;
		m_dma_error   = 1'b0;
		errors        = 0;
		dma_req_count = 0;
		gemm_start_count = 0;
		irq_count     = 0;
		m_export_req_count = 0;
		m_export_done_count = 0;
		m_export_error_count = 0;
		m_axis_beat_count = 0;
		m_axis_last_count = 0;
		dma_stream_active = 1'b0;
		dma_stream_tuser = 2'b00;
		dma_stream_remaining = 0;
		data_seed = 32'h100;
		inject_dma_error_once = 1'b0;
		dma_error_pending = 1'b0;
		force_bad_tuser_once = 1'b0;
		m_export_active = 1'b0;
		m_export_remaining = 0;
		m_export_buf = 1'b0;
		m_export_id = 32'd0;
		inject_m_dma_error_once = 1'b0;

		repeat (5) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		// Configure external base addresses in pcsr
		send_ctrl_inst({`PT_OP_CFG, `PT_CFG_A_BASE_LO, 8'h00, 16'h0100}, 32'h10);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h10), 200);
			send_ctrl_inst({`PT_OP_CFG, `PT_CFG_B_BASE_LO, 8'h00, 16'h0200}, 32'h11);
			wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h11), 200);

			// QCFG protocol tests
			// a) per-tensor: header + 1 payload, response only after payload
			send_ctrl_inst(build_qcfg_header(`PT_QGRAN_PER_TENSOR), 32'h20);
			expect_no_ctrl_resp(4);
			send_ctrl_inst(32'h0001_0000, 32'h20);
			wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h20), 200);

			// b) x-wise: header + 2 payloads (X_DIM=2), response only after final payload
			send_ctrl_inst(build_qcfg_header(`PT_QGRAN_X_WISE), 32'h21);
			expect_no_ctrl_resp(4);
			send_ctrl_inst(32'h0000_8000, 32'h21);
			expect_no_ctrl_resp(4);
			send_ctrl_inst(32'h0001_0000, 32'h21);
			wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h21), 200);

			// c) id mismatch during payload must fail and return header id
			irq_before = irq_count;
			send_ctrl_inst(build_qcfg_header(`PT_QGRAN_Y_WISE), 32'h22);
			expect_no_ctrl_resp(4);
			send_ctrl_inst(32'h0001_0000, 32'h22);
			expect_no_ctrl_resp(4);
			send_ctrl_inst(32'h0001_0000, 32'h23);
			wait_ctrl_resp(pack_resp(1'b1, 1'b0, 32'h22), 200);
			repeat (10) @(posedge clk);
			if (irq_count != (irq_before + 1)) begin
				$display("[FAIL] qcfg id mismatch should raise error irq");
				errors = errors + 1;
			end

			// d) restore default scale
			send_ctrl_inst(build_qcfg_header(`PT_QGRAN_PER_TENSOR), 32'h24);
			expect_no_ctrl_resp(4);
			send_ctrl_inst(32'h0001_0000, 32'h24);
			wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h24), 200);

			// 1) full/full/full miss path
			irq_before = irq_count;
		dma_req_before = dma_req_count;
		m_export_req_before = m_export_req_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h004, 10'h008), 32'h1);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h1), 4000);
		repeat (30) @(posedge clk);
		if (dma_req_count < (dma_req_before + 2)) begin
			$display("[FAIL] expected >=2 DMA requests for first miss path, before=%0d after=%0d", dma_req_before, dma_req_count);
			errors = errors + 1;
		end
		if (gemm_start_count < 1) begin
			$display("[FAIL] expected GEMM start in first full path");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] first full path should trigger exactly one completion irq");
			errors = errors + 1;
		end
		if (m_export_req_count != (m_export_req_before + 1)) begin
			$display("[FAIL] expected one M export request after first completion");
			errors = errors + 1;
		end

		// 2) full/full/full hit path
		dma_req_before = dma_req_count;
		irq_before = irq_count;
		gemm_before = gemm_start_count;
		m_export_req_before = m_export_req_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h004, 10'h008), 32'h1);
		wait_ctrl_resp(pack_resp(1'b0, 1'b1, 32'h1), 4000);
		repeat (30) @(posedge clk);
		if (dma_req_count != dma_req_before) begin
			$display("[FAIL] expected hit path with no new DMA request, before=%0d after=%0d", dma_req_before, dma_req_count);
			errors = errors + 1;
		end
		if (gemm_start_count < (gemm_before + 1)) begin
			$display("[FAIL] expected second GEMM start for hit path");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] hit path should trigger one completion irq");
			errors = errors + 1;
		end
		if (m_export_req_count != (m_export_req_before + 1)) begin
			$display("[FAIL] expected one M export request on hit path");
			errors = errors + 1;
		end

		// 3) M-window reuse path: A/B both source from M buffer=1
		dma_req_before = dma_req_count;
		irq_before = irq_count;
		m_export_req_before = m_export_req_count;
		send_ctrl_inst(
			build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL,
			                 build_mwin_off(1'b1, 8'h00), build_mwin_off(1'b1, 8'h00)),
			32'h3
		);
		wait_ctrl_resp(pack_resp(1'b0, 1'b0, 32'h3), 4000);
		repeat (30) @(posedge clk);
		if (dma_req_count != dma_req_before) begin
			$display("[FAIL] M-window reuse should not issue DMA");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] M-window path should trigger one completion irq");
			errors = errors + 1;
		end
		if (m_export_req_count != (m_export_req_before + 1)) begin
			$display("[FAIL] expected one M export request on M-window path");
			errors = errors + 1;
		end

		// 4) unsupported MNK must be rejected immediately
		irq_before = irq_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL_DIV2, `PT_SCALE_FULL, 10'h010, 10'h020), 32'h4);
		wait_ctrl_resp(pack_resp(1'b1, 1'b0, 32'h4), 500);
		repeat (10) @(posedge clk);
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] unsupported MNK should raise error irq");
			errors = errors + 1;
		end

		// 5) non-row-aligned offset must be rejected immediately
		irq_before = irq_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h001, 10'h008), 32'h5);
		wait_ctrl_resp(pack_resp(1'b1, 1'b0, 32'h5), 500);
		repeat (10) @(posedge clk);
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] non-aligned offset should raise error irq");
			errors = errors + 1;
		end

		// 6) A/B DMA error path
		irq_before = irq_count;
		inject_dma_error_once = 1'b1;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h020, 10'h024), 32'h6);
		wait_ctrl_resp(pack_resp(1'b1, 1'b0, 32'h6), 2000);
		repeat (20) @(posedge clk);
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] dma_error should raise error irq");
			errors = errors + 1;
		end

		// 7) illegal tuser path
		irq_before = irq_count;
		force_bad_tuser_once = 1'b1;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h030, 10'h034), 32'h7);
		wait_ctrl_resp(pack_resp(1'b1, 1'b0, 32'h7), 2000);
		repeat (20) @(posedge clk);
		if (irq_count != (irq_before + 1)) begin
			$display("[FAIL] illegal tuser should raise error irq");
			errors = errors + 1;
		end

		// 8) M export DMA error path: expect success resp first, then export error resp
		irq_before = irq_count;
		inject_m_dma_error_once = 1'b1;
		m_export_req_before = m_export_req_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h040, 10'h044), 32'h8);
		wait_ctrl_resp(pack_resp(1'b0, 1'b1, 32'h8), 4000);
		wait_ctrl_resp(pack_resp(1'b1, 1'b1, 32'h8), 4000);
		repeat (30) @(posedge clk);
		if (m_export_req_count != (m_export_req_before + 1)) begin
			$display("[FAIL] expected one M export request before export error");
			errors = errors + 1;
		end
		if (irq_count != (irq_before + 2)) begin
			$display("[FAIL] export error case should raise completion+error irq");
			errors = errors + 1;
		end

		if (m_axis_beat_count != (m_export_req_count * EXPORT_BEATS)) begin
			$display("[FAIL] m_axis beat count mismatch exp=%0d got=%0d", m_export_req_count * EXPORT_BEATS, m_axis_beat_count);
			errors = errors + 1;
		end
		if (m_axis_last_count != m_export_req_count) begin
			$display("[FAIL] m_axis last count mismatch exp=%0d got=%0d", m_export_req_count, m_axis_last_count);
			errors = errors + 1;
		end

		if (errors == 0) begin
			$display("TB RESULT (PT): PASS");
		end else begin
			$display("TB RESULT (PT): FAIL (errors=%0d)", errors);
		end

		#20;
		$finish;
	end

endmodule
