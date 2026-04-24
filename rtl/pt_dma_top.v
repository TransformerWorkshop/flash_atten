`include "param.vh"

module PT_DMA_TOP #(
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
	parameter M_PHYSICAL_COPIES = 2,
	parameter CMD_FIFO_DEPTH = 4,
	parameter RESP_FIFO_DEPTH = 4
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire [7:0]                 s_axil_awaddr,
	input  wire                       s_axil_awvalid,
	output wire                       s_axil_awready,
	input  wire [31:0]                s_axil_wdata,
	input  wire [3:0]                 s_axil_wstrb,
	input  wire                       s_axil_wvalid,
	output wire                       s_axil_wready,
	output wire [1:0]                 s_axil_bresp,
	output wire                       s_axil_bvalid,
	input  wire                       s_axil_bready,
	input  wire [7:0]                 s_axil_araddr,
	input  wire                       s_axil_arvalid,
	output wire                       s_axil_arready,
	output wire [31:0]                s_axil_rdata,
	output wire [1:0]                 s_axil_rresp,
	output wire                       s_axil_rvalid,
	input  wire                       s_axil_rready,
	output wire                       rd_dma_desc_valid,
	input  wire                       rd_dma_desc_ready,
	output wire [EXT_ADDR_W-1:0]      rd_dma_desc_addr,
	output wire [31:0]                rd_dma_desc_id,
	output wire [`PT_DMA_KIND_W-1:0]  rd_dma_desc_kind,
	output wire [`PT_SIZE_W-1:0]      rd_dma_desc_elems,
	input  wire                       rd_dma_error,
	input  wire                       s_axis_tvalid,
	output wire                       s_axis_tready,
	input  wire [((A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES)*DATA_WIDTH-1:0]      s_axis_tdata,
	input  wire [((A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES)*DATA_WIDTH/8-1:0]    s_axis_tstrb,
	input  wire                       s_axis_tlast,
	input  wire                       s_axis_tkeep,
	input  wire                       s_axis_tid,
	input  wire                       s_axis_tdest,
	input  wire [1:0]                 s_axis_tuser,
	output wire                       wr_dma_desc_valid,
	input  wire                       wr_dma_desc_ready,
	output wire [EXT_ADDR_W-1:0]      wr_dma_desc_addr,
	output wire [31:0]                wr_dma_desc_id,
	output wire                       wr_dma_desc_buf,
	output wire [DMA_BEATS_W-1:0]     wr_dma_desc_beats,
	input  wire                       wr_dma_done,
	input  wire                       wr_dma_error,
	output wire                       m_axis_tvalid,
	input  wire                       m_axis_tready,
	output wire [M_EXPORT_LANES*DATA_WIDTH-1:0]      m_axis_tdata,
	output wire [M_EXPORT_LANES*DATA_WIDTH/8-1:0]    m_axis_tstrb,
	output wire                       m_axis_tlast,
	output wire                       m_axis_tkeep,
	output wire                       m_axis_tid,
	output wire                       m_axis_tdest,
	output wire [1:0]                 m_axis_tuser,
	output wire                       irq
);

	localparam integer DESC_AW = (LUT_DEPTH <= 1) ? 1 : $clog2(LUT_DEPTH);
	localparam integer CMD_TRACK_AW = (CMD_FIFO_DEPTH <= 1) ? 1 : $clog2(CMD_FIFO_DEPTH);
	localparam integer LOAD_STREAM_LANES = (A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES;
	localparam integer LOAD_STREAM_STRB_W = LOAD_STREAM_LANES * DATA_WIDTH / 8;
	localparam integer A_TILE_LEN = GEMM_X_DIM * GEMM_X_DIM;
	localparam integer B_TILE_LEN = GEMM_Y_DIM * GEMM_Y_DIM;

	wire                       csr_desc_push_pulse;
	wire                       csr_resp_pop_pulse;
	wire                       csr_soft_clear_pulse;
	wire                       csr_clear_flags_pulse;
	wire [31:0]                csr_cmd_inst;
	wire [31:0]                csr_cmd_id;
	wire [EXT_ADDR_W-1:0]      csr_a_addr;
	wire [EXT_ADDR_W-1:0]      csr_b_addr;
	wire [EXT_ADDR_W-1:0]      csr_c_addr;
	wire [EXT_ADDR_W-1:0]      csr_m_addr;

	wire [63:0]                cmd_fifo_data_out;
	wire                       cmd_fifo_valid_out;
	wire                       cmd_fifo_ready_in;
	wire                       cmd_fifo_pop_ready;
	wire [31:0]                resp_fifo_data_out;
	wire                       resp_fifo_valid_out;
	wire                       resp_fifo_ready_in;

	wire                       pt_ctrl_valid;
	wire                       pt_ctrl_ready;
	wire [31:0]                pt_ctrl_inst;
	wire [31:0]                pt_ctrl_id;
	wire [31:0]                pt_ctrl_resp;
	wire                       pt_ctrl_resp_valid;
	wire                       pt_dma_req_valid;
	wire                       pt_dma_req_ready;
	wire [`PT_DMA_KIND_W-1:0]  pt_dma_req_kind;
	wire [31:0]                pt_dma_req_id;
	wire                       pt_m_dma_req_valid;
	wire                       pt_m_dma_req_ready;
	wire [31:0]                pt_m_dma_req_id;
	wire                       pt_m_dma_req_buf;
	wire [DMA_BEATS_W-1:0]     pt_m_dma_req_beats;
	wire                       pt_irq_unused;

	reg                        desc_valid_r [0:LUT_DEPTH-1];
	reg  [31:0]                desc_id_r [0:LUT_DEPTH-1];
	reg  [31:0]                desc_cmd_inst_r [0:LUT_DEPTH-1];
	reg  [EXT_ADDR_W-1:0]      desc_a_addr_r [0:LUT_DEPTH-1];
	reg  [EXT_ADDR_W-1:0]      desc_b_addr_r [0:LUT_DEPTH-1];
	reg  [EXT_ADDR_W-1:0]      desc_c_addr_r [0:LUT_DEPTH-1];
	reg  [EXT_ADDR_W-1:0]      desc_m_addr_r [0:LUT_DEPTH-1];

	reg                        cmd_overflow_r;
	reg                        desc_overflow_r;
	reg                        resp_overflow_r;
	reg                        desc_miss_r;

	reg                        push_found;
	reg                        push_free_found;
	reg  [DESC_AW-1:0]         push_found_idx;
	reg  [DESC_AW-1:0]         push_free_idx;
	reg                        rd_desc_found;
	reg  [DESC_AW-1:0]         rd_desc_idx;
	reg                        wr_desc_found;
	reg  [DESC_AW-1:0]         wr_desc_idx;
	reg                        accept_desc_found;
	reg  [DESC_AW-1:0]         accept_desc_idx;
	reg                        resp_desc_found;
	reg  [DESC_AW-1:0]         resp_desc_idx;
	reg                        wr_slot_valid_r;
	reg  [DESC_AW-1:0]         wr_slot_idx_r;
	reg  [31:0]                perf_cycle_counter_r;
	reg  [31:0]                perf_command_push_count_r;
	reg  [31:0]                perf_pt_accept_count_r;
	reg  [31:0]                perf_resp_enqueue_count_r;
	reg  [31:0]                perf_wr_dma_done_count_r;
	reg  [31:0]                perf_push_to_accept_cycles_r;
	reg  [31:0]                perf_accept_to_resp_cycles_r;
	reg  [31:0]                perf_resp_to_done_cycles_r;
	reg  [31:0]                push_cycle_fifo_r [0:CMD_FIFO_DEPTH-1];
	reg  [CMD_TRACK_AW-1:0]    push_cycle_head_r;
	reg  [CMD_TRACK_AW-1:0]    push_cycle_tail_r;
	reg  [CMD_TRACK_AW:0]      push_cycle_count_r;
	reg                        accept_cycle_valid_r [0:LUT_DEPTH-1];
	reg  [31:0]                accept_cycle_r [0:LUT_DEPTH-1];
	reg                        resp_cycle_valid_r [0:LUT_DEPTH-1];
	reg  [31:0]                resp_cycle_r [0:LUT_DEPTH-1];

	wire desc_push_commit = csr_desc_push_pulse && (push_found || push_free_found);
	wire cmd_push_fire = desc_push_commit && cmd_fifo_ready_in;
	wire cmd_fifo_clear = clear || csr_soft_clear_pulse;
	wire resp_fifo_clear = clear || csr_soft_clear_pulse;
	wire runtime_clear = clear || csr_soft_clear_pulse;
	wire resp_enqueue_fire = pt_ctrl_resp_valid && resp_fifo_ready_in;
	wire wr_desc_fire = wr_dma_desc_valid && wr_dma_desc_ready;
	wire pt_accept_fire = pt_ctrl_valid && pt_ctrl_ready;
	wire resp_is_load = resp_desc_found &&
		(desc_cmd_inst_r[resp_desc_idx][`PT_INST_OPCODE_H:`PT_INST_OPCODE_L] == `PT_OP_LOAD);
	wire retire_resp_slot = resp_enqueue_fire && resp_desc_found && (pt_ctrl_resp[31] || resp_is_load);
	wire retire_wr_slot = wr_slot_valid_r && (wr_dma_done || wr_dma_error);

	assign pt_ctrl_valid = cmd_fifo_valid_out;
	assign pt_ctrl_inst = cmd_fifo_data_out[63:32];
	assign pt_ctrl_id = cmd_fifo_data_out[31:0];
	assign cmd_fifo_pop_ready = pt_ctrl_ready;

	assign pt_dma_req_ready = rd_desc_found && !desc_miss_r && rd_dma_desc_ready;
	assign pt_m_dma_req_ready = wr_desc_found && !desc_miss_r && wr_dma_desc_ready;

	assign rd_dma_desc_valid = pt_dma_req_valid && rd_desc_found && !desc_miss_r;
	assign rd_dma_desc_addr = rd_desc_found ? (
		(pt_dma_req_kind == `PT_DMA_KIND_A) ? desc_a_addr_r[rd_desc_idx] :
		(pt_dma_req_kind == `PT_DMA_KIND_B) ? desc_b_addr_r[rd_desc_idx] :
		desc_c_addr_r[rd_desc_idx]
	) : {EXT_ADDR_W{1'b0}};
	assign rd_dma_desc_id = rd_dma_desc_valid ? pt_dma_req_id : 32'd0;
	assign rd_dma_desc_kind = rd_dma_desc_valid ? pt_dma_req_kind : {`PT_DMA_KIND_W{1'b0}};
	assign wr_dma_desc_valid = pt_m_dma_req_valid && wr_desc_found && !desc_miss_r;
	assign wr_dma_desc_addr = wr_desc_found ? desc_m_addr_r[wr_desc_idx] : {EXT_ADDR_W{1'b0}};
	assign wr_dma_desc_id = wr_dma_desc_valid ? pt_m_dma_req_id : 32'd0;
	assign wr_dma_desc_buf = wr_dma_desc_valid ? pt_m_dma_req_buf : 1'b0;
	assign wr_dma_desc_beats = wr_dma_desc_valid ? pt_m_dma_req_beats : {DMA_BEATS_W{1'b0}};

	assign irq = resp_fifo_valid_out || cmd_overflow_r || desc_overflow_r || resp_overflow_r || desc_miss_r;

	function [`PT_SIZE_W-1:0] calc_rd_dma_elems;
		input [31:0] cmd_inst;
		input [`PT_DMA_KIND_W-1:0] req_kind;
		reg [3:0] opcode;
		reg [3:0] m_tiles;
		reg [3:0] n_tiles;
		reg [3:0] k_tiles;
		reg [31:0] elems32;
		begin
			opcode = cmd_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
			m_tiles = cmd_inst[`PT_MATMUL_M_TILES_H:`PT_MATMUL_M_TILES_L];
			n_tiles = cmd_inst[`PT_MATMUL_N_TILES_H:`PT_MATMUL_N_TILES_L];
			k_tiles = cmd_inst[`PT_MATMUL_K_TILES_H:`PT_MATMUL_K_TILES_L];
			elems32 = 32'd0;
			case (opcode)
				`PT_OP_LOAD: begin
					if (req_kind == `PT_DMA_KIND_A) begin
						elems32 = {{(32-`PT_SIZE_W){1'b0}}, cmd_inst[`PT_LOAD_A_SIZE_H:`PT_LOAD_A_SIZE_L]};
					end else if (req_kind == `PT_DMA_KIND_B) begin
						elems32 = {{(32-`PT_SIZE_W){1'b0}}, cmd_inst[`PT_LOAD_B_SIZE_H:`PT_LOAD_B_SIZE_L]};
					end
				end
				`PT_OP_MATMUL: begin
					if (req_kind == `PT_DMA_KIND_A) begin
						elems32 = m_tiles * k_tiles * A_TILE_LEN;
					end else if (req_kind == `PT_DMA_KIND_B) begin
						elems32 = k_tiles * n_tiles * B_TILE_LEN;
					end
				end
				`PT_OP_MATADD: begin
					if (req_kind == `PT_DMA_KIND_C) begin
						elems32 = B_TILE_LEN;
					end
				end
				default: begin end
			endcase
			calc_rd_dma_elems = elems32[`PT_SIZE_W-1:0];
		end
	endfunction

	assign rd_dma_desc_elems = rd_desc_found ? calc_rd_dma_elems(desc_cmd_inst_r[rd_desc_idx], pt_dma_req_kind) : {`PT_SIZE_W{1'b0}};

	PT_DMA_AXIL_CSR #(
		.EXT_ADDR_W(EXT_ADDR_W),
		.CMD_FIFO_DEPTH(CMD_FIFO_DEPTH),
		.RESP_FIFO_DEPTH(RESP_FIFO_DEPTH)
	) u_axil_csr (
		.clk                    (clk),
		.rstn                   (rstn),
		.clear                  (runtime_clear),
		.s_axil_awaddr          (s_axil_awaddr),
		.s_axil_awvalid         (s_axil_awvalid),
		.s_axil_awready         (s_axil_awready),
		.s_axil_wdata           (s_axil_wdata),
		.s_axil_wstrb           (s_axil_wstrb),
		.s_axil_wvalid          (s_axil_wvalid),
		.s_axil_wready          (s_axil_wready),
		.s_axil_bresp           (s_axil_bresp),
		.s_axil_bvalid          (s_axil_bvalid),
		.s_axil_bready          (s_axil_bready),
		.s_axil_araddr          (s_axil_araddr),
		.s_axil_arvalid         (s_axil_arvalid),
		.s_axil_arready         (s_axil_arready),
		.s_axil_rdata           (s_axil_rdata),
		.s_axil_rresp           (s_axil_rresp),
		.s_axil_rvalid          (s_axil_rvalid),
		.s_axil_rready          (s_axil_rready),
		.status_cmd_fifo_not_full(cmd_fifo_ready_in),
		.status_resp_fifo_not_empty(resp_fifo_valid_out),
		.status_irq_active      (irq),
		.status_pt_ctrl_ready   (pt_ctrl_ready),
		.status_cmd_overflow    (cmd_overflow_r),
		.status_desc_overflow   (desc_overflow_r),
		.status_resp_overflow   (resp_overflow_r),
		.status_desc_miss       (desc_miss_r),
		.status_stream_align_error(1'b0),
		.resp_head              (resp_fifo_valid_out ? resp_fifo_data_out : 32'd0),
		.perf_command_push_count(perf_command_push_count_r),
		.perf_pt_accept_count   (perf_pt_accept_count_r),
		.perf_resp_enqueue_count(perf_resp_enqueue_count_r),
		.perf_wr_dma_done_count (perf_wr_dma_done_count_r),
		.perf_push_to_accept_cycles(perf_push_to_accept_cycles_r),
		.perf_accept_to_resp_cycles(perf_accept_to_resp_cycles_r),
		.perf_resp_to_done_cycles(perf_resp_to_done_cycles_r),
		.desc_push_pulse        (csr_desc_push_pulse),
		.resp_pop_pulse         (csr_resp_pop_pulse),
		.soft_clear_pulse       (csr_soft_clear_pulse),
		.clear_flags_pulse      (csr_clear_flags_pulse),
		.active_channel_mask_reg(),
		.cmd_inst_reg           (csr_cmd_inst),
		.cmd_id_reg             (csr_cmd_id),
		.a_addr_reg             (csr_a_addr),
		.b_addr_reg             (csr_b_addr),
		.c_addr_reg             (csr_c_addr),
		.m_addr_reg             (csr_m_addr)
	);

	sync_fifo #(
		.WIDTH(64),
		.DEPTH(CMD_FIFO_DEPTH)
	) u_cmd_fifo (
		.clk      (clk),
		.resetn   (rstn),
		.clear    (cmd_fifo_clear),
		.data_in  ({csr_cmd_inst, csr_cmd_id}),
		.valid_in (cmd_push_fire),
		.ready_in (cmd_fifo_ready_in),
		.data_out (cmd_fifo_data_out),
		.valid_out(cmd_fifo_valid_out),
		.ready_out(cmd_fifo_pop_ready)
	);

	sync_fifo #(
		.WIDTH(32),
		.DEPTH(RESP_FIFO_DEPTH)
	) u_resp_fifo (
		.clk      (clk),
		.resetn   (rstn),
		.clear    (resp_fifo_clear),
		.data_in  (pt_ctrl_resp),
		.valid_in (pt_ctrl_resp_valid && resp_fifo_ready_in),
		.ready_in (resp_fifo_ready_in),
		.data_out (resp_fifo_data_out),
		.valid_out(resp_fifo_valid_out),
		.ready_out(csr_resp_pop_pulse)
	);

	PT #(
		.DATA_WIDTH       (DATA_WIDTH),
		.GEMM_X_DIM       (GEMM_X_DIM),
		.GEMM_Y_DIM       (GEMM_Y_DIM),
		.EXT_ADDR_W       (EXT_ADDR_W),
		.DMA_BEATS_W      (DMA_BEATS_W),
		.LUT_DEPTH        (LUT_DEPTH),
		.A_BANK_DEPTH     (A_BANK_DEPTH),
		.B_BANK_DEPTH     (B_BANK_DEPTH),
		.M_BANK_DEPTH     (M_BANK_DEPTH),
		.A_LOAD_LANES     (A_LOAD_LANES),
		.B_LOAD_LANES     (B_LOAD_LANES),
		.M_WRITE_LANES    (M_WRITE_LANES),
		.M_EXPORT_LANES   (M_EXPORT_LANES),
		.M_PHYSICAL_COPIES(M_PHYSICAL_COPIES)
	) u_pt (
		.clk            (clk),
		.rstn           (rstn),
		.clear          (clear),
		.soft_clear     (csr_soft_clear_pulse),
		.s_axis_tvalid  (s_axis_tvalid),
		.s_axis_tready  (s_axis_tready),
		.s_axis_tdata   (s_axis_tdata),
		.s_axis_tstrb   ({LOAD_STREAM_STRB_W{1'b0}}),
		.s_axis_tlast   (1'b0),
		.s_axis_tkeep   (1'b0),
		.s_axis_tid     (1'b0),
		.s_axis_tdest   (1'b0),
		.s_axis_tuser   (s_axis_tuser),
		.m_axis_tvalid  (m_axis_tvalid),
		.m_axis_tready  (m_axis_tready),
		.m_axis_tdata   (m_axis_tdata),
		.m_axis_tstrb   (m_axis_tstrb),
		.m_axis_tlast   (m_axis_tlast),
		.m_axis_tkeep   (m_axis_tkeep),
		.m_axis_tid     (m_axis_tid),
		.m_axis_tdest   (m_axis_tdest),
		.m_axis_tuser   (m_axis_tuser),
		.ctrl_valid     (pt_ctrl_valid),
		.ctrl_ready     (pt_ctrl_ready),
		.ctrl_inst      (pt_ctrl_inst),
		.ctrl_id        (pt_ctrl_id),
		.ctrl_resp      (pt_ctrl_resp),
		.ctrl_resp_valid(pt_ctrl_resp_valid),
		.dma_req_valid  (pt_dma_req_valid),
		.dma_req_ready  (pt_dma_req_ready),
		.dma_req_kind   (pt_dma_req_kind),
		.dma_req_id     (pt_dma_req_id),
		.dma_done       (1'b0),
		.dma_error      (rd_dma_error),
		.m_dma_req_valid(pt_m_dma_req_valid),
		.m_dma_req_ready(pt_m_dma_req_ready),
		.m_dma_req_id   (pt_m_dma_req_id),
		.m_dma_req_buf  (pt_m_dma_req_buf),
		.m_dma_req_beats(pt_m_dma_req_beats),
		.m_dma_done     (wr_dma_done),
		.m_dma_error    (wr_dma_error),
		.irq            (pt_irq_unused)
	);

	integer di;
	always @(*) begin
		push_found = 1'b0;
		push_free_found = 1'b0;
		push_found_idx = {DESC_AW{1'b0}};
		push_free_idx = {DESC_AW{1'b0}};
		rd_desc_found = 1'b0;
		rd_desc_idx = {DESC_AW{1'b0}};
		wr_desc_found = 1'b0;
		wr_desc_idx = {DESC_AW{1'b0}};
		accept_desc_found = 1'b0;
		accept_desc_idx = {DESC_AW{1'b0}};
		resp_desc_found = 1'b0;
		resp_desc_idx = {DESC_AW{1'b0}};
		for (di = 0; di < LUT_DEPTH; di = di + 1) begin
			if (!push_found && desc_valid_r[di] && (desc_id_r[di] == csr_cmd_id)) begin
				push_found = 1'b1;
				push_found_idx = di[DESC_AW-1:0];
			end
			if (!push_free_found && !desc_valid_r[di]) begin
				push_free_found = 1'b1;
				push_free_idx = di[DESC_AW-1:0];
			end
			if (!rd_desc_found && desc_valid_r[di] && (desc_id_r[di] == pt_dma_req_id)) begin
				rd_desc_found = 1'b1;
				rd_desc_idx = di[DESC_AW-1:0];
			end
			if (!wr_desc_found && desc_valid_r[di] && (desc_id_r[di] == pt_m_dma_req_id)) begin
				wr_desc_found = 1'b1;
				wr_desc_idx = di[DESC_AW-1:0];
			end
			if (!accept_desc_found && desc_valid_r[di] && (desc_id_r[di] == pt_ctrl_id)) begin
				accept_desc_found = 1'b1;
				accept_desc_idx = di[DESC_AW-1:0];
			end
			if (!resp_desc_found && desc_valid_r[di] && (desc_id_r[di][29:0] == pt_ctrl_resp[29:0])) begin
				resp_desc_found = 1'b1;
				resp_desc_idx = di[DESC_AW-1:0];
			end
		end
	end

	integer li;
	integer qi;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cmd_overflow_r  <= 1'b0;
			desc_overflow_r <= 1'b0;
			resp_overflow_r <= 1'b0;
			desc_miss_r     <= 1'b0;
			wr_slot_valid_r <= 1'b0;
			wr_slot_idx_r   <= {DESC_AW{1'b0}};
			perf_cycle_counter_r <= 32'd0;
			perf_command_push_count_r <= 32'd0;
			perf_pt_accept_count_r <= 32'd0;
			perf_resp_enqueue_count_r <= 32'd0;
			perf_wr_dma_done_count_r <= 32'd0;
			perf_push_to_accept_cycles_r <= 32'd0;
			perf_accept_to_resp_cycles_r <= 32'd0;
			perf_resp_to_done_cycles_r <= 32'd0;
			push_cycle_head_r <= {CMD_TRACK_AW{1'b0}};
			push_cycle_tail_r <= {CMD_TRACK_AW{1'b0}};
			push_cycle_count_r <= {(CMD_TRACK_AW+1){1'b0}};
			for (li = 0; li < LUT_DEPTH; li = li + 1) begin
				desc_valid_r[li]    <= 1'b0;
				desc_id_r[li]       <= 32'd0;
				desc_cmd_inst_r[li] <= 32'd0;
				desc_a_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				desc_b_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				desc_c_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				desc_m_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				accept_cycle_valid_r[li] <= 1'b0;
				accept_cycle_r[li] <= 32'd0;
				resp_cycle_valid_r[li] <= 1'b0;
				resp_cycle_r[li] <= 32'd0;
			end
			for (qi = 0; qi < CMD_FIFO_DEPTH; qi = qi + 1) begin
				push_cycle_fifo_r[qi] <= 32'd0;
			end
		end else if (runtime_clear) begin
			cmd_overflow_r  <= 1'b0;
			desc_overflow_r <= 1'b0;
			resp_overflow_r <= 1'b0;
			desc_miss_r     <= 1'b0;
			wr_slot_valid_r <= 1'b0;
			wr_slot_idx_r   <= {DESC_AW{1'b0}};
			perf_cycle_counter_r <= 32'd0;
			perf_command_push_count_r <= 32'd0;
			perf_pt_accept_count_r <= 32'd0;
			perf_resp_enqueue_count_r <= 32'd0;
			perf_wr_dma_done_count_r <= 32'd0;
			perf_push_to_accept_cycles_r <= 32'd0;
			perf_accept_to_resp_cycles_r <= 32'd0;
			perf_resp_to_done_cycles_r <= 32'd0;
			push_cycle_head_r <= {CMD_TRACK_AW{1'b0}};
			push_cycle_tail_r <= {CMD_TRACK_AW{1'b0}};
			push_cycle_count_r <= {(CMD_TRACK_AW+1){1'b0}};
			for (li = 0; li < LUT_DEPTH; li = li + 1) begin
				desc_valid_r[li]    <= 1'b0;
				desc_id_r[li]       <= 32'd0;
				desc_cmd_inst_r[li] <= 32'd0;
				desc_a_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				desc_b_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				desc_c_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				desc_m_addr_r[li]   <= {EXT_ADDR_W{1'b0}};
				accept_cycle_valid_r[li] <= 1'b0;
				accept_cycle_r[li] <= 32'd0;
				resp_cycle_valid_r[li] <= 1'b0;
				resp_cycle_r[li] <= 32'd0;
			end
			for (qi = 0; qi < CMD_FIFO_DEPTH; qi = qi + 1) begin
				push_cycle_fifo_r[qi] <= 32'd0;
			end
		end else begin
			perf_cycle_counter_r <= perf_cycle_counter_r + 1'b1;

			if (csr_clear_flags_pulse) begin
				cmd_overflow_r  <= 1'b0;
				desc_overflow_r <= 1'b0;
				resp_overflow_r <= 1'b0;
			end

			if (cmd_push_fire) begin
				perf_command_push_count_r <= perf_command_push_count_r + 1'b1;
			end
			if (pt_accept_fire) begin
				perf_pt_accept_count_r <= perf_pt_accept_count_r + 1'b1;
			end
			if (resp_enqueue_fire) begin
				perf_resp_enqueue_count_r <= perf_resp_enqueue_count_r + 1'b1;
			end
			if (wr_dma_done) begin
				perf_wr_dma_done_count_r <= perf_wr_dma_done_count_r + 1'b1;
			end

			if (cmd_push_fire && pt_accept_fire) begin
				if (push_cycle_count_r != 0) begin
					perf_push_to_accept_cycles_r <= perf_push_to_accept_cycles_r + (perf_cycle_counter_r - push_cycle_fifo_r[push_cycle_head_r]);
					push_cycle_fifo_r[push_cycle_tail_r] <= perf_cycle_counter_r;
					push_cycle_head_r <= push_cycle_head_r + 1'b1;
					push_cycle_tail_r <= push_cycle_tail_r + 1'b1;
				end
			end else if (cmd_push_fire) begin
				push_cycle_fifo_r[push_cycle_tail_r] <= perf_cycle_counter_r;
				push_cycle_tail_r <= push_cycle_tail_r + 1'b1;
				push_cycle_count_r <= push_cycle_count_r + 1'b1;
			end else if (pt_accept_fire) begin
				if (push_cycle_count_r != 0) begin
					perf_push_to_accept_cycles_r <= perf_push_to_accept_cycles_r + (perf_cycle_counter_r - push_cycle_fifo_r[push_cycle_head_r]);
					push_cycle_head_r <= push_cycle_head_r + 1'b1;
					push_cycle_count_r <= push_cycle_count_r - 1'b1;
				end
			end

			if (pt_accept_fire && accept_desc_found) begin
				accept_cycle_valid_r[accept_desc_idx] <= 1'b1;
				accept_cycle_r[accept_desc_idx] <= perf_cycle_counter_r;
			end

			if (resp_enqueue_fire && resp_desc_found) begin
				if (accept_cycle_valid_r[resp_desc_idx]) begin
					perf_accept_to_resp_cycles_r <= perf_accept_to_resp_cycles_r + (perf_cycle_counter_r - accept_cycle_r[resp_desc_idx]);
				end
				accept_cycle_valid_r[resp_desc_idx] <= 1'b0;
				if (!resp_is_load && !pt_ctrl_resp[31]) begin
					resp_cycle_valid_r[resp_desc_idx] <= 1'b1;
					resp_cycle_r[resp_desc_idx] <= perf_cycle_counter_r;
				end else begin
					resp_cycle_valid_r[resp_desc_idx] <= 1'b0;
				end
			end

			if (wr_dma_done && wr_slot_valid_r && resp_cycle_valid_r[wr_slot_idx_r]) begin
				perf_resp_to_done_cycles_r <= perf_resp_to_done_cycles_r + (perf_cycle_counter_r - resp_cycle_r[wr_slot_idx_r]);
			end

			if (wr_desc_fire) begin
				wr_slot_valid_r <= wr_desc_found;
				wr_slot_idx_r   <= wr_desc_idx;
			end

			if (retire_resp_slot) begin
				desc_valid_r[resp_desc_idx] <= 1'b0;
				accept_cycle_valid_r[resp_desc_idx] <= 1'b0;
				resp_cycle_valid_r[resp_desc_idx] <= 1'b0;
			end

			if (retire_wr_slot) begin
				desc_valid_r[wr_slot_idx_r] <= 1'b0;
				accept_cycle_valid_r[wr_slot_idx_r] <= 1'b0;
				resp_cycle_valid_r[wr_slot_idx_r] <= 1'b0;
				wr_slot_valid_r <= 1'b0;
			end

			if (csr_desc_push_pulse) begin
				if (push_found) begin
					desc_cmd_inst_r[push_found_idx] <= csr_cmd_inst;
					desc_a_addr_r[push_found_idx]   <= csr_a_addr;
					desc_b_addr_r[push_found_idx]   <= csr_b_addr;
					desc_c_addr_r[push_found_idx]   <= csr_c_addr;
					desc_m_addr_r[push_found_idx]   <= csr_m_addr;
				end else if (push_free_found) begin
					desc_valid_r[push_free_idx]    <= 1'b1;
					desc_id_r[push_free_idx]       <= csr_cmd_id;
					desc_cmd_inst_r[push_free_idx] <= csr_cmd_inst;
					desc_a_addr_r[push_free_idx]   <= csr_a_addr;
					desc_b_addr_r[push_free_idx]   <= csr_b_addr;
					desc_c_addr_r[push_free_idx]   <= csr_c_addr;
					desc_m_addr_r[push_free_idx]   <= csr_m_addr;
				end else begin
					desc_overflow_r <= 1'b1;
				end

				if (desc_push_commit && !cmd_fifo_ready_in) begin
					cmd_overflow_r <= 1'b1;
				end
			end

			if (pt_ctrl_resp_valid && !resp_fifo_ready_in) begin
				resp_overflow_r <= 1'b1;
			end

			if ((pt_dma_req_valid && !rd_desc_found) || (pt_m_dma_req_valid && !wr_desc_found)) begin
				desc_miss_r <= 1'b1;
			end
		end
	end

endmodule
