`timescale 1ns/1ps
`include "param.vh"

module tb_pt;
	localparam DATA_WIDTH = 32;
	localparam X_DIM      = 2 ;
	localparam Y_DIM      = 2 ;

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

	wire                   dma_req_valid;
	reg                    dma_req_ready;
	wire [1:0]             dma_req_tuser;
	wire [31:0]            dma_req_id;
	wire [31:0]            dma_req_ext_addr;
	wire [9:0]             dma_req_local_addr;
	wire [15:0]            dma_req_beats;
	reg                    dma_done;
	reg                    dma_error;
	wire                   irq;

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
		.dma_req_valid(dma_req_valid),
		.dma_req_ready(dma_req_ready),
		.dma_req_tuser(dma_req_tuser),
		.dma_req_id(dma_req_id),
		.dma_req_ext_addr(dma_req_ext_addr),
		.dma_req_local_addr(dma_req_local_addr),
		.dma_req_beats(dma_req_beats),
		.dma_done(dma_done),
		.dma_error(dma_error),
		.irq(irq)
	);

	always #5 clk = ~clk;

	integer errors;
	integer cycles;
	integer dma_req_count;
	integer gemm_start_count;
	integer irq_count;
	integer irq_before;
	integer dma_req_before;

	reg        dma_stream_active;
	reg [1:0]  dma_stream_tuser;
	reg [15:0] dma_stream_remaining;
	reg [DATA_WIDTH-1:0] data_seed;

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
		begin
			cycles = 0;
			while (cycles < timeout && ctrl_resp !== exp) begin
				@(posedge clk);
				cycles = cycles + 1;
			end
			if (ctrl_resp !== exp) begin
				$display("[FAIL] ctrl_resp timeout exp=%h got=%h", exp, ctrl_resp);
				errors = errors + 1;
			end
		end
	endtask

	always @(posedge clk) begin
		dma_done <= 1'b0;
		s_axis_tlast <= 1'b0;

		if (!rstn || clear) begin
			dma_stream_active    <= 1'b0;
			dma_stream_tuser     <= 2'b00;
			dma_stream_remaining <= 16'd0;
			s_axis_tvalid        <= 1'b0;
			s_axis_tuser         <= 2'b00;
			s_axis_tdata         <= {DATA_WIDTH{1'b0}};
			data_seed            <= 32'h100;
		end else begin
			if (dma_req_valid && dma_req_ready) begin
				dma_stream_active    <= 1'b1;
				dma_stream_tuser     <= dma_req_tuser;
				dma_stream_remaining <= dma_req_beats;
				dma_req_count        <= dma_req_count + 1;
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
		end
	end

	always @(posedge clk) begin
		if (!rstn || clear) begin
			gemm_start_count <= 0;
			irq_count        <= 0;
		end else begin
			if (dut.gemm_start)
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
		errors        = 0;
		dma_req_count = 0;
		gemm_start_count = 0;
		irq_count     = 0;
		dma_stream_active = 1'b0;
		dma_stream_tuser = 2'b00;
		dma_stream_remaining = 0;
		data_seed = 32'h100;

		repeat (5) @(posedge clk);
		rstn = 1'b1;
		@(posedge clk);

		// Configure external base addresses in pcsr
		send_ctrl_inst({`PT_OP_CFG, `PT_CFG_A_BASE_LO, 8'h00, 16'h0100}, 32'h10);
		wait_ctrl_resp(32'h10, 200);
		send_ctrl_inst({`PT_OP_CFG, `PT_CFG_B_BASE_LO, 8'h00, 16'h0200}, 32'h11);
		wait_ctrl_resp(32'h11, 200);

		// 1) full/full/full miss path: should request DMA for A and B then execute
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h004, 10'h008), 32'h1);
		wait_ctrl_resp(32'h1, 4000);
		cycles = 0;
		while (cycles < 4000 && gemm_start_count < 1) begin
			@(posedge clk);
			cycles = cycles + 1;
		end

		if (dma_req_count < 2) begin
			$display("[FAIL] expected at least 2 DMA requests for first miss path, got %0d", dma_req_count);
			errors = errors + 1;
		end
		if (gemm_start_count < 1) begin
			$display("[FAIL] expected GEMM start in first full path");
			errors = errors + 1;
		end

		// 2) full/full/full hit path: same id+offset should hit local cache, no extra DMA
		dma_req_before = dma_req_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL, `PT_SCALE_FULL, 10'h004, 10'h008), 32'h1);
		cycles = 0;
		while (cycles < 2000 && gemm_start_count < 2) begin
			@(posedge clk);
			cycles = cycles + 1;
		end
		if (dma_req_count != dma_req_before) begin
			$display("[FAIL] expected hit path with no new DMA request, before=%0d after=%0d", dma_req_before, dma_req_count);
			errors = errors + 1;
		end
		if (gemm_start_count < 2) begin
			$display("[FAIL] expected second GEMM start for hit path");
			errors = errors + 1;
		end

		// 3) unsupported MNK: N=full/2 should be rejected
		irq_before = irq_count;
		send_ctrl_inst(build_matmul_inst(`PT_OP_MATMUL, `PT_SCALE_FULL, `PT_SCALE_FULL_DIV2, `PT_SCALE_FULL, 10'h010, 10'h020), 32'h2);
		wait_ctrl_resp(32'h8000_0002, 500);
		repeat (20) @(posedge clk);
		if (irq_count <= irq_before) begin
			$display("[FAIL] unsupported mode should raise error IRQ");
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
