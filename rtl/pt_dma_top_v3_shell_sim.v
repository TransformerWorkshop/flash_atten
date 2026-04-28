`include "param.vh"

module PT_DMA_TOP_V3_SHELL_SIM #(
	parameter DATA_WIDTH   = 32,
	parameter WORD_WIDTH   = 32,
	parameter ELEM_WIDTH   = 8,
	parameter PACK_LANES   = 4,
	parameter ACC_WIDTH    = 32,
	parameter GEMM_X_DIM   = 16,
	parameter GEMM_Y_DIM   = 16,
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
	parameter STREAM_CHANNELS = 1,
	parameter S_AXIS_CHANNEL_WIDTH = 128,
	parameter M_AXIS_CHANNEL_WIDTH = 128,
	parameter RESP_FIFO_DEPTH = 4,
	parameter MAX_PENDING_ENTRIES = 16,
	parameter MAX_RESIDENT_ENTRIES = 16,
	parameter MAX_ENTRY_WORDS = 1024,
	parameter MAX_ACC_WORDS = 1024
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
	input  wire                       s_shell_axis_tvalid,
	output wire                       s_shell_axis_tready,
	input  wire [127:0]               s_shell_axis_tdata,
	input  wire [15:0]                s_shell_axis_tstrb,
	input  wire                       s_shell_axis_tlast,
	input  wire                       s_shell_axis_tkeep,
	output wire                       m_shell_axis_tvalid,
	input  wire                       m_shell_axis_tready,
	output wire [127:0]               m_shell_axis_tdata,
	output wire [15:0]                m_shell_axis_tstrb,
	output wire                       m_shell_axis_tlast,
	output wire                       m_shell_axis_tkeep,
	output wire                       irq
);

	localparam integer LOAD_STREAM_LANES = (A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES;
	localparam integer LOAD_STREAM_STRB_W = LOAD_STREAM_LANES * DATA_WIDTH / 8;
	localparam integer SHELL_STREAM_LANES = 128 / DATA_WIDTH;
	localparam integer PACKED_WORDS_PER_ROW = (PACK_LANES <= 1) ? GEMM_Y_DIM : (GEMM_Y_DIM / PACK_LANES);
	localparam [1:0] KIND_NONE = 2'd0;
	localparam [1:0] KIND_A = 2'd1;
	localparam [1:0] KIND_B = 2'd2;
	localparam [1:0] KIND_C = 2'd3;
	localparam [3:0] CMD_KIND_IDLE = 4'd0;
	localparam [3:0] CMD_KIND_PT = 4'd1;
	localparam [3:0] CMD_KIND_MATMUL = 4'd2;
	localparam [3:0] CMD_KIND_MATADD = 4'd3;

	wire                       csr_desc_push_pulse;
	wire                       csr_resp_pop_pulse;
	wire                       csr_soft_clear_pulse;
	wire                       csr_clear_flags_pulse;
	wire                       csr_ingress_push_pulse;
	wire                       csr_out_meta_pop_pulse;
	wire [31:0]                csr_cmd_inst;
	wire [31:0]                csr_cmd_id;
	wire [EXT_ADDR_W-1:0]      csr_a_addr;
	wire [EXT_ADDR_W-1:0]      csr_b_addr;
	wire [EXT_ADDR_W-1:0]      csr_c_addr;
	wire [EXT_ADDR_W-1:0]      csr_m_addr;
	wire [31:0]                shell_mode_reg;
	wire [31:0]                ingress_kind_reg;
	wire [31:0]                ingress_ctrl_id_reg;
	wire [31:0]                ingress_tile_info0_reg;
	wire [31:0]                ingress_tile_info1_reg;
	wire [31:0]                ingress_word_count_reg;

	reg  [31:0]                resp_fifo_r [0:RESP_FIFO_DEPTH-1];
	reg  [1:0]                 resp_head_r;
	reg  [1:0]                 resp_tail_r;
	reg  [2:0]                 resp_count_r;

	reg                        out_meta_valid_r;
	reg  [31:0]                out_meta_head0_r;
	reg  [31:0]                out_meta_head1_r;
	reg  [31:0]                out_meta_head2_r;

	reg                        scratchpad_miss_sticky_r;
	reg                        shell_error_sticky_r;

	reg                        pending_valid_r [0:MAX_PENDING_ENTRIES-1];
	reg  [1:0]                 pending_kind_r [0:MAX_PENDING_ENTRIES-1];
	reg  [31:0]                pending_ctrl_id_r [0:MAX_PENDING_ENTRIES-1];
	reg  [7:0]                 pending_m_tile_off_r [0:MAX_PENDING_ENTRIES-1];
	reg  [7:0]                 pending_n_tile_off_r [0:MAX_PENDING_ENTRIES-1];
	reg  [7:0]                 pending_k_tile_off_r [0:MAX_PENDING_ENTRIES-1];
	reg  [7:0]                 pending_m_tiles_r [0:MAX_PENDING_ENTRIES-1];
	reg  [7:0]                 pending_n_tiles_r [0:MAX_PENDING_ENTRIES-1];
	reg  [7:0]                 pending_k_tiles_r [0:MAX_PENDING_ENTRIES-1];
	reg  [15:0]                pending_word_count_r [0:MAX_PENDING_ENTRIES-1];
	reg  [31:0]                pending_data_r [0:(MAX_PENDING_ENTRIES * MAX_ENTRY_WORDS)-1];

	reg                        resident_valid_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [1:0]                 resident_kind_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [31:0]                resident_ctrl_id_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [7:0]                 resident_m_tile_off_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [7:0]                 resident_n_tile_off_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [7:0]                 resident_k_tile_off_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [7:0]                 resident_m_tiles_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [7:0]                 resident_n_tiles_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [7:0]                 resident_k_tiles_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [15:0]                resident_word_count_r [0:MAX_RESIDENT_ENTRIES-1];
	reg  [31:0]                resident_data_r [0:(MAX_RESIDENT_ENTRIES * MAX_ENTRY_WORDS)-1];

	reg                        acc_valid_r [0:1];
	reg  [31:0]                acc_ctrl_id_r [0:1];
	reg  [7:0]                 acc_m_tile_off_r [0:1];
	reg  [7:0]                 acc_n_tile_off_r [0:1];
	reg  [7:0]                 acc_m_tiles_r [0:1];
	reg  [7:0]                 acc_n_tiles_r [0:1];
	reg  [15:0]                acc_word_count_r [0:1];
	reg  [31:0]                acc_data_r [0:(2 * MAX_ACC_WORDS)-1];
	reg                        next_acc_slot_r;
	reg                        qcfg_wait_payload_r;
	reg  [31:0]                qcfg_ctrl_id_r;

	reg                        ingress_active_r;
	reg  [1:0]                 ingress_slot_idx_r;
	reg  [1:0]                 ingress_kind_r;
	reg  [31:0]                ingress_ctrl_id_r;
	reg  [7:0]                 ingress_m_tile_off_r;
	reg  [7:0]                 ingress_n_tile_off_r;
	reg  [7:0]                 ingress_k_tile_off_r;
	reg  [7:0]                 ingress_m_tiles_r;
	reg  [7:0]                 ingress_n_tiles_r;
	reg  [7:0]                 ingress_k_tiles_r;
	reg  [15:0]                ingress_word_count_r;
	reg  [15:0]                ingress_recv_words_r;

	reg  [3:0]                 active_cmd_kind_r;
	reg                        command_busy_r;
	reg  [31:0]                active_cmd_id_r;
	reg  [31:0]                active_cmd_inst_r;
	reg  [3:0]                 active_m_tiles_r;
	reg  [3:0]                 active_n_tiles_r;
	reg  [3:0]                 active_k_tiles_r;
	reg  [7:0]                 active_m_tile_off_r;
	reg  [7:0]                 active_n_tile_off_r;
	reg  [1:0]                 active_acc_slot_r;
	reg  [15:0]                active_result_word_count_r;
	reg                        active_wait_pt_resp_r;
	reg                        active_got_pt_resp_r;
	reg  [31:0]                active_pt_resp_word_r;
	reg                        active_wait_export_r;
	reg                        active_got_export_r;
	reg                        active_forward_m_r;
	reg                        active_emit_intermediate_r;
	reg  [15:0]                active_pt_beats_expected_r;

	reg                        pt_ctrl_valid_r;
	reg  [31:0]                pt_ctrl_inst_r;
	reg  [31:0]                pt_ctrl_id_r;
	wire [31:0]                pt_ctrl_resp;
	wire                       pt_ctrl_resp_valid;
	wire                       pt_ctrl_ready;

	wire                       pt_dma_req_valid;
	wire                       pt_dma_req_ready;
	wire [`PT_DMA_KIND_W-1:0]  pt_dma_req_kind;
	wire [31:0]                pt_dma_req_id;
	reg                        pt_dma_done_r;
	reg                        pt_dma_error_r;
	wire                       pt_m_dma_req_valid;
	wire                       pt_m_dma_req_ready;
	wire [31:0]                pt_m_dma_req_id;
	wire                       pt_m_dma_req_buf;
	wire [DMA_BEATS_W-1:0]     pt_m_dma_req_beats;
	reg                        pt_m_dma_done_r;
	reg                        pt_m_dma_error_r;

	reg                        load_busy_r;
	reg  [1:0]                 load_kind_r;
	reg  [4:0]                 load_resident_idx_r;
	reg  [15:0]                load_word_idx_r;
	reg  [15:0]                load_word_count_r;
	reg  [127:0]               load_beat_data_words_r [0:3];
	wire                       pt_s_axis_tvalid;
	wire                       pt_s_axis_tready;
	wire [LOAD_STREAM_LANES*DATA_WIDTH-1:0] pt_s_axis_tdata;
	wire [LOAD_STREAM_STRB_W-1:0] pt_s_axis_tstrb;
	wire [1:0]                 pt_s_axis_tuser;

	reg                        export_busy_r;
	reg  [15:0]                export_word_idx_r;
	reg  [15:0]                export_word_count_r;
	reg  [15:0]                export_beats_seen_r;
	reg                        emit_active_r;
	reg  [1:0]                 emit_source_kind_r;
	reg  [15:0]                emit_word_idx_r;
	reg  [15:0]                emit_word_count_r;
	reg  [31:0]                temp_result_data_r [0:MAX_ACC_WORDS-1];
	reg  [31:0]                emit_ctrl_id_r;
	reg  [7:0]                 emit_m_tile_off_r;
	reg  [7:0]                 emit_n_tile_off_r;
	reg  [7:0]                 emit_m_tiles_r;
	reg  [7:0]                 emit_n_tiles_r;
	reg                        emit_is_final_r;

	wire [M_EXPORT_LANES*DATA_WIDTH-1:0] pt_m_axis_tdata;
	wire [M_EXPORT_LANES*DATA_WIDTH/8-1:0] pt_m_axis_tstrb;
	wire                       pt_m_axis_tvalid;
	wire                       pt_m_axis_tready;
	wire                       pt_m_axis_tlast;
	wire                       pt_irq_unused;

	wire shell_forward_m_enable = shell_mode_reg[0];
	wire shell_emit_intermediate_enable = shell_mode_reg[1];
	wire status_cmd_slot_ready = !command_busy_r;
	wire status_resp_not_empty = (resp_count_r != 0);
	wire status_irq_active = status_resp_not_empty || scratchpad_miss_sticky_r || shell_error_sticky_r;
	wire [31:0] shell_status_word = {
		25'd0,
		shell_error_sticky_r,
		scratchpad_miss_sticky_r,
		out_meta_valid_r,
		status_resp_not_empty,
		command_busy_r,
		1'b0,
		ingress_active_r
	};

	function [31:0] pack_resp_local;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp_local = {err, m_buf, id[29:0]};
		end
	endfunction

	function [3:0] decode_tile_count;
		input [1:0] code;
		begin
			case (code)
				2'b00: decode_tile_count = `PT_TILES_1;
				2'b01: decode_tile_count = `PT_TILES_2;
				2'b10: decode_tile_count = `PT_TILES_4;
				default: decode_tile_count = 4'd0;
			endcase
		end
	endfunction

	function [15:0] calc_output_word_count;
		input [3:0] m_tiles;
		input [3:0] n_tiles;
		reg [31:0] total_words;
		begin
			total_words = (m_tiles * GEMM_X_DIM) * ((n_tiles * GEMM_Y_DIM) / PACK_LANES);
			calc_output_word_count = total_words[15:0];
		end
	endfunction

	function [31:0] sat_add_packed_word;
		input [31:0] lhs_word;
		input [31:0] rhs_word;
		integer li;
		reg signed [8:0] lhs_lane;
		reg signed [8:0] rhs_lane;
		reg signed [9:0] sum_lane;
		reg signed [7:0] sat_lane;
		begin
			sat_add_packed_word = 32'd0;
			for (li = 0; li < 4; li = li + 1) begin
				lhs_lane = $signed({lhs_word[(li * 8) + 7], lhs_word[(li * 8) +: 8]});
				rhs_lane = $signed({rhs_word[(li * 8) + 7], rhs_word[(li * 8) +: 8]});
				sum_lane = lhs_lane + rhs_lane;
				if (sum_lane > 10'sd127) begin
					sat_lane = 8'sd127;
				end else if (sum_lane < -10'sd128) begin
					sat_lane = -8'sd128;
				end else begin
					sat_lane = sum_lane[7:0];
				end
				sat_add_packed_word[(li * 8) +: 8] = sat_lane[7:0];
			end
		end
	endfunction

	task push_resp_task;
		input [31:0] word;
		begin
			if (resp_count_r < RESP_FIFO_DEPTH) begin
				resp_fifo_r[resp_tail_r] <= word;
				resp_tail_r <= resp_tail_r + 1'b1;
				resp_count_r <= resp_count_r + 1'b1;
			end else begin
				shell_error_sticky_r <= 1'b1;
			end
		end
	endtask

	task find_free_pending_task;
		output integer found_idx;
		integer i;
		begin
			found_idx = -1;
			for (i = 0; i < MAX_PENDING_ENTRIES; i = i + 1) begin
				if (!pending_valid_r[i] && (found_idx < 0)) begin
					found_idx = i;
				end
			end
		end
	endtask

	task find_pending_task;
		input [31:0] ctrl_id;
		input [1:0]  kind;
		input [15:0] word_count;
		input [7:0]  m_tiles;
		input [7:0]  n_tiles;
		input [7:0]  k_tiles;
		output integer found_idx;
		integer i;
		begin
			found_idx = -1;
			for (i = 0; i < MAX_PENDING_ENTRIES; i = i + 1) begin
				if (
					pending_valid_r[i]
					&& (pending_ctrl_id_r[i] == ctrl_id)
					&& (pending_kind_r[i] == kind)
					&& ((word_count == 16'd0) || (pending_word_count_r[i] == word_count))
					&& (pending_m_tiles_r[i] == m_tiles)
					&& (pending_n_tiles_r[i] == n_tiles)
					&& (pending_k_tiles_r[i] == k_tiles)
					&& (found_idx < 0)
				) begin
					found_idx = i;
				end
			end
		end
	endtask

	task find_resident_task;
		input [31:0] ctrl_id;
		input [1:0]  kind;
		output integer found_idx;
		integer i;
		begin
			found_idx = -1;
			for (i = 0; i < MAX_RESIDENT_ENTRIES; i = i + 1) begin
				if (resident_valid_r[i] && (resident_ctrl_id_r[i] == ctrl_id) && (resident_kind_r[i] == kind) && (found_idx < 0)) begin
					found_idx = i;
				end
			end
		end
	endtask

	task find_free_resident_task;
		output integer found_idx;
		integer i;
		begin
			found_idx = -1;
			for (i = 0; i < MAX_RESIDENT_ENTRIES; i = i + 1) begin
				if (!resident_valid_r[i] && (found_idx < 0)) begin
					found_idx = i;
				end
			end
		end
	endtask

	task find_acc_match_task;
		input [31:0] ctrl_id;
		input [7:0]  m_tile_off;
		input [7:0]  n_tile_off;
		input [7:0]  m_tiles;
		input [7:0]  n_tiles;
		output integer found_idx;
		integer i;
		begin
			found_idx = -1;
			for (i = 0; i < 2; i = i + 1) begin
				if (
					acc_valid_r[i]
					&& (acc_ctrl_id_r[i] == ctrl_id)
					&& (acc_m_tile_off_r[i] == m_tile_off)
					&& (acc_n_tile_off_r[i] == n_tile_off)
					&& (acc_m_tiles_r[i] == m_tiles)
					&& (acc_n_tiles_r[i] == n_tiles)
					&& (found_idx < 0)
				) begin
					found_idx = i;
				end
			end
		end
	endtask

	task queue_emit_from_acc_task;
		input integer acc_idx;
		input [31:0] ctrl_id;
		input final_flag;
		begin
			if (!emit_active_r) begin
				emit_active_r <= 1'b1;
				emit_source_kind_r <= acc_idx[1:0];
				emit_word_idx_r <= 16'd0;
				emit_word_count_r <= acc_word_count_r[acc_idx];
				emit_ctrl_id_r <= ctrl_id;
				emit_m_tile_off_r <= acc_m_tile_off_r[acc_idx];
				emit_n_tile_off_r <= acc_n_tile_off_r[acc_idx];
				emit_m_tiles_r <= acc_m_tiles_r[acc_idx];
				emit_n_tiles_r <= acc_n_tiles_r[acc_idx];
				emit_is_final_r <= final_flag;
				out_meta_valid_r <= 1'b1;
				out_meta_head0_r <= ctrl_id;
				out_meta_head1_r <= {7'd0, final_flag, acc_m_tile_off_r[acc_idx], acc_n_tile_off_r[acc_idx], 8'd0};
				out_meta_head2_r <= {acc_word_count_r[acc_idx], acc_n_tiles_r[acc_idx], acc_m_tiles_r[acc_idx]};
			end else begin
				shell_error_sticky_r <= 1'b1;
			end
		end
	endtask

	task queue_emit_from_temp_task;
		input [31:0] ctrl_id;
		input [15:0] word_count;
		input [7:0]  m_tile_off;
		input [7:0]  n_tile_off;
		input [7:0]  m_tiles;
		input [7:0]  n_tiles;
		input final_flag;
		begin
			if (!emit_active_r) begin
				emit_active_r <= 1'b1;
				emit_source_kind_r <= 2'd3;
				emit_word_idx_r <= 16'd0;
				emit_word_count_r <= word_count;
				emit_ctrl_id_r <= ctrl_id;
				emit_m_tile_off_r <= m_tile_off;
				emit_n_tile_off_r <= n_tile_off;
				emit_m_tiles_r <= m_tiles;
				emit_n_tiles_r <= n_tiles;
				emit_is_final_r <= final_flag;
				out_meta_valid_r <= 1'b1;
				out_meta_head0_r <= ctrl_id;
				out_meta_head1_r <= {7'd0, final_flag, m_tile_off, n_tile_off, 8'd0};
				out_meta_head2_r <= {word_count, n_tiles, m_tiles};
			end else begin
				shell_error_sticky_r <= 1'b1;
			end
		end
	endtask

	wire [127:0] emit_data_word_pack =
		{(emit_source_kind_r == 2'd3) ? temp_result_data_r[emit_word_idx_r + 3] : acc_data_r[(emit_source_kind_r * MAX_ACC_WORDS) + emit_word_idx_r + 3],
		 (emit_source_kind_r == 2'd3) ? temp_result_data_r[emit_word_idx_r + 2] : acc_data_r[(emit_source_kind_r * MAX_ACC_WORDS) + emit_word_idx_r + 2],
		 (emit_source_kind_r == 2'd3) ? temp_result_data_r[emit_word_idx_r + 1] : acc_data_r[(emit_source_kind_r * MAX_ACC_WORDS) + emit_word_idx_r + 1],
		 (emit_source_kind_r == 2'd3) ? temp_result_data_r[emit_word_idx_r + 0] : acc_data_r[(emit_source_kind_r * MAX_ACC_WORDS) + emit_word_idx_r + 0]};

	reg [15:0] emit_strb_r;
	integer calc_i;
	always @(*) begin
		emit_strb_r = 16'd0;
		for (calc_i = 0; calc_i < SHELL_STREAM_LANES; calc_i = calc_i + 1) begin
			if ((emit_word_idx_r + calc_i) < emit_word_count_r) begin
				emit_strb_r[(calc_i * 4) +: 4] = 4'hF;
			end
		end
	end

	assign m_shell_axis_tvalid = emit_active_r;
	assign m_shell_axis_tdata  = emit_data_word_pack;
	assign m_shell_axis_tstrb  = emit_strb_r;
	assign m_shell_axis_tlast  = emit_active_r && ((emit_word_idx_r + SHELL_STREAM_LANES) >= emit_word_count_r);
	assign m_shell_axis_tkeep  = 1'b1;
	assign irq = status_irq_active;

	assign s_shell_axis_tready = ingress_active_r;

	reg [LOAD_STREAM_LANES*DATA_WIDTH-1:0] load_stream_data_r;
	integer load_lane_i;
	always @(*) begin
		load_stream_data_r = {LOAD_STREAM_LANES*DATA_WIDTH{1'b0}};
		for (load_lane_i = 0; load_lane_i < LOAD_STREAM_LANES; load_lane_i = load_lane_i + 1) begin
			if ((load_word_idx_r + load_lane_i) < load_word_count_r) begin
				load_stream_data_r[(load_lane_i * DATA_WIDTH) +: DATA_WIDTH] =
					resident_data_r[(load_resident_idx_r * MAX_ENTRY_WORDS) + load_word_idx_r + load_lane_i];
			end
		end
	end

	assign pt_s_axis_tvalid = load_busy_r;
	assign pt_s_axis_tdata  = load_stream_data_r;
	assign pt_s_axis_tstrb  = {LOAD_STREAM_STRB_W{1'b1}};
	assign pt_s_axis_tuser  = (load_kind_r == KIND_A) ? `PT_STREAM_KIND_A :
	                         (load_kind_r == KIND_B) ? `PT_STREAM_KIND_B :
	                         `PT_STREAM_KIND_C;

	assign pt_dma_req_ready = command_busy_r && (active_cmd_kind_r == CMD_KIND_MATMUL) && !load_busy_r;
	assign pt_m_dma_req_ready = command_busy_r && (active_cmd_kind_r == CMD_KIND_MATMUL) && !export_busy_r;
	assign pt_m_axis_tready = export_busy_r;

	PT_SHELL_AXIL_CSR_SIM #(
		.AXIL_ADDR_W(8),
		.AXIL_DATA_W(32),
		.EXT_ADDR_W(EXT_ADDR_W)
	) u_csr (
		.clk(clk),
		.rstn(rstn),
		.clear(clear),
		.s_axil_awaddr(s_axil_awaddr),
		.s_axil_awvalid(s_axil_awvalid),
		.s_axil_awready(s_axil_awready),
		.s_axil_wdata(s_axil_wdata),
		.s_axil_wstrb(s_axil_wstrb),
		.s_axil_wvalid(s_axil_wvalid),
		.s_axil_wready(s_axil_wready),
		.s_axil_bresp(s_axil_bresp),
		.s_axil_bvalid(s_axil_bvalid),
		.s_axil_bready(s_axil_bready),
		.s_axil_araddr(s_axil_araddr),
		.s_axil_arvalid(s_axil_arvalid),
		.s_axil_arready(s_axil_arready),
		.s_axil_rdata(s_axil_rdata),
		.s_axil_rresp(s_axil_rresp),
		.s_axil_rvalid(s_axil_rvalid),
		.s_axil_rready(s_axil_rready),
		.resp_head((resp_count_r != 0) ? resp_fifo_r[resp_head_r] : 32'd0),
		.out_meta_head0(out_meta_valid_r ? out_meta_head0_r : 32'd0),
		.out_meta_head1(out_meta_valid_r ? out_meta_head1_r : 32'd0),
		.out_meta_head2(out_meta_valid_r ? out_meta_head2_r : 32'd0),
		.shell_status_word(shell_status_word),
		.status_cmd_slot_ready(status_cmd_slot_ready),
		.status_resp_not_empty(status_resp_not_empty),
		.status_irq_active(status_irq_active),
		.status_cmd_busy(command_busy_r),
		.desc_push_pulse(csr_desc_push_pulse),
		.resp_pop_pulse(csr_resp_pop_pulse),
		.soft_clear_pulse(csr_soft_clear_pulse),
		.clear_flags_pulse(csr_clear_flags_pulse),
		.ingress_push_pulse(csr_ingress_push_pulse),
		.out_meta_pop_pulse(csr_out_meta_pop_pulse),
		.cmd_inst_reg(csr_cmd_inst),
		.cmd_id_reg(csr_cmd_id),
		.a_addr_reg(csr_a_addr),
		.b_addr_reg(csr_b_addr),
		.c_addr_reg(csr_c_addr),
		.m_addr_reg(csr_m_addr),
		.shell_mode_reg(shell_mode_reg),
		.ingress_kind_reg(ingress_kind_reg),
		.ingress_ctrl_id_reg(ingress_ctrl_id_reg),
		.ingress_tile_info0_reg(ingress_tile_info0_reg),
		.ingress_tile_info1_reg(ingress_tile_info1_reg),
		.ingress_word_count_reg(ingress_word_count_reg)
	);

	PT_V3 #(
		.DATA_WIDTH(DATA_WIDTH),
		.WORD_WIDTH(WORD_WIDTH),
		.ELEM_WIDTH(ELEM_WIDTH),
		.PACK_LANES(PACK_LANES),
		.ACC_WIDTH(ACC_WIDTH),
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM),
		.EXT_ADDR_W(EXT_ADDR_W),
		.DMA_BEATS_W(DMA_BEATS_W),
		.LUT_DEPTH(LUT_DEPTH),
		.A_BANK_DEPTH(A_BANK_DEPTH),
		.B_BANK_DEPTH(B_BANK_DEPTH),
		.M_BANK_DEPTH(M_BANK_DEPTH),
		.A_LOAD_LANES(A_LOAD_LANES),
		.B_LOAD_LANES(B_LOAD_LANES),
		.M_WRITE_LANES(M_WRITE_LANES),
		.M_EXPORT_LANES(M_EXPORT_LANES),
		.M_PHYSICAL_COPIES(M_PHYSICAL_COPIES)
	) u_pt_v3 (
		.clk(clk),
		.rstn(rstn),
		.clear(clear),
		.soft_clear(csr_soft_clear_pulse),
		.s_axis_tvalid(pt_s_axis_tvalid),
		.s_axis_tready(pt_s_axis_tready),
		.s_axis_tdata(pt_s_axis_tdata),
		.s_axis_tstrb(pt_s_axis_tstrb),
		.s_axis_tlast(1'b0),
		.s_axis_tkeep(1'b1),
		.s_axis_tid(1'b0),
		.s_axis_tdest(1'b0),
		.s_axis_tuser(pt_s_axis_tuser),
		.m_axis_tvalid(pt_m_axis_tvalid),
		.m_axis_tready(pt_m_axis_tready),
		.m_axis_tdata(pt_m_axis_tdata),
		.m_axis_tstrb(pt_m_axis_tstrb),
		.m_axis_tlast(pt_m_axis_tlast),
		.m_axis_tkeep(),
		.m_axis_tid(),
		.m_axis_tdest(),
		.m_axis_tuser(),
		.ctrl_valid(pt_ctrl_valid_r),
		.ctrl_ready(pt_ctrl_ready),
		.ctrl_inst(pt_ctrl_inst_r),
		.ctrl_id(pt_ctrl_id_r),
		.ctrl_resp(pt_ctrl_resp),
		.ctrl_resp_valid(pt_ctrl_resp_valid),
		.dma_req_valid(pt_dma_req_valid),
		.dma_req_ready(pt_dma_req_ready),
		.dma_req_kind(pt_dma_req_kind),
		.dma_req_id(pt_dma_req_id),
		.dma_done(pt_dma_done_r),
		.dma_error(pt_dma_error_r),
		.m_dma_req_valid(pt_m_dma_req_valid),
		.m_dma_req_ready(pt_m_dma_req_ready),
		.m_dma_req_id(pt_m_dma_req_id),
		.m_dma_req_buf(pt_m_dma_req_buf),
		.m_dma_req_beats(pt_m_dma_req_beats),
		.m_dma_done(pt_m_dma_done_r),
		.m_dma_error(pt_m_dma_error_r),
		.irq(pt_irq_unused)
	);

	integer i;
	integer j;
	integer found_idx;
	integer second_found_idx;
	integer resident_idx;
	integer acc_idx;
	reg [3:0] cmd_opcode;
	reg [3:0] load_m_tiles;
	reg [3:0] load_n_tiles;
	reg [3:0] load_k_tiles;
	reg need_a;
	reg need_b;
	reg [9:0] load_a_size;
	reg [9:0] load_b_size;
	reg [3:0] matmul_m_tiles;
	reg [3:0] matmul_n_tiles;
	reg [3:0] matmul_k_tiles;
	reg [9:0] matadd_m_off;
	reg [15:0] matadd_word_count;
	reg [31:0] c_word;
	reg [31:0] result_word;
	integer a_resident_slot_idx;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			resp_head_r <= 2'd0;
			resp_tail_r <= 2'd0;
			resp_count_r <= 3'd0;
			out_meta_valid_r <= 1'b0;
			out_meta_head0_r <= 32'd0;
			out_meta_head1_r <= 32'd0;
			out_meta_head2_r <= 32'd0;
			scratchpad_miss_sticky_r <= 1'b0;
			shell_error_sticky_r <= 1'b0;
			ingress_active_r <= 1'b0;
			ingress_slot_idx_r <= 2'd0;
			ingress_kind_r <= KIND_NONE;
			ingress_ctrl_id_r <= 32'd0;
			ingress_m_tile_off_r <= 8'd0;
			ingress_n_tile_off_r <= 8'd0;
			ingress_k_tile_off_r <= 8'd0;
			ingress_m_tiles_r <= 8'd0;
			ingress_n_tiles_r <= 8'd0;
			ingress_k_tiles_r <= 8'd0;
			ingress_word_count_r <= 16'd0;
			ingress_recv_words_r <= 16'd0;
			command_busy_r <= 1'b0;
			active_cmd_kind_r <= CMD_KIND_IDLE;
			active_cmd_id_r <= 32'd0;
			active_cmd_inst_r <= 32'd0;
			active_m_tiles_r <= 4'd0;
			active_n_tiles_r <= 4'd0;
			active_k_tiles_r <= 4'd0;
			active_m_tile_off_r <= 8'd0;
			active_n_tile_off_r <= 8'd0;
			active_acc_slot_r <= 2'd0;
			active_result_word_count_r <= 16'd0;
			active_wait_pt_resp_r <= 1'b0;
			active_got_pt_resp_r <= 1'b0;
			active_pt_resp_word_r <= 32'd0;
			active_wait_export_r <= 1'b0;
			active_got_export_r <= 1'b0;
			active_forward_m_r <= 1'b0;
			active_emit_intermediate_r <= 1'b0;
			active_pt_beats_expected_r <= 16'd0;
			pt_ctrl_valid_r <= 1'b0;
			pt_ctrl_inst_r <= 32'd0;
			pt_ctrl_id_r <= 32'd0;
			pt_dma_done_r <= 1'b0;
			pt_dma_error_r <= 1'b0;
			pt_m_dma_done_r <= 1'b0;
			pt_m_dma_error_r <= 1'b0;
			load_busy_r <= 1'b0;
			load_kind_r <= KIND_NONE;
			load_resident_idx_r <= 5'd0;
			load_word_idx_r <= 16'd0;
			load_word_count_r <= 16'd0;
			export_busy_r <= 1'b0;
			export_word_idx_r <= 16'd0;
			export_word_count_r <= 16'd0;
			export_beats_seen_r <= 16'd0;
			emit_active_r <= 1'b0;
			emit_source_kind_r <= 2'd0;
			emit_word_idx_r <= 16'd0;
			emit_word_count_r <= 16'd0;
			emit_ctrl_id_r <= 32'd0;
			emit_m_tile_off_r <= 8'd0;
			emit_n_tile_off_r <= 8'd0;
			emit_m_tiles_r <= 8'd0;
			emit_n_tiles_r <= 8'd0;
			emit_is_final_r <= 1'b0;
			next_acc_slot_r <= 1'b0;
			qcfg_wait_payload_r <= 1'b0;
			qcfg_ctrl_id_r <= 32'd0;
			for (i = 0; i < MAX_PENDING_ENTRIES; i = i + 1) begin
				pending_valid_r[i] <= 1'b0;
				pending_kind_r[i] <= KIND_NONE;
				pending_ctrl_id_r[i] <= 32'd0;
				pending_m_tile_off_r[i] <= 8'd0;
				pending_n_tile_off_r[i] <= 8'd0;
				pending_k_tile_off_r[i] <= 8'd0;
				pending_m_tiles_r[i] <= 8'd0;
				pending_n_tiles_r[i] <= 8'd0;
				pending_k_tiles_r[i] <= 8'd0;
				pending_word_count_r[i] <= 16'd0;
			end
			for (i = 0; i < MAX_RESIDENT_ENTRIES; i = i + 1) begin
				resident_valid_r[i] <= 1'b0;
				resident_kind_r[i] <= KIND_NONE;
				resident_ctrl_id_r[i] <= 32'd0;
				resident_m_tile_off_r[i] <= 8'd0;
				resident_n_tile_off_r[i] <= 8'd0;
				resident_k_tile_off_r[i] <= 8'd0;
				resident_m_tiles_r[i] <= 8'd0;
				resident_n_tiles_r[i] <= 8'd0;
				resident_k_tiles_r[i] <= 8'd0;
				resident_word_count_r[i] <= 16'd0;
			end
			for (i = 0; i < 2; i = i + 1) begin
				acc_valid_r[i] <= 1'b0;
				acc_ctrl_id_r[i] <= 32'd0;
				acc_m_tile_off_r[i] <= 8'd0;
				acc_n_tile_off_r[i] <= 8'd0;
				acc_m_tiles_r[i] <= 8'd0;
				acc_n_tiles_r[i] <= 8'd0;
				acc_word_count_r[i] <= 16'd0;
			end
		end else begin
			pt_dma_done_r <= 1'b0;
			pt_m_dma_done_r <= 1'b0;
			pt_dma_error_r <= 1'b0;
			pt_m_dma_error_r <= 1'b0;

			if (clear || csr_soft_clear_pulse) begin
				resp_head_r <= 2'd0;
				resp_tail_r <= 2'd0;
				resp_count_r <= 3'd0;
				out_meta_valid_r <= 1'b0;
				out_meta_head0_r <= 32'd0;
				out_meta_head1_r <= 32'd0;
				out_meta_head2_r <= 32'd0;
				scratchpad_miss_sticky_r <= 1'b0;
				shell_error_sticky_r <= 1'b0;
				ingress_active_r <= 1'b0;
				ingress_recv_words_r <= 16'd0;
				command_busy_r <= 1'b0;
				active_cmd_kind_r <= CMD_KIND_IDLE;
				active_wait_pt_resp_r <= 1'b0;
				active_got_pt_resp_r <= 1'b0;
				active_wait_export_r <= 1'b0;
				active_got_export_r <= 1'b0;
				pt_ctrl_valid_r <= 1'b0;
				load_busy_r <= 1'b0;
				export_busy_r <= 1'b0;
				emit_active_r <= 1'b0;
				qcfg_wait_payload_r <= 1'b0;
				for (i = 0; i < MAX_PENDING_ENTRIES; i = i + 1) begin
					pending_valid_r[i] <= 1'b0;
				end
				for (i = 0; i < MAX_RESIDENT_ENTRIES; i = i + 1) begin
					resident_valid_r[i] <= 1'b0;
				end
				for (i = 0; i < 2; i = i + 1) begin
					acc_valid_r[i] <= 1'b0;
				end
			end else begin
				if (csr_resp_pop_pulse && (resp_count_r != 0)) begin
					resp_head_r <= resp_head_r + 1'b1;
					resp_count_r <= resp_count_r - 1'b1;
				end
				if (csr_out_meta_pop_pulse) begin
					out_meta_valid_r <= 1'b0;
				end
				if (csr_clear_flags_pulse) begin
					scratchpad_miss_sticky_r <= 1'b0;
					shell_error_sticky_r <= 1'b0;
				end

				if (pt_ctrl_valid_r && pt_ctrl_ready) begin
					pt_ctrl_valid_r <= 1'b0;
				end

				if (pt_ctrl_resp_valid && active_wait_pt_resp_r) begin
					active_pt_resp_word_r <= pt_ctrl_resp;
					active_got_pt_resp_r <= 1'b1;
					active_wait_pt_resp_r <= 1'b0;
				end

				if (emit_active_r && m_shell_axis_tvalid && m_shell_axis_tready) begin
					if ((emit_word_idx_r + SHELL_STREAM_LANES) >= emit_word_count_r) begin
						emit_active_r <= 1'b0;
						if (command_busy_r && ((active_cmd_kind_r == CMD_KIND_MATMUL) || (active_cmd_kind_r == CMD_KIND_MATADD))) begin
							command_busy_r <= 1'b0;
							active_cmd_kind_r <= CMD_KIND_IDLE;
						end
					end else begin
						emit_word_idx_r <= emit_word_idx_r + SHELL_STREAM_LANES;
					end
				end

				if (csr_ingress_push_pulse && !ingress_active_r) begin
					find_free_pending_task(found_idx);
					if ((found_idx < 0) || (ingress_word_count_reg == 0)) begin
						shell_error_sticky_r <= 1'b1;
					end else begin
						ingress_active_r <= 1'b1;
						ingress_slot_idx_r <= found_idx[1:0];
						ingress_kind_r <= ingress_kind_reg[1:0];
						ingress_ctrl_id_r <= ingress_ctrl_id_reg;
						ingress_m_tile_off_r <= ingress_tile_info0_reg[7:0];
						ingress_n_tile_off_r <= ingress_tile_info0_reg[15:8];
						ingress_k_tile_off_r <= ingress_tile_info0_reg[23:16];
						ingress_m_tiles_r <= ingress_tile_info1_reg[7:0];
						ingress_n_tiles_r <= ingress_tile_info1_reg[15:8];
						ingress_k_tiles_r <= ingress_tile_info1_reg[23:16];
						ingress_word_count_r <= ingress_word_count_reg[15:0];
						ingress_recv_words_r <= 16'd0;
					end
				end

				if (ingress_active_r && s_shell_axis_tvalid && s_shell_axis_tready) begin
					if (s_shell_axis_tlast && ((ingress_recv_words_r + SHELL_STREAM_LANES) < ingress_word_count_r)) begin
						shell_error_sticky_r <= 1'b1;
						ingress_active_r <= 1'b0;
					end
					for (i = 0; i < SHELL_STREAM_LANES; i = i + 1) begin
						if ((ingress_recv_words_r + i) < ingress_word_count_r) begin
							if (s_shell_axis_tstrb[(i * 4) +: 4] == 4'hF) begin
								pending_data_r[(ingress_slot_idx_r * MAX_ENTRY_WORDS) + ingress_recv_words_r + i] <=
									s_shell_axis_tdata[(i * DATA_WIDTH) +: DATA_WIDTH];
							end else begin
								shell_error_sticky_r <= 1'b1;
							end
						end
					end
					if ((ingress_recv_words_r + SHELL_STREAM_LANES) >= ingress_word_count_r) begin
						if (s_shell_axis_tlast) begin
							pending_valid_r[ingress_slot_idx_r] <= 1'b1;
							pending_kind_r[ingress_slot_idx_r] <= ingress_kind_r;
							pending_ctrl_id_r[ingress_slot_idx_r] <= ingress_ctrl_id_r;
							pending_m_tile_off_r[ingress_slot_idx_r] <= ingress_m_tile_off_r;
							pending_n_tile_off_r[ingress_slot_idx_r] <= ingress_n_tile_off_r;
							pending_k_tile_off_r[ingress_slot_idx_r] <= ingress_k_tile_off_r;
							pending_m_tiles_r[ingress_slot_idx_r] <= ingress_m_tiles_r;
							pending_n_tiles_r[ingress_slot_idx_r] <= ingress_n_tiles_r;
							pending_k_tiles_r[ingress_slot_idx_r] <= ingress_k_tiles_r;
							pending_word_count_r[ingress_slot_idx_r] <= ingress_word_count_r;
						end else begin
							shell_error_sticky_r <= 1'b1;
						end
						ingress_active_r <= 1'b0;
					end else begin
						ingress_recv_words_r <= ingress_recv_words_r + SHELL_STREAM_LANES;
					end
				end

				if (!load_busy_r && command_busy_r && (active_cmd_kind_r == CMD_KIND_MATMUL) && pt_dma_req_valid && pt_dma_req_ready) begin
					if (pt_dma_req_kind == `PT_DMA_KIND_A) begin
						find_resident_task(active_cmd_id_r, KIND_A, resident_idx);
						if (resident_idx >= 0) begin
							load_busy_r <= 1'b1;
							load_kind_r <= KIND_A;
							load_resident_idx_r <= resident_idx[4:0];
							load_word_idx_r <= 16'd0;
							load_word_count_r <= resident_word_count_r[resident_idx];
						end else begin
							shell_error_sticky_r <= 1'b1;
						end
					end else if (pt_dma_req_kind == `PT_DMA_KIND_B) begin
						find_resident_task(active_cmd_id_r, KIND_B, resident_idx);
						if (resident_idx >= 0) begin
							load_busy_r <= 1'b1;
							load_kind_r <= KIND_B;
							load_resident_idx_r <= resident_idx[4:0];
							load_word_idx_r <= 16'd0;
							load_word_count_r <= resident_word_count_r[resident_idx];
						end else begin
							shell_error_sticky_r <= 1'b1;
						end
					end else begin
						shell_error_sticky_r <= 1'b1;
					end
				end

				if (load_busy_r && pt_s_axis_tvalid && pt_s_axis_tready) begin
					if ((load_word_idx_r + LOAD_STREAM_LANES) >= load_word_count_r) begin
						load_busy_r <= 1'b0;
					end else begin
						load_word_idx_r <= load_word_idx_r + LOAD_STREAM_LANES;
					end
				end

				if (!export_busy_r && command_busy_r && (active_cmd_kind_r == CMD_KIND_MATMUL) && pt_m_dma_req_valid && pt_m_dma_req_ready) begin
					export_busy_r <= 1'b1;
					export_word_idx_r <= 16'd0;
					export_beats_seen_r <= 16'd0;
					export_word_count_r <= active_result_word_count_r;
					active_wait_export_r <= 1'b1;
					active_pt_beats_expected_r <= pt_m_dma_req_beats[15:0];
				end

				if (export_busy_r && pt_m_axis_tvalid && pt_m_axis_tready) begin
					for (i = 0; i < M_EXPORT_LANES; i = i + 1) begin
						if ((export_word_idx_r + i) < export_word_count_r) begin
							temp_result_data_r[export_word_idx_r + i] <= pt_m_axis_tdata[(i * DATA_WIDTH) +: DATA_WIDTH];
						end
					end
					if ((export_beats_seen_r + 1'b1) >= active_pt_beats_expected_r) begin
						export_busy_r <= 1'b0;
						active_got_export_r <= 1'b1;
						active_wait_export_r <= 1'b0;
						pt_m_dma_done_r <= 1'b1;
					end else begin
						export_word_idx_r <= export_word_idx_r + M_EXPORT_LANES;
						export_beats_seen_r <= export_beats_seen_r + 1'b1;
					end
				end

				if (csr_desc_push_pulse && !command_busy_r) begin
					cmd_opcode = csr_cmd_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
					if (qcfg_wait_payload_r) begin
						command_busy_r <= 1'b1;
						active_cmd_kind_r <= CMD_KIND_PT;
						active_cmd_id_r <= csr_cmd_id;
						pt_ctrl_inst_r <= csr_cmd_inst;
						pt_ctrl_id_r <= csr_cmd_id;
						pt_ctrl_valid_r <= 1'b1;
						active_wait_pt_resp_r <= 1'b1;
						active_got_pt_resp_r <= 1'b0;
					end else if (cmd_opcode == `PT_OP_CFG) begin
						command_busy_r <= 1'b1;
						active_cmd_kind_r <= CMD_KIND_PT;
						active_cmd_id_r <= csr_cmd_id;
						pt_ctrl_inst_r <= csr_cmd_inst;
						pt_ctrl_id_r <= csr_cmd_id;
						pt_ctrl_valid_r <= 1'b1;
						active_wait_pt_resp_r <= 1'b1;
						active_got_pt_resp_r <= 1'b0;
					end else if (cmd_opcode == `PT_OP_QCFG) begin
						pt_ctrl_inst_r <= csr_cmd_inst;
						pt_ctrl_id_r <= csr_cmd_id;
						pt_ctrl_valid_r <= 1'b1;
						qcfg_wait_payload_r <= 1'b1;
						qcfg_ctrl_id_r <= csr_cmd_id;
					end else if (cmd_opcode == `PT_OP_LOAD) begin
						need_a = csr_cmd_inst[`PT_LOAD_NEED_A_BIT];
						need_b = csr_cmd_inst[`PT_LOAD_NEED_B_BIT];
						load_m_tiles = decode_tile_count(csr_cmd_inst[`PT_LOAD_M_CODE_H:`PT_LOAD_M_CODE_L]);
						load_n_tiles = decode_tile_count(csr_cmd_inst[`PT_LOAD_N_CODE_H:`PT_LOAD_N_CODE_L]);
						load_k_tiles = decode_tile_count(csr_cmd_inst[`PT_LOAD_K_CODE_H:`PT_LOAD_K_CODE_L]);
						load_a_size = csr_cmd_inst[`PT_LOAD_A_SIZE_H:`PT_LOAD_A_SIZE_L];
						load_b_size = csr_cmd_inst[`PT_LOAD_B_SIZE_H:`PT_LOAD_B_SIZE_L];
						a_resident_slot_idx = -1;
						if (!(need_a || need_b) || (load_m_tiles == 0) || (load_n_tiles == 0) || (load_k_tiles == 0)) begin
							push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
							scratchpad_miss_sticky_r <= 1'b1;
						end else begin
							if (need_a) begin
								find_pending_task(csr_cmd_id, KIND_A, {6'd0, load_a_size}, load_m_tiles, 8'd0, load_k_tiles, found_idx);
								if (found_idx < 0) begin
									push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
									scratchpad_miss_sticky_r <= 1'b1;
								end else begin
									find_resident_task(csr_cmd_id, KIND_A, resident_idx);
									if (resident_idx < 0) begin
										find_free_resident_task(resident_idx);
									end
									if (resident_idx < 0) begin
										push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
										shell_error_sticky_r <= 1'b1;
									end else begin
										a_resident_slot_idx = resident_idx;
										resident_valid_r[resident_idx] = 1'b1;
										resident_kind_r[resident_idx] = KIND_A;
										resident_ctrl_id_r[resident_idx] = csr_cmd_id;
										resident_m_tile_off_r[resident_idx] = pending_m_tile_off_r[found_idx];
										resident_n_tile_off_r[resident_idx] = pending_n_tile_off_r[found_idx];
										resident_k_tile_off_r[resident_idx] = pending_k_tile_off_r[found_idx];
										resident_m_tiles_r[resident_idx] = pending_m_tiles_r[found_idx];
										resident_n_tiles_r[resident_idx] = pending_n_tiles_r[found_idx];
										resident_k_tiles_r[resident_idx] = pending_k_tiles_r[found_idx];
										resident_word_count_r[resident_idx] = pending_word_count_r[found_idx];
										for (j = 0; j < MAX_ENTRY_WORDS; j = j + 1) begin
											if (j < pending_word_count_r[found_idx]) begin
												resident_data_r[(resident_idx * MAX_ENTRY_WORDS) + j] = pending_data_r[(found_idx * MAX_ENTRY_WORDS) + j];
											end
										end
										pending_valid_r[found_idx] = 1'b0;
										if (!need_b) begin
											push_resp_task(pack_resp_local(1'b0, 1'b0, csr_cmd_id));
										end
									end
								end
							end
							if (need_b) begin
								find_pending_task(csr_cmd_id, KIND_B, {6'd0, load_b_size}, 8'd0, load_n_tiles, load_k_tiles, found_idx);
								if (found_idx < 0) begin
									find_pending_task(csr_cmd_id, KIND_C, {6'd0, load_b_size}, load_m_tiles, load_n_tiles, 8'd0, found_idx);
								end
								if (found_idx < 0) begin
									push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
									scratchpad_miss_sticky_r <= 1'b1;
								end else begin
									find_resident_task(csr_cmd_id, pending_kind_r[found_idx], resident_idx);
									if (resident_idx < 0) begin
									find_free_resident_task(resident_idx);
									if ((resident_idx == a_resident_slot_idx) && (a_resident_slot_idx >= 0)) begin
										for (j = a_resident_slot_idx + 1; j < MAX_RESIDENT_ENTRIES; j = j + 1) begin
											if (!resident_valid_r[j] && (resident_idx == a_resident_slot_idx)) begin
												resident_idx = j;
											end
										end
										if (resident_idx == a_resident_slot_idx) begin
											resident_idx = -1;
										end
									end
									end
									if (resident_idx < 0) begin
										push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
										shell_error_sticky_r <= 1'b1;
									end else begin
										resident_valid_r[resident_idx] = 1'b1;
										resident_kind_r[resident_idx] = pending_kind_r[found_idx];
										resident_ctrl_id_r[resident_idx] = csr_cmd_id;
										resident_m_tile_off_r[resident_idx] = pending_m_tile_off_r[found_idx];
										resident_n_tile_off_r[resident_idx] = pending_n_tile_off_r[found_idx];
										resident_k_tile_off_r[resident_idx] = pending_k_tile_off_r[found_idx];
										resident_m_tiles_r[resident_idx] = pending_m_tiles_r[found_idx];
										resident_n_tiles_r[resident_idx] = pending_n_tiles_r[found_idx];
										resident_k_tiles_r[resident_idx] = pending_k_tiles_r[found_idx];
										resident_word_count_r[resident_idx] = pending_word_count_r[found_idx];
										for (j = 0; j < MAX_ENTRY_WORDS; j = j + 1) begin
											if (j < pending_word_count_r[found_idx]) begin
												resident_data_r[(resident_idx * MAX_ENTRY_WORDS) + j] = pending_data_r[(found_idx * MAX_ENTRY_WORDS) + j];
											end
										end
										pending_valid_r[found_idx] = 1'b0;
										push_resp_task(pack_resp_local(1'b0, 1'b0, csr_cmd_id));
									end
								end
							end
						end
					end else if (cmd_opcode == `PT_OP_MATMUL) begin
						find_resident_task(csr_cmd_id, KIND_A, found_idx);
						find_resident_task(csr_cmd_id, KIND_B, second_found_idx);
						if ((found_idx < 0) || (second_found_idx < 0)) begin
							push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
							scratchpad_miss_sticky_r <= 1'b1;
						end else begin
							matmul_m_tiles = csr_cmd_inst[`PT_MATMUL_M_TILES_H:`PT_MATMUL_M_TILES_L];
							matmul_n_tiles = csr_cmd_inst[`PT_MATMUL_N_TILES_H:`PT_MATMUL_N_TILES_L];
							matmul_k_tiles = csr_cmd_inst[`PT_MATMUL_K_TILES_H:`PT_MATMUL_K_TILES_L];
							command_busy_r <= 1'b1;
							active_cmd_kind_r <= CMD_KIND_MATMUL;
							active_cmd_id_r <= csr_cmd_id;
							active_cmd_inst_r <= csr_cmd_inst;
							active_m_tiles_r <= matmul_m_tiles;
							active_n_tiles_r <= matmul_n_tiles;
							active_k_tiles_r <= matmul_k_tiles;
							active_m_tile_off_r <= resident_m_tile_off_r[found_idx];
							active_n_tile_off_r <= resident_n_tile_off_r[second_found_idx];
							active_result_word_count_r <= calc_output_word_count(matmul_m_tiles, matmul_n_tiles);
							active_wait_pt_resp_r <= 1'b1;
							active_got_pt_resp_r <= 1'b0;
							active_wait_export_r <= 1'b0;
							active_got_export_r <= 1'b0;
							active_forward_m_r <= shell_forward_m_enable;
							active_emit_intermediate_r <= shell_emit_intermediate_enable;
							pt_ctrl_inst_r <= csr_cmd_inst;
							pt_ctrl_id_r <= csr_cmd_id;
							pt_ctrl_valid_r <= 1'b1;
						end
					end else if (cmd_opcode == `PT_OP_MATADD) begin
						matadd_m_off = csr_cmd_inst[`PT_MATADD_M_OFF_H:`PT_MATADD_M_OFF_L];
						acc_idx = matadd_m_off[8];
						if (!acc_valid_r[acc_idx]) begin
							push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
							scratchpad_miss_sticky_r <= 1'b1;
						end else begin
							find_resident_task(csr_cmd_id, KIND_C, resident_idx);
							matadd_word_count = acc_word_count_r[acc_idx];
							for (j = 0; j < MAX_ACC_WORDS; j = j + 1) begin
								if (j < matadd_word_count) begin
									if ((resident_idx >= 0) && (j < resident_word_count_r[resident_idx])) begin
										c_word = resident_data_r[(resident_idx * MAX_ENTRY_WORDS) + j];
									end else begin
										c_word = 32'd0;
									end
									result_word = sat_add_packed_word(acc_data_r[(acc_idx * MAX_ACC_WORDS) + j], c_word);
									acc_data_r[(acc_idx * MAX_ACC_WORDS) + j] = result_word;
								end
							end
							acc_ctrl_id_r[acc_idx] <= csr_cmd_id;
							push_resp_task(pack_resp_local(1'b0, acc_idx[0], csr_cmd_id));
							command_busy_r <= 1'b1;
							active_cmd_kind_r <= CMD_KIND_MATADD;
							queue_emit_from_acc_task(acc_idx, csr_cmd_id, 1'b1);
						end
					end else begin
						push_resp_task(pack_resp_local(1'b1, 1'b0, csr_cmd_id));
						shell_error_sticky_r <= 1'b1;
					end
				end

				if (command_busy_r && (active_cmd_kind_r == CMD_KIND_PT) && active_got_pt_resp_r) begin
					push_resp_task(active_pt_resp_word_r);
					command_busy_r <= 1'b0;
					active_cmd_kind_r <= CMD_KIND_IDLE;
					active_got_pt_resp_r <= 1'b0;
					qcfg_wait_payload_r <= 1'b0;
				end

				if (command_busy_r && (active_cmd_kind_r == CMD_KIND_MATMUL) && active_got_pt_resp_r && active_got_export_r) begin
					if (active_pt_resp_word_r[31]) begin
						push_resp_task(active_pt_resp_word_r);
					end else begin
						find_acc_match_task(active_cmd_id_r, active_m_tile_off_r, active_n_tile_off_r, active_m_tiles_r, active_n_tiles_r, acc_idx);
						if ((acc_idx >= 0) && active_forward_m_r) begin
							for (j = 0; j < MAX_ACC_WORDS; j = j + 1) begin
								if (j < active_result_word_count_r) begin
									acc_data_r[(acc_idx * MAX_ACC_WORDS) + j] <=
										sat_add_packed_word(acc_data_r[(acc_idx * MAX_ACC_WORDS) + j], temp_result_data_r[j]);
								end
							end
							active_acc_slot_r <= acc_idx[1:0];
						end else begin
							acc_idx = next_acc_slot_r;
							acc_valid_r[acc_idx] <= 1'b1;
							acc_ctrl_id_r[acc_idx] <= active_cmd_id_r;
							acc_m_tile_off_r[acc_idx] <= active_m_tile_off_r;
							acc_n_tile_off_r[acc_idx] <= active_n_tile_off_r;
							acc_m_tiles_r[acc_idx] <= active_m_tiles_r;
							acc_n_tiles_r[acc_idx] <= active_n_tiles_r;
							acc_word_count_r[acc_idx] <= active_result_word_count_r;
							for (j = 0; j < MAX_ACC_WORDS; j = j + 1) begin
								if (j < active_result_word_count_r) begin
									acc_data_r[(acc_idx * MAX_ACC_WORDS) + j] <= temp_result_data_r[j];
								end
							end
							active_acc_slot_r <= acc_idx[1:0];
							next_acc_slot_r <= ~next_acc_slot_r;
						end
						push_resp_task(pack_resp_local(1'b0, active_acc_slot_r[0], active_cmd_id_r));
						if (!active_forward_m_r) begin
							queue_emit_from_temp_task(
								active_cmd_id_r,
								active_result_word_count_r,
								active_m_tile_off_r,
								active_n_tile_off_r,
								active_m_tiles_r,
								active_n_tiles_r,
								1'b1
							);
						end else if (active_emit_intermediate_r) begin
							queue_emit_from_acc_task(active_acc_slot_r, active_cmd_id_r, 1'b0);
						end else begin
							command_busy_r <= 1'b0;
							active_cmd_kind_r <= CMD_KIND_IDLE;
						end
					end
					active_got_pt_resp_r <= 1'b0;
					active_got_export_r <= 1'b0;
				end
			end
		end
	end

endmodule
