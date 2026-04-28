`include "param.vh"

module PT_V2 #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4,
	parameter GEMM_Y_DIM   = 4,
	parameter EXT_ADDR_W   = 32,
	parameter DMA_BEATS_W  = 16,
	parameter LUT_DEPTH    = 8,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16,
	parameter M_BANK_DEPTH = 16,
	parameter A_LOAD_LANES = GEMM_X_DIM,
	parameter B_LOAD_LANES = GEMM_Y_DIM,
	parameter M_WRITE_LANES = GEMM_Y_DIM,
	parameter M_EXPORT_LANES = GEMM_Y_DIM,
	parameter M_PHYSICAL_COPIES = 2
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire                       soft_clear,
	input  wire                       s_axis_tvalid,
	output wire                       s_axis_tready,
	input  wire [(((A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES)*DATA_WIDTH)-1:0]      s_axis_tdata,
	input  wire [(((A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES)*DATA_WIDTH/8)-1:0]    s_axis_tstrb,
	input  wire                       s_axis_tlast,
	input  wire                       s_axis_tkeep,
	input  wire                       s_axis_tid,
	input  wire                       s_axis_tdest,
	input  wire [1:0]                 s_axis_tuser,
	output wire                       m_axis_tvalid,
	input  wire                       m_axis_tready,
	output wire [M_EXPORT_LANES*DATA_WIDTH-1:0]      m_axis_tdata,
	output wire [M_EXPORT_LANES*DATA_WIDTH/8-1:0]    m_axis_tstrb,
	output wire                       m_axis_tlast,
	output wire                       m_axis_tkeep,
	output wire                       m_axis_tid,
	output wire                       m_axis_tdest,
	output wire [1:0]                 m_axis_tuser,
	input  wire                       ctrl_valid,
	output wire                       ctrl_ready,
	input  wire [`INST_WIDTH-1:0]     ctrl_inst,
	input  wire [31:0]                ctrl_id,
	output wire [31:0]                ctrl_resp,
	output wire                       ctrl_resp_valid,
	output wire                       dma_req_valid,
	input  wire                       dma_req_ready,
	output wire [`PT_DMA_KIND_W-1:0]  dma_req_kind,
	output wire [31:0]                dma_req_id,
	input  wire                       dma_done,
	input  wire                       dma_error,
	output wire                       m_dma_req_valid,
	input  wire                       m_dma_req_ready,
	output wire [31:0]                m_dma_req_id,
	output wire                       m_dma_req_buf,
	output wire [DMA_BEATS_W-1:0]     m_dma_req_beats,
	input  wire                       m_dma_done,
	input  wire                       m_dma_error,
	output wire                       irq
);

	localparam integer A_LW = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer LOAD_STREAM_LANES = (A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES;
	localparam integer A_DEPTH = A_BANK_DEPTH * GEMM_X_DIM;
	localparam integer B_DEPTH = B_BANK_DEPTH * GEMM_Y_DIM;
	localparam integer M_DEPTH = M_BANK_DEPTH * GEMM_X_DIM;
	localparam integer A_AW = (A_DEPTH <= 1) ? 1 : $clog2(A_DEPTH);
	localparam integer B_AW = (B_DEPTH <= 1) ? 1 : $clog2(B_DEPTH);
	localparam integer M_AW = (M_DEPTH <= 1) ? 1 : $clog2(M_DEPTH);
	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	wire pt_v2_unused_compat_inputs = &{1'b0, s_axis_tstrb, s_axis_tlast, s_axis_tkeep, s_axis_tid, s_axis_tdest, dma_done};

	wire                  a_mem_wr_en;
	wire                  a_mem_wr_buf;
	wire [GEMM_X_DIM-1:0] a_mem_wr_mask;
	wire [A_AW-1:0]       a_mem_wr_addr;
	wire [GEMM_X_DIM*DATA_WIDTH-1:0] a_mem_wr_data;
	wire                  b_mem_wr_en;
	wire                  b_mem_wr_buf;
	wire [GEMM_Y_DIM-1:0] b_mem_wr_mask;
	wire [B_AW-1:0]       b_mem_wr_addr;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_wr_data;

	wire                  a_mem_rd_en;
	wire                  exec_a_buf;
	wire [A_AW-1:0]       exec_a_addr;
	wire                  b_mem_rd_en;
	wire                  exec_b_buf;
	wire [B_AW-1:0]       exec_b_addr;
	wire                  exec_m_b_buf;
	wire [M_AW-1:0]       exec_m_b_addr;
	wire                  exec_m_b_rd_en;

	wire                  md_cmd_valid;
	wire                  md_cmd_ready;
	wire [`PT_MEM_KIND_W-1:0] md_cmd_kind;
	wire [`INST_WIDTH-1:0] md_cmd_inst;
	wire [31:0]           md_cmd_id;

	wire                  malloc_cmd_valid;
	wire                  malloc_cmd_ready;
	wire [`PT_MALLOC_KIND_W-1:0] malloc_cmd_kind;
	wire [`INST_WIDTH-1:0] malloc_cmd_inst;
	wire [31:0]           malloc_cmd_id;

	wire                  fill_req_valid;
	wire                  fill_req_ready;
	wire [`PT_DMA_KIND_W-1:0] fill_req_kind;
	wire [31:0]           fill_req_id;
	wire [`PT_LOCAL_ADDR_W-1:0] fill_req_local_base;
	wire [`PT_SIZE_W-1:0] fill_req_len;
	wire [3:0]            fill_req_m_tiles;
	wire [3:0]            fill_req_n_tiles;
	wire [3:0]            fill_req_k_tiles;
	wire                  fill_done_valid;
	wire [`PT_DMA_KIND_W-1:0] fill_done_kind;
	wire [31:0]           fill_done_id;
	wire                  fill_done_err;

	wire                  ce_cmd_valid;
	wire                  ce_cmd_ready;
	wire [`INST_WIDTH-1:0] ce_cmd_ctrl;
	wire [31:0]           ce_cmd_id;
	wire [`PT_LOCAL_ADDR_W-1:0] ce_a_local_base;
	wire [`PT_LOCAL_ADDR_W-1:0] ce_b_local_base;
	wire                  ce_m_wr_buf;

	wire                  gemm_start;
	wire [DATA_WIDTH-1:0] gemm_num_acc;
	wire                  gemm_a_valid;
	wire                  gemm_b_valid;
	wire                  gemm_a_ready;
	wire                  gemm_b_ready;
	wire                  gemm_start_ready;
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

	wire                  m_mem_wr_en;
	wire                  m_mem_wr_buf;
	wire [GEMM_Y_DIM-1:0] m_mem_wr_mask;
	wire [M_AW-1:0]       m_mem_wr_addr;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_mem_wr_data;
	wire                  exp_rd_en;
	wire                  exp_rd_buf;
	wire [M_AW-1:0]       exp_rd_addr;

	wire                  md_cmd_resp_valid;
	wire [31:0]           md_cmd_resp;
	wire                  md_cmd_irq;
	wire                  md_async_resp_valid;
	wire [31:0]           md_async_resp;
	wire                  md_async_irq;
	wire                  malloc_resp_valid;
	wire [31:0]           malloc_resp;
	wire                  malloc_irq;
	wire                  malloc_exec_busy;
	wire                  malloc_serial_busy;
	wire                  ce_resp_valid;
	wire [31:0]           ce_resp;
	wire [`PT_SIZE_W-1:0] ce_resp_row_chunk_count;
	wire                  ce_resp_single_output;
	wire                  ce_irq;
	reg  [31:0]           ctrl_resp_r;
	reg                   ctrl_resp_valid_r;
	wire                  runtime_clear = clear || soft_clear;
	assign ctrl_resp = ctrl_resp_r;
	assign ctrl_resp_valid = ctrl_resp_valid_r;
	assign irq = md_cmd_irq | md_async_irq | malloc_irq | ce_irq;

	wire [GEMM_X_DIM*DATA_WIDTH-1:0] a_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_b_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_exp_rd_data;
	wire                  m_alloc_ready;
	wire                  m_alloc_buf;
	wire                  m_alloc_take;
	wire                  m_buf0_single_output;
	wire                  m_buf1_single_output;

	PT_DISPATCH_V2 #(
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_dispatch (
		.clk            (clk),
		.rstn           (rstn),
		.clear          (runtime_clear),
		.ctrl_valid     (ctrl_valid),
		.ctrl_ready     (ctrl_ready),
		.ctrl_inst      (ctrl_inst),
		.ctrl_id        (ctrl_id),
		.md_cmd_valid   (md_cmd_valid),
		.md_cmd_ready   (md_cmd_ready),
		.md_cmd_kind    (md_cmd_kind),
		.md_cmd_inst    (md_cmd_inst),
		.md_cmd_id      (md_cmd_id),
		.md_cmd_resp_valid(md_cmd_resp_valid),
		.malloc_cmd_valid(malloc_cmd_valid),
		.malloc_cmd_ready(malloc_cmd_ready),
		.malloc_cmd_kind(malloc_cmd_kind),
		.malloc_cmd_inst(malloc_cmd_inst),
		.malloc_cmd_id  (malloc_cmd_id),
		.malloc_resp_valid(malloc_resp_valid),
		.malloc_exec_busy(malloc_exec_busy),
		.malloc_serial_busy(malloc_serial_busy)
	);

	PT_MALLOC #(
		.GEMM_X_DIM   (GEMM_X_DIM),
		.GEMM_Y_DIM   (GEMM_Y_DIM),
		.LUT_DEPTH    (LUT_DEPTH),
		.A_BANK_DEPTH (A_BANK_DEPTH),
		.B_BANK_DEPTH (B_BANK_DEPTH)
	) u_malloc (
		.clk            (clk),
		.rstn           (rstn),
		.clear          (runtime_clear),
		.malloc_cmd_valid(malloc_cmd_valid),
		.malloc_cmd_ready(malloc_cmd_ready),
		.malloc_cmd_kind(malloc_cmd_kind),
		.malloc_cmd_inst(malloc_cmd_inst),
		.malloc_cmd_id  (malloc_cmd_id),
		.fill_req_valid (fill_req_valid),
		.fill_req_ready (fill_req_ready),
		.fill_req_kind  (fill_req_kind),
		.fill_req_id    (fill_req_id),
		.fill_req_local_base(fill_req_local_base),
		.fill_req_len   (fill_req_len),
		.fill_req_m_tiles(fill_req_m_tiles),
		.fill_req_n_tiles(fill_req_n_tiles),
		.fill_req_k_tiles(fill_req_k_tiles),
		.fill_done_valid(fill_done_valid),
		.fill_done_kind (fill_done_kind),
		.fill_done_id   (fill_done_id),
		.fill_done_err  (fill_done_err),
		.ce_cmd_valid   (ce_cmd_valid),
		.ce_cmd_ready   (ce_cmd_ready),
		.ce_cmd_ctrl    (ce_cmd_ctrl),
		.ce_cmd_id      (ce_cmd_id),
		.ce_a_local_base(ce_a_local_base),
		.ce_b_local_base(ce_b_local_base),
		.ce_m_wr_buf    (ce_m_wr_buf),
		.m_alloc_ready  (m_alloc_ready),
		.m_alloc_buf    (m_alloc_buf),
		.m_alloc_take   (m_alloc_take),
		.m_buf0_single_output(m_buf0_single_output),
		.m_buf1_single_output(m_buf1_single_output),
		.ce_resp_valid  (ce_resp_valid),
		.ce_resp        (ce_resp),
		.malloc_resp_valid(malloc_resp_valid),
		.malloc_resp    (malloc_resp),
		.malloc_irq     (malloc_irq),
		.exec_busy      (malloc_exec_busy),
		.serial_exec_busy(malloc_serial_busy)
	);

	PT_MD_V2 #(
		.DATA_WIDTH   (DATA_WIDTH),
		.GEMM_X_DIM   (GEMM_X_DIM),
		.GEMM_Y_DIM   (GEMM_Y_DIM),
		.DMA_BEATS_W  (DMA_BEATS_W),
		.A_BANK_DEPTH (A_BANK_DEPTH),
		.B_BANK_DEPTH (B_BANK_DEPTH),
		.M_BANK_DEPTH (M_BANK_DEPTH),
		.A_LOAD_LANES (A_LOAD_LANES),
		.B_LOAD_LANES (B_LOAD_LANES),
		.M_EXPORT_LANES(M_EXPORT_LANES)
	) u_md (
		.clk            (clk),
		.rstn           (rstn),
		.clear          (runtime_clear),
		.md_cmd_valid   (md_cmd_valid),
		.md_cmd_ready   (md_cmd_ready),
		.md_cmd_kind    (md_cmd_kind),
		.md_cmd_inst    (md_cmd_inst),
		.md_cmd_id      (md_cmd_id),
		.md_cmd_resp_valid(md_cmd_resp_valid),
		.md_cmd_resp    (md_cmd_resp),
		.md_cmd_irq     (md_cmd_irq),
		.md_async_resp_valid(md_async_resp_valid),
		.md_async_resp  (md_async_resp),
		.md_async_irq   (md_async_irq),
		.fill_req_valid (fill_req_valid),
		.fill_req_ready (fill_req_ready),
		.fill_req_kind  (fill_req_kind),
		.fill_req_id    (fill_req_id),
		.fill_req_local_base(fill_req_local_base),
		.fill_req_len   (fill_req_len),
		.fill_req_m_tiles(fill_req_m_tiles),
		.fill_req_n_tiles(fill_req_n_tiles),
		.fill_req_k_tiles(fill_req_k_tiles),
		.fill_done_valid(fill_done_valid),
		.fill_done_kind (fill_done_kind),
		.fill_done_id   (fill_done_id),
		.fill_done_err  (fill_done_err),
		.s_axis_tvalid  (s_axis_tvalid),
		.s_axis_tdata   (s_axis_tdata),
		.s_axis_tuser   (s_axis_tuser),
		.s_axis_tready  (s_axis_tready),
		.dma_req_valid  (dma_req_valid),
		.dma_req_ready  (dma_req_ready),
		.dma_req_kind   (dma_req_kind),
		.dma_req_id     (dma_req_id),
		.dma_error      (dma_error),
		.a_mem_wr_en    (a_mem_wr_en),
		.a_mem_wr_buf   (a_mem_wr_buf),
		.a_mem_wr_mask  (a_mem_wr_mask),
		.a_mem_wr_addr  (a_mem_wr_addr),
		.a_mem_wr_data  (a_mem_wr_data),
		.b_mem_wr_en    (b_mem_wr_en),
		.b_mem_wr_buf   (b_mem_wr_buf),
		.b_mem_wr_mask  (b_mem_wr_mask),
		.b_mem_wr_addr  (b_mem_wr_addr),
		.b_mem_wr_data  (b_mem_wr_data),
		.m_alloc_take   (m_alloc_take),
		.m_alloc_ready  (m_alloc_ready),
		.m_alloc_buf    (m_alloc_buf),
		.m_buf0_single_output(m_buf0_single_output),
		.m_buf1_single_output(m_buf1_single_output),
		.ce_resp_valid  (ce_resp_valid),
		.ce_resp        (ce_resp),
		.ce_resp_row_chunk_count(ce_resp_row_chunk_count),
		.ce_resp_single_output(ce_resp_single_output),
		.m_dma_req_valid(m_dma_req_valid),
		.m_dma_req_ready(m_dma_req_ready),
		.m_dma_req_id   (m_dma_req_id),
		.m_dma_req_buf  (m_dma_req_buf),
		.m_dma_req_beats(m_dma_req_beats),
		.m_dma_done     (m_dma_done),
		.m_dma_error    (m_dma_error),
		.m_axis_tvalid  (m_axis_tvalid),
		.m_axis_tready  (m_axis_tready),
		.m_axis_tdata   (m_axis_tdata),
		.m_axis_tstrb   (m_axis_tstrb),
		.m_axis_tlast   (m_axis_tlast),
		.m_axis_tkeep   (m_axis_tkeep),
		.m_axis_tid     (m_axis_tid),
		.m_axis_tdest   (m_axis_tdest),
		.m_axis_tuser   (m_axis_tuser),
		.exp_rd_en      (exp_rd_en),
		.exp_rd_buf     (exp_rd_buf),
		.exp_rd_addr    (exp_rd_addr),
		.exp_rd_data    (m_exp_rd_data),
		.csr_quant_inv_scale(quant_inv_scale),
		.csr_a_base_lo_we(csr_a_base_lo_we),
		.csr_a_base_hi_we(csr_a_base_hi_we),
		.csr_b_base_lo_we(csr_b_base_lo_we),
		.csr_b_base_hi_we(csr_b_base_hi_we),
		.csr_cfg_wdata16(csr_cfg_wdata16),
		.csr_quant_commit_we(csr_quant_commit_we),
		.csr_quant_mode_wdata(csr_quant_mode_wdata),
		.csr_quant_inv_scale_wdata(csr_quant_inv_scale_wdata)
	);

	CSR_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_csr_bank (
		.clk                 (clk),
		.rstn                (rstn),
		.clear               (clear),
		.a_base_lo_we        (csr_a_base_lo_we),
		.a_base_hi_we        (csr_a_base_hi_we),
		.b_base_lo_we        (csr_b_base_lo_we),
		.b_base_hi_we        (csr_b_base_hi_we),
		.cfg_wdata16         (csr_cfg_wdata16),
		.quant_commit_we     (csr_quant_commit_we),
		.quant_mode_wdata    (csr_quant_mode_wdata),
		.quant_inv_scale_wdata(csr_quant_inv_scale_wdata),
		.pcsr_a_base         (pcsr_a_base),
		.pcsr_b_base         (pcsr_b_base),
		.quant_mode          (quant_mode),
		.quant_inv_scale     (quant_inv_scale)
	);

	PT_CE_V2 #(
		.DATA_WIDTH   (DATA_WIDTH),
		.GEMM_X_DIM   (GEMM_X_DIM),
		.GEMM_Y_DIM   (GEMM_Y_DIM),
		.A_BANK_DEPTH (A_BANK_DEPTH),
		.B_BANK_DEPTH (B_BANK_DEPTH),
		.M_BANK_DEPTH (M_BANK_DEPTH),
		.M_WRITE_LANES(M_WRITE_LANES)
	) u_ce (
		.clk            (clk),
		.rstn           (rstn),
		.clear          (runtime_clear),
		.ce_cmd_valid   (ce_cmd_valid),
		.ce_cmd_ready   (ce_cmd_ready),
		.ce_cmd_ctrl    (ce_cmd_ctrl),
		.ce_cmd_id      (ce_cmd_id),
		.ce_a_local_base(ce_a_local_base),
		.ce_b_local_base(ce_b_local_base),
		.ce_m_wr_buf    (ce_m_wr_buf),
		.a_mem_rd_en    (a_mem_rd_en),
		.exec_a_buf     (exec_a_buf),
		.exec_a_addr    (exec_a_addr),
		.b_mem_rd_en    (b_mem_rd_en),
		.exec_b_buf     (exec_b_buf),
		.exec_b_addr    (exec_b_addr),
		.exec_m_b_buf   (exec_m_b_buf),
		.exec_m_b_addr  (exec_m_b_addr),
		.exec_m_b_rd_en (exec_m_b_rd_en),
		.gemm_a_valid   (gemm_a_valid),
		.gemm_b_valid   (gemm_b_valid),
		.gemm_start     (gemm_start),
		.gemm_num_acc   (gemm_num_acc),
		.gemm_a_ready   (gemm_a_ready),
		.gemm_b_ready   (gemm_b_ready),
		.gemm_start_ready(gemm_start_ready),
		.quant_m_data   (quant_m_data),
		.quant_m_idx    (quant_m_idx),
		.quant_m_valid  (quant_m_valid),
		.quant_m_last   (quant_m_last),
		.quant_m_ready  (quant_m_ready),
		.b_mem_row_data (b_mem_rd_data),
		.m_mem_row_data (m_b_mem_rd_data),
		.m_buf0_single_output(m_buf0_single_output),
		.m_buf1_single_output(m_buf1_single_output),
		.gema_lhs_data  (gema_lhs_data),
		.gema_rhs_data  (gema_rhs_data),
		.gema_in_idx    (gema_in_idx),
		.gema_in_last   (gema_in_last),
		.gema_in_valid  (gema_in_valid),
		.gema_in_ready  (gema_in_ready),
		.add_m_data     (add_m_data),
		.add_m_idx      (add_m_idx),
		.add_m_valid    (add_m_valid),
		.add_m_last     (add_m_last),
		.add_m_ready    (add_m_ready),
		.m_mem_wr_en    (m_mem_wr_en),
		.m_mem_wr_buf   (m_mem_wr_buf),
		.m_mem_wr_mask  (m_mem_wr_mask),
		.m_mem_wr_addr  (m_mem_wr_addr),
		.m_mem_wr_data  (m_mem_wr_data),
		.ce_resp_valid  (ce_resp_valid),
		.ce_resp        (ce_resp),
		.ce_resp_row_chunk_count(ce_resp_row_chunk_count),
		.ce_resp_single_output(ce_resp_single_output),
		.ce_irq         (ce_irq)
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (GEMM_X_DIM),
		.DEPTH     (A_DEPTH)
	) u_a_bank (
		.clk    (clk),
		.rstn   (rstn),
		.clear  (runtime_clear),
		.wr_en  (a_mem_wr_en),
		.wr_buf (a_mem_wr_buf),
		.wr_mask(a_mem_wr_mask),
		.wr_addr(a_mem_wr_addr),
		.wr_data(a_mem_wr_data),
		.rd_en  (a_mem_rd_en),
		.rd_buf (exec_a_buf),
		.rd_addr(exec_a_addr),
		.rd_data(a_mem_rd_data)
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (GEMM_Y_DIM),
		.DEPTH     (B_DEPTH)
	) u_b_bank (
		.clk    (clk),
		.rstn   (rstn),
		.clear  (runtime_clear),
		.wr_en  (b_mem_wr_en),
		.wr_buf (b_mem_wr_buf),
		.wr_mask(b_mem_wr_mask),
		.wr_addr(b_mem_wr_addr),
		.wr_data(b_mem_wr_data),
		.rd_en  (b_mem_rd_en),
		.rd_buf (exec_b_buf),
		.rd_addr(exec_b_addr),
		.rd_data(b_mem_rd_data)
	);

	PT_M_MEM #(
		.DATA_WIDTH(DATA_WIDTH),
		.B_LANES   (GEMM_Y_DIM),
		.DEPTH     (M_DEPTH),
		.M_PHYSICAL_COPIES(M_PHYSICAL_COPIES)
	) u_m_mem (
		.clk      (clk),
		.rstn     (rstn),
		.clear    (runtime_clear),
		.wr_en    (m_mem_wr_en),
		.wr_buf   (m_mem_wr_buf),
		.wr_mask  (m_mem_wr_mask),
		.wr_addr  (m_mem_wr_addr),
		.wr_data  (m_mem_wr_data),
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
		.clk          (clk),
		.rstn         (rstn),
		.clear        (runtime_clear),
		.start        (gemm_start),
		.num_acc      (gemm_num_acc),
		.a_valid      (gemm_a_valid),
		.a_ready      (gemm_a_ready),
		.a            (a_mem_rd_data),
		.b_valid      (gemm_b_valid),
		.b_ready      (gemm_b_ready),
		.b            (b_mem_rd_data),
		.start_ready  (gemm_start_ready),
		.m_group_data (gemm_m_data),
		.m_group_valid(gemm_m_valid),
		.m_group_ready(gemm_m_ready),
		.m_group_idx  (gemm_m_idx),
		.m_last       (gemm_m_last)
	);

	QUANT #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_quant (
		.clk            (clk),
		.rstn           (rstn),
		.clear          (runtime_clear),
		.in_valid       (gemm_m_valid),
		.in_ready       (gemm_m_ready),
		.in_data        (gemm_m_data),
		.in_idx         (gemm_m_idx),
		.in_last        (gemm_m_last),
		.quant_mode     (quant_mode),
		.quant_inv_scale(quant_inv_scale),
		.out_valid      (quant_m_valid),
		.out_ready      (quant_m_ready),
		.out_data       (quant_m_data),
		.out_idx        (quant_m_idx),
		.out_last       (quant_m_last)
	);

	GEMA #(
		.DATA_WIDTH(DATA_WIDTH),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_gema (
		.clk      (clk),
		.rstn     (rstn),
		.clear    (runtime_clear),
		.in_valid (gema_in_valid),
		.in_ready (gema_in_ready),
		.lhs_data (gema_lhs_data),
		.rhs_data (gema_rhs_data),
		.in_idx   (gema_in_idx),
		.in_last  (gema_in_last),
		.out_valid(add_m_valid),
		.out_ready(add_m_ready),
		.out_data (add_m_data),
		.out_idx  (add_m_idx),
		.out_last (add_m_last)
	);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			ctrl_resp_r       <= 32'd0;
			ctrl_resp_valid_r <= 1'b0;
		end else if (runtime_clear) begin
			ctrl_resp_r       <= 32'd0;
			ctrl_resp_valid_r <= 1'b0;
		end else begin
			ctrl_resp_valid_r <= 1'b0;
			if (md_async_resp_valid) begin
				ctrl_resp_r       <= md_async_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (malloc_resp_valid && malloc_resp[31]) begin
				ctrl_resp_r       <= malloc_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (md_cmd_resp_valid && md_cmd_resp[31]) begin
				ctrl_resp_r       <= md_cmd_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (ce_resp_valid && ce_resp[31]) begin
				ctrl_resp_r       <= ce_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (ce_resp_valid) begin
				ctrl_resp_r       <= ce_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (malloc_resp_valid) begin
				ctrl_resp_r       <= malloc_resp;
				ctrl_resp_valid_r <= 1'b1;
			end else if (md_cmd_resp_valid) begin
				ctrl_resp_r       <= md_cmd_resp;
				ctrl_resp_valid_r <= 1'b1;
			end
		end
	end

endmodule
