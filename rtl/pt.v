`include "param.vh"

module PT #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4 ,
	parameter GEMM_Y_DIM   = 4 ,
	parameter EXT_ADDR_W   = 32,
	parameter DMA_BEATS_W  = 16,
	parameter LUT_DEPTH    = 8 ,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16
) (
	// clock, reset and soft reset
	input  wire                       clk ,
	input  wire                       rstn,
	input  wire                       clear,

	// standard axi4-stream slave interface (matrix a, matrix b)
	input  wire                       s_axis_tvalid,
	output wire                       s_axis_tready,
	input  wire [     DATA_WIDTH-1:0] s_axis_tdata ,
	input  wire [   DATA_WIDTH/8-1:0] s_axis_tstrb ,
	input  wire                       s_axis_tlast ,
	input  wire                       s_axis_tkeep ,
	input  wire                       s_axis_tid   ,
	input  wire                       s_axis_tdest ,
	input  wire [                1:0] s_axis_tuser ,

	// standard axi4-stream master interface (matrix m export)
	output wire                       m_axis_tvalid,
	input  wire                       m_axis_tready,
	output wire [     DATA_WIDTH-1:0] m_axis_tdata ,
	output wire [   DATA_WIDTH/8-1:0] m_axis_tstrb ,
	output wire                       m_axis_tlast ,
	output wire                       m_axis_tkeep ,
	output wire                       m_axis_tid   ,
	output wire                       m_axis_tdest ,
	output wire [                1:0] m_axis_tuser ,

	// control signals
	input  wire                       ctrl_valid,
	output wire                       ctrl_ready,
	input  wire [`INST_WIDTH-1:0]     ctrl_inst ,
	input  wire [               31:0] ctrl_id   ,
	output wire [               31:0] ctrl_resp ,
	output wire                       ctrl_resp_valid,

	// dma request/response for A/B load
	output wire                       dma_req_valid     ,
	input  wire                       dma_req_ready     ,
	output wire [                1:0] dma_req_tuser     ,
	output wire [               31:0] dma_req_id        ,
	output wire [         EXT_ADDR_W-1:0] dma_req_ext_addr  ,
	output wire [                9:0] dma_req_local_addr,
	output wire [        DMA_BEATS_W-1:0] dma_req_beats     ,
	input  wire                       dma_done          ,
	input  wire                       dma_error         ,

	// dma request/response for M export
	output wire                       m_dma_req_valid,
	input  wire                       m_dma_req_ready,
	output wire [               31:0] m_dma_req_id,
	output wire                       m_dma_req_buf,
	output wire [        DMA_BEATS_W-1:0] m_dma_req_beats,
	input  wire                       m_dma_done,
	input  wire                       m_dma_error,

	// irq output
	output wire                       irq
);

	localparam integer A_LW = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_AW = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);
	localparam integer M_DEPTH = A_BANK_DEPTH;
	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;

	// MD -> memory write controls
	wire                  a_mem_wr_en;
	wire                  a_mem_wr_buf;
	wire [A_LW-1:0]       a_mem_wr_lane;
	wire [A_AW-1:0]       a_mem_wr_addr;
	wire [DATA_WIDTH-1:0] a_mem_wr_data;
	wire                  b_mem_wr_en;
	wire                  b_mem_wr_buf;
	wire [B_LW-1:0]       b_mem_wr_lane;
	wire [B_AW-1:0]       b_mem_wr_addr;
	wire [DATA_WIDTH-1:0] b_mem_wr_data;

	// CE -> memory read controls
	wire                  a_mem_rd_en;
	wire                  exec_a_buf;
	wire [A_AW-1:0]       exec_a_addr;
	wire                  b_mem_rd_en;
	wire                  exec_b_buf;
	wire [B_AW-1:0]       exec_b_addr;

	// CE M-window source selects
	wire                  exec_a_is_m;
	wire                  exec_b_is_m;
	wire                  exec_m_a_buf;
	wire                  exec_m_b_buf;
	wire [A_AW-1:0]       exec_m_a_addr;
	wire [B_AW-1:0]       exec_m_b_addr;
	wire                  exec_m_a_rd_en;
	wire                  exec_m_b_rd_en;

	// MD -> CE issue queue stream
	wire                  ce_inst_valid;
	wire                  ce_inst_ready;
	wire [`INST_WIDTH-1:0] ce_inst;
	wire [31:0]           ce_id;

	// CE -> GEMM control
	wire                  gemm_start;
	wire [DATA_WIDTH-1:0] gemm_num_acc;
	wire                  gemm_a_valid;
	wire                  gemm_b_valid;
	wire                  gemm_a_ready;
	wire                  gemm_b_ready;
	wire [GEMM_Y_DIM*4*DATA_WIDTH-1:0] gemm_m_data;
	wire [31:0]           gemm_m_idx;
	wire                  gemm_m_valid;
	wire                  gemm_m_last;
	wire                  gemm_m_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] quant_m_data;
	wire [31:0]           quant_m_idx;
	wire                  quant_m_valid;
	wire                  quant_m_last;
	wire                  quant_m_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_lhs_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_rhs_data;
	wire [31:0]           gema_in_idx;
	wire                  gema_in_last;
	wire                  gema_in_valid;
	wire                  gema_in_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] add_m_data;
	wire [31:0]           add_m_idx;
	wire                  add_m_valid;
	wire                  add_m_last;
	wire                  add_m_ready;
	wire [2:0]            quant_mode;
	wire [MAX_DIM*32-1:0] quant_inv_scale;
	wire [31:0]           pcsr_a_base;
	wire [31:0]           pcsr_b_base;
	wire                  csr_a_base_lo_we;
	wire                  csr_a_base_hi_we;
	wire                  csr_b_base_lo_we;
	wire                  csr_b_base_hi_we;
	wire [15:0]           csr_cfg_wdata16;
	wire                  csr_quant_commit_we;
	wire [2:0]            csr_quant_mode_wdata;
	wire [MAX_DIM*32-1:0] csr_quant_inv_scale_wdata;

	// CE M writeback controls
	wire                  m_mem_wr_en;
	wire                  m_mem_wr_buf;
	wire [B_LW-1:0]       m_mem_wr_lane;
	wire [A_AW-1:0]       m_mem_wr_addr;
	wire [DATA_WIDTH-1:0] m_mem_wr_data;

	// MD export read controls for M bank
	wire                  exp_rd_en;
	wire                  exp_rd_buf;
	wire [A_AW-1:0]       exp_rd_addr;

	// ctrl response merge
	wire                  md_resp_valid;
	wire [31:0]           md_resp;
	wire                  ce_resp_valid;
	wire [31:0]           ce_resp;
	reg  [31:0]           ctrl_resp_r;
	reg                   ctrl_resp_valid_r;
	assign ctrl_resp = ctrl_resp_r;
	assign ctrl_resp_valid = ctrl_resp_valid_r;

	wire                  md_irq;
	wire                  ce_irq;
	assign irq = md_irq | ce_irq;

	// A/B memory data
	wire [GEMM_X_DIM*DATA_WIDTH-1:0] a_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_rd_data;

	// M bank read data
	wire [GEMM_X_DIM*DATA_WIDTH-1:0] m_a_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_b_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_exp_rd_data;
	wire [GEMM_X_DIM*DATA_WIDTH-1:0] gemm_a_data = exec_a_is_m ? m_a_mem_rd_data : a_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gemm_b_data = exec_b_is_m ? m_b_mem_rd_data : b_mem_rd_data;

	PT_MD #(
		.DATA_WIDTH  (DATA_WIDTH),
		.GEMM_X_DIM  (GEMM_X_DIM),
		.GEMM_Y_DIM  (GEMM_Y_DIM),
		.EXT_ADDR_W  (EXT_ADDR_W),
		.DMA_BEATS_W (DMA_BEATS_W),
		.LUT_DEPTH   (LUT_DEPTH),
		.A_BANK_DEPTH(A_BANK_DEPTH),
		.B_BANK_DEPTH(B_BANK_DEPTH)
	) u_md (
		.clk             (clk             ),
		.rstn            (rstn            ),
		.clear           (clear           ),
		.ctrl_valid      (ctrl_valid      ),
		.ctrl_ready      (ctrl_ready      ),
		.ctrl_inst       (ctrl_inst       ),
		.ctrl_id         (ctrl_id         ),
		.md_resp_valid   (md_resp_valid   ),
		.md_resp         (md_resp         ),
		.s_axis_tvalid   (s_axis_tvalid   ),
		.s_axis_tdata    (s_axis_tdata    ),
		.s_axis_tuser    (s_axis_tuser    ),
		.s_axis_tready   (s_axis_tready   ),
		.dma_req_valid   (dma_req_valid   ),
		.dma_req_ready   (dma_req_ready   ),
		.dma_req_tuser   (dma_req_tuser   ),
		.dma_req_id      (dma_req_id      ),
		.dma_req_ext_addr(dma_req_ext_addr),
		.dma_req_local_addr(dma_req_local_addr),
		.dma_req_beats   (dma_req_beats   ),
		.dma_done        (dma_done        ),
		.dma_error       (dma_error       ),
		.a_mem_wr_en     (a_mem_wr_en     ),
		.a_mem_wr_buf    (a_mem_wr_buf    ),
		.a_mem_wr_lane   (a_mem_wr_lane   ),
		.a_mem_wr_addr   (a_mem_wr_addr   ),
		.a_mem_wr_data   (a_mem_wr_data   ),
		.b_mem_wr_en     (b_mem_wr_en     ),
		.b_mem_wr_buf    (b_mem_wr_buf    ),
		.b_mem_wr_lane   (b_mem_wr_lane   ),
		.b_mem_wr_addr   (b_mem_wr_addr   ),
		.b_mem_wr_data   (b_mem_wr_data   ),
		.ce_inst_valid   (ce_inst_valid   ),
		.ce_inst_ready   (ce_inst_ready   ),
		.ce_inst         (ce_inst         ),
		.ce_id           (ce_id           ),
		.ce_resp_valid   (ce_resp_valid   ),
		.ce_resp         (ce_resp         ),
		.m_dma_req_valid (m_dma_req_valid ),
		.m_dma_req_ready (m_dma_req_ready ),
		.m_dma_req_id    (m_dma_req_id    ),
		.m_dma_req_buf   (m_dma_req_buf   ),
		.m_dma_req_beats (m_dma_req_beats ),
		.m_dma_done      (m_dma_done      ),
		.m_dma_error     (m_dma_error     ),
		.m_axis_tvalid   (m_axis_tvalid   ),
		.m_axis_tready   (m_axis_tready   ),
		.m_axis_tdata    (m_axis_tdata    ),
		.m_axis_tstrb    (m_axis_tstrb    ),
		.m_axis_tlast    (m_axis_tlast    ),
		.m_axis_tkeep    (m_axis_tkeep    ),
		.m_axis_tid      (m_axis_tid      ),
		.m_axis_tdest    (m_axis_tdest    ),
			.m_axis_tuser    (m_axis_tuser    ),
			.exp_rd_en       (exp_rd_en       ),
			.exp_rd_buf      (exp_rd_buf      ),
			.exp_rd_addr     (exp_rd_addr     ),
			.exp_rd_data     (m_exp_rd_data   ),
			.pcsr_a_base     (pcsr_a_base     ),
			.pcsr_b_base     (pcsr_b_base     ),
			.csr_quant_inv_scale(quant_inv_scale),
			.csr_a_base_lo_we(csr_a_base_lo_we),
			.csr_a_base_hi_we(csr_a_base_hi_we),
			.csr_b_base_lo_we(csr_b_base_lo_we),
			.csr_b_base_hi_we(csr_b_base_hi_we),
			.csr_cfg_wdata16 (csr_cfg_wdata16 ),
			.csr_quant_commit_we(csr_quant_commit_we),
			.csr_quant_mode_wdata(csr_quant_mode_wdata),
			.csr_quant_inv_scale_wdata(csr_quant_inv_scale_wdata),
			.irq             (md_irq          )
		);

	CSR_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_csr_bank (
		.clk                 (clk                  ),
		.rstn                (rstn                 ),
		.clear               (clear                ),
		.a_base_lo_we        (csr_a_base_lo_we     ),
		.a_base_hi_we        (csr_a_base_hi_we     ),
		.b_base_lo_we        (csr_b_base_lo_we     ),
		.b_base_hi_we        (csr_b_base_hi_we     ),
		.cfg_wdata16         (csr_cfg_wdata16      ),
		.quant_commit_we     (csr_quant_commit_we  ),
		.quant_mode_wdata    (csr_quant_mode_wdata ),
		.quant_inv_scale_wdata(csr_quant_inv_scale_wdata),
		.pcsr_a_base         (pcsr_a_base          ),
		.pcsr_b_base         (pcsr_b_base          ),
		.quant_mode          (quant_mode           ),
		.quant_inv_scale     (quant_inv_scale      )
	);

	PT_CE #(
		.DATA_WIDTH  (DATA_WIDTH),
		.GEMM_X_DIM  (GEMM_X_DIM),
		.GEMM_Y_DIM  (GEMM_Y_DIM),
		.A_BANK_DEPTH(A_BANK_DEPTH),
		.B_BANK_DEPTH(B_BANK_DEPTH)
	) u_ce (
		.clk         (clk         ),
		.rstn        (rstn        ),
		.clear       (clear       ),
		.ce_inst_valid(ce_inst_valid),
		.ce_inst_ready(ce_inst_ready),
		.ce_inst     (ce_inst     ),
		.ce_id       (ce_id       ),
		.a_mem_rd_en (a_mem_rd_en ),
		.exec_a_buf  (exec_a_buf  ),
		.exec_a_addr (exec_a_addr ),
		.b_mem_rd_en (b_mem_rd_en ),
		.exec_b_buf  (exec_b_buf  ),
		.exec_b_addr (exec_b_addr ),
		.exec_a_is_m (exec_a_is_m ),
		.exec_b_is_m (exec_b_is_m ),
		.exec_m_a_buf(exec_m_a_buf),
		.exec_m_b_buf(exec_m_b_buf),
		.exec_m_a_addr(exec_m_a_addr),
		.exec_m_b_addr(exec_m_b_addr),
		.exec_m_a_rd_en(exec_m_a_rd_en),
		.exec_m_b_rd_en(exec_m_b_rd_en),
		.gemm_a_valid(gemm_a_valid),
		.gemm_b_valid(gemm_b_valid),
		.gemm_start  (gemm_start  ),
		.gemm_num_acc(gemm_num_acc),
		.gemm_a_ready(gemm_a_ready),
		.gemm_b_ready(gemm_b_ready),
			.quant_m_data (quant_m_data ),
			.quant_m_idx  (quant_m_idx  ),
			.quant_m_valid(quant_m_valid),
			.quant_m_last (quant_m_last ),
			.quant_m_ready(quant_m_ready),
			.b_mem_row_data(b_mem_rd_data),
			.m_mem_row_data(m_b_mem_rd_data),
			.gema_lhs_data(gema_lhs_data),
			.gema_rhs_data(gema_rhs_data),
			.gema_in_idx  (gema_in_idx  ),
			.gema_in_last (gema_in_last ),
			.gema_in_valid(gema_in_valid),
			.gema_in_ready(gema_in_ready),
			.add_m_data   (add_m_data   ),
			.add_m_idx    (add_m_idx    ),
			.add_m_valid  (add_m_valid  ),
			.add_m_last   (add_m_last   ),
			.add_m_ready  (add_m_ready  ),
			.m_mem_wr_en (m_mem_wr_en ),
			.m_mem_wr_buf(m_mem_wr_buf),
			.m_mem_wr_lane(m_mem_wr_lane),
		.m_mem_wr_addr(m_mem_wr_addr),
		.m_mem_wr_data(m_mem_wr_data),
		.ce_resp_valid(ce_resp_valid),
		.ce_resp     (ce_resp     ),
		.ce_irq      (ce_irq      )
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (GEMM_X_DIM),
		.DEPTH     (A_BANK_DEPTH)
	) u_a_bank (
		.clk    (clk         ),
		.rstn   (rstn        ),
		.clear  (clear       ),
		.wr_en  (a_mem_wr_en ),
		.wr_buf (a_mem_wr_buf),
		.wr_lane(a_mem_wr_lane),
		.wr_addr(a_mem_wr_addr),
		.wr_data(a_mem_wr_data),
		.rd_en  (a_mem_rd_en ),
		.rd_buf (exec_a_buf  ),
		.rd_addr(exec_a_addr ),
		.rd_data(a_mem_rd_data)
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (GEMM_Y_DIM),
		.DEPTH     (B_BANK_DEPTH)
	) u_b_bank (
		.clk    (clk         ),
		.rstn   (rstn        ),
		.clear  (clear       ),
		.wr_en  (b_mem_wr_en ),
		.wr_buf (b_mem_wr_buf),
		.wr_lane(b_mem_wr_lane),
		.wr_addr(b_mem_wr_addr),
		.wr_data(b_mem_wr_data),
		.rd_en  (b_mem_rd_en ),
		.rd_buf (exec_b_buf  ),
		.rd_addr(exec_b_addr ),
		.rd_data(b_mem_rd_data)
	);

	PT_M_MEM #(
		.DATA_WIDTH(DATA_WIDTH),
		.A_LANES   (GEMM_X_DIM),
		.B_LANES   (GEMM_Y_DIM),
		.DEPTH     (M_DEPTH)
	) u_m_mem (
		.clk      (clk         ),
		.rstn     (rstn        ),
		.clear    (clear       ),
		.wr_en    (m_mem_wr_en ),
		.wr_buf   (m_mem_wr_buf),
		.wr_lane  (m_mem_wr_lane),
		.wr_addr  (m_mem_wr_addr),
		.wr_data  (m_mem_wr_data),
		.rd_a_en  (exec_m_a_rd_en),
		.rd_a_buf (exec_m_a_buf),
		.rd_a_addr(exec_m_a_addr),
		.rd_a_data(m_a_mem_rd_data),
		.rd_b_en  (exec_m_b_rd_en),
		.rd_b_buf (exec_m_b_buf),
		.rd_b_addr(exec_m_b_addr),
		.rd_b_data(m_b_mem_rd_data),
		.rd_exp_en(exp_rd_en),
		.rd_exp_buf(exp_rd_buf),
		.rd_exp_addr(exp_rd_addr),
		.rd_exp_data(m_exp_rd_data)
	);

	GEMM #(
		.WIDTH        (DATA_WIDTH),
		.X_DIM        (GEMM_X_DIM),
		.Y_DIM        (GEMM_Y_DIM),
		.OUTPUT_BY_ROW(1)
		) gemm_inst (
		.clk          (clk         ),
		.rstn         (rstn        ),
		.clear        (clear       ),
		.start        (gemm_start  ),
		.num_acc      (gemm_num_acc),
		.a_valid      (gemm_a_valid),
		.a_ready      (gemm_a_ready),
		.a            (gemm_a_data ),
		.b_valid      (gemm_b_valid),
		.b_ready      (gemm_b_ready),
		.b            (gemm_b_data ),
		.m_group_data (gemm_m_data ),
			.m_group_valid(gemm_m_valid),
			.m_group_ready(gemm_m_ready),
			.m_group_idx  (gemm_m_idx  ),
			.m_last       (gemm_m_last )
		);

		QUANT #(
			.DATA_WIDTH(DATA_WIDTH),
			.GEMM_X_DIM(GEMM_X_DIM),
			.GEMM_Y_DIM(GEMM_Y_DIM)
		) u_quant (
			.clk           (clk             ),
			.rstn          (rstn            ),
			.clear         (clear           ),
			.in_valid      (gemm_m_valid    ),
			.in_ready      (gemm_m_ready    ),
			.in_data       (gemm_m_data     ),
			.in_idx        (gemm_m_idx      ),
			.in_last       (gemm_m_last     ),
		.quant_mode    (quant_mode      ),
		.quant_inv_scale(quant_inv_scale),
		.out_valid     (quant_m_valid   ),
		.out_ready     (quant_m_ready   ),
		.out_data      (quant_m_data    ),
		.out_idx       (quant_m_idx     ),
		.out_last      (quant_m_last    )
	);

	GEMA #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_gema (
		.clk      (clk         ),
		.rstn     (rstn        ),
		.clear    (clear       ),
		.in_valid (gema_in_valid),
		.in_ready (gema_in_ready),
		.lhs_data (gema_lhs_data),
		.rhs_data (gema_rhs_data),
		.in_idx   (gema_in_idx ),
		.in_last  (gema_in_last),
		.out_valid(add_m_valid ),
		.out_ready(add_m_ready ),
		.out_data (add_m_data  ),
		.out_idx  (add_m_idx   ),
		.out_last (add_m_last  )
	);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			ctrl_resp_r       <= 32'd0;
			ctrl_resp_valid_r <= 1'b0;
		end else if (clear) begin
			ctrl_resp_r       <= 32'd0;
			ctrl_resp_valid_r <= 1'b0;
		end else begin
			ctrl_resp_valid_r <= 1'b0;
			if (md_resp_valid && md_resp[31]) begin
				ctrl_resp_r       <= md_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (ce_resp_valid) begin
				ctrl_resp_r       <= ce_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (md_resp_valid) begin
				ctrl_resp_r       <= md_resp;
				ctrl_resp_valid_r <= 1'b1;
			end
		end
	end

	// keep currently unused AXIS sideband inputs explicitly referenced
	wire _unused_ok = &{1'b0, s_axis_tstrb[0], s_axis_tlast, s_axis_tkeep, s_axis_tid, s_axis_tdest};

endmodule
