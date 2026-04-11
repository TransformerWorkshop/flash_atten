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

	// standard axi4-stream master interface (matrix m)
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

	// dma request/response
	output wire                       dma_req_valid     ,
	input  wire                       dma_req_ready     ,
	output wire [                1:0] dma_req_tuser     ,
	output wire [               31:0] dma_req_id        ,
	output wire [         EXT_ADDR_W-1:0] dma_req_ext_addr  ,
	output wire [                9:0] dma_req_local_addr,
	output wire [        DMA_BEATS_W-1:0] dma_req_beats     ,
	input  wire                       dma_done          ,
	input  wire                       dma_error         ,

	// irq output
	output wire                       irq
);

	localparam integer A_LW = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_AW = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);

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
	wire                  gemm_m_valid;
	wire                  gemm_m_last;

	// ctrl response merge
	wire                  md_resp_valid;
	wire [31:0]           md_resp;
	wire                  ce_resp_valid;
	wire [31:0]           ce_resp;
	reg  [31:0]           ctrl_resp_r;
	assign ctrl_resp = ctrl_resp_r;

	// memory data
	wire [GEMM_X_DIM*DATA_WIDTH-1:0] a_mem_rd_data;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_rd_data;

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
		.irq             (irq             )
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
		.gemm_a_valid(gemm_a_valid),
		.gemm_b_valid(gemm_b_valid),
		.gemm_start  (gemm_start  ),
		.gemm_num_acc(gemm_num_acc),
		.gemm_a_ready(gemm_a_ready),
		.gemm_b_ready(gemm_b_ready),
		.gemm_m_valid(gemm_m_valid),
		.gemm_m_last (gemm_m_last ),
		.ce_resp_valid(ce_resp_valid),
		.ce_resp     (ce_resp     )
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
		.a            (a_mem_rd_data),
		.b_valid      (gemm_b_valid),
		.b_ready      (gemm_b_ready),
		.b            (b_mem_rd_data),
		.m_group_data (),
		.m_group_valid(gemm_m_valid),
		.m_group_ready(1'b1),
		.m_group_idx  (),
		.m_last       (gemm_m_last )
	);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			ctrl_resp_r <= 32'd0;
		end else if (clear) begin
			ctrl_resp_r <= 32'd0;
		end else begin
			if (md_resp_valid) begin
				ctrl_resp_r <= md_resp;
			end
			if (ce_resp_valid) begin
				ctrl_resp_r <= ce_resp;
			end
		end
	end

	// result output is not implemented in this stage
	assign m_axis_tvalid = 1'b0;
	assign m_axis_tdata  = {DATA_WIDTH{1'b0}};
	assign m_axis_tstrb  = {(DATA_WIDTH/8){1'b0}};
	assign m_axis_tlast  = 1'b0;
	assign m_axis_tkeep  = 1'b0;
	assign m_axis_tid    = 1'b0;
	assign m_axis_tdest  = 1'b0;
	assign m_axis_tuser  = 2'b00;

	// keep currently unused AXIS sideband inputs explicitly referenced
	wire _unused_ok = &{1'b0, s_axis_tstrb[0], s_axis_tlast, s_axis_tkeep, s_axis_tid, s_axis_tdest, m_axis_tready};

endmodule

