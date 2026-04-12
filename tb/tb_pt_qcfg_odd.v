`timescale 1ns/1ps
`include "param.vh"

module tb_pt_qcfg_odd;
	localparam DATA_WIDTH = 32;
	localparam X_DIM = 3;
	localparam Y_DIM = 2;

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

	integer errors;
	integer irq_count;

	PT #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_X_DIM(X_DIM),
		.GEMM_Y_DIM(Y_DIM),
		.EXT_ADDR_W(32),
		.DMA_BEATS_W(16),
		.LUT_DEPTH(8),
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
		integer t;
		reg got;
		begin
			t = 0;
			got = 1'b0;
			while ((t < timeout) && !got) begin
				@(posedge clk);
				if (ctrl_resp_valid) begin
					got = 1'b1;
					if (ctrl_resp !== exp) begin
						$display("[FAIL] ctrl_resp mismatch exp=%h got=%h", exp, ctrl_resp);
						errors = errors + 1;
					end
				end
				t = t + 1;
			end
			if (!got) begin
				$display("[FAIL] ctrl_resp timeout exp=%h", exp);
				errors = errors + 1;
			end
		end
	endtask

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
		irq_count = 0;

		repeat (5) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		send_ctrl_inst(build_qcfg_header(`PT_QGRAN_X_WISE_DIV2), 32'h55);
		wait_ctrl_resp(pack_resp(1'b1, 1'b0, 32'h55), 200);
		repeat (10) @(posedge clk);
		if (irq_count != 1) begin
			$display("[FAIL] odd X_DIM /2 granularity should raise irq");
			errors = errors + 1;
		end

		if (errors == 0) begin
			$display("TB RESULT (PT_QCFG_ODD): PASS");
		end else begin
			$display("TB RESULT (PT_QCFG_ODD): FAIL (errors=%0d)", errors);
		end

		#20;
		$finish;
	end

endmodule
