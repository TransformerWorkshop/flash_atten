`include "param.vh"

module PT_CE_V3 #(
	parameter DATA_WIDTH   = 32,
	parameter ELEM_WIDTH   = 8,
	parameter PACK_LANES   = 4,
	parameter GEMM_X_DIM   = 4,
	parameter GEMM_Y_DIM   = 4,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16,
	parameter M_BANK_DEPTH = 16,
	parameter M_WRITE_LANES = GEMM_Y_DIM
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire                       ce_cmd_valid,
	output wire                       ce_cmd_ready,
	input  wire [`INST_WIDTH-1:0]     ce_cmd_ctrl,
	input  wire [31:0]                ce_cmd_id,
	input  wire [`PT_LOCAL_ADDR_W-1:0] ce_a_local_base,
	input  wire [`PT_LOCAL_ADDR_W-1:0] ce_b_local_base,
	input  wire                       ce_m_wr_buf,
	output wire                       a_mem_rd_en,
	output reg                        exec_a_buf,
	output reg  [(((A_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(A_BANK_DEPTH * GEMM_X_DIM))-1:0] exec_a_addr,
	output wire                       b_mem_rd_en,
	output reg                        exec_b_buf,
	output reg  [(((B_BANK_DEPTH * GEMM_Y_DIM) <= 1) ? 1 : $clog2(B_BANK_DEPTH * GEMM_Y_DIM))-1:0] exec_b_addr,
	output reg                        exec_m_b_buf,
	output reg  [(((M_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(M_BANK_DEPTH * GEMM_X_DIM))-1:0] exec_m_b_addr,
	output wire                       exec_m_b_rd_en,
	output wire                       gemm_a_valid,
	output wire                       gemm_b_valid,
	output wire                       gemm_start,
	output wire [DATA_WIDTH-1:0]      gemm_num_acc,
	input  wire                       gemm_a_ready,
	input  wire                       gemm_b_ready,
	input  wire                       gemm_start_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] quant_m_data,
	input  wire [31:0]                quant_m_idx,
	input  wire                       quant_m_valid,
	input  wire                       quant_m_last,
	output wire                       quant_m_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_row_data,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_mem_row_data,
	input  wire                       m_buf0_single_output,
	input  wire                       m_buf1_single_output,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_lhs_data,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_rhs_data,
	output wire [31:0]                gema_in_idx,
	output wire                       gema_in_last,
	output wire                       gema_in_valid,
	input  wire                       gema_in_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] add_m_data,
	input  wire [31:0]                add_m_idx,
	input  wire                       add_m_valid,
	input  wire                       add_m_last,
	output wire                       add_m_ready,
	output reg                        m_mem_wr_en,
	output reg                        m_mem_wr_buf,
	output reg  [GEMM_Y_DIM-1:0]      m_mem_wr_mask,
	output reg  [(((M_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(M_BANK_DEPTH * GEMM_X_DIM))-1:0] m_mem_wr_addr,
	output reg  [GEMM_Y_DIM*DATA_WIDTH-1:0]      m_mem_wr_data,
	output reg                        ce_resp_valid,
	output reg  [31:0]                ce_resp,
	output reg  [`PT_SIZE_W-1:0]      ce_resp_row_chunk_count,
	output reg                        ce_resp_single_output,
	output reg                        ce_irq
);

	localparam integer A_DEPTH = A_BANK_DEPTH * GEMM_X_DIM;
	localparam integer B_DEPTH = B_BANK_DEPTH * GEMM_Y_DIM;
	localparam integer M_DEPTH = M_BANK_DEPTH * GEMM_X_DIM;
	localparam integer A_AW = (A_DEPTH <= 1) ? 1 : $clog2(A_DEPTH);
	localparam integer B_AW = (B_DEPTH <= 1) ? 1 : $clog2(B_DEPTH);
	localparam integer M_AW = (M_DEPTH <= 1) ? 1 : $clog2(M_DEPTH);
	localparam integer A_DIM_SHIFT = $clog2((GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM);
	localparam integer B_DIM_SHIFT = $clog2((GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM);
	localparam integer STORE_BASE_W = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM + 1);
	localparam [0:0] DRAIN_FULL_WIDTH = (M_WRITE_LANES >= GEMM_Y_DIM) ? 1'b1 : 1'b0;
	localparam [STORE_BASE_W:0] M_WRITE_LANES_W = M_WRITE_LANES;
	localparam integer MATMUL_ACC_W = 16;
	localparam integer TILE_IDX_W = 3;
	localparam integer K_WORDS_PER_TILE = (PACK_LANES <= 1) ? GEMM_X_DIM : (GEMM_X_DIM / PACK_LANES);
	localparam [31:0] K_WORDS_PER_TILE_U32 = K_WORDS_PER_TILE;

	localparam [2:0] ADD_IDLE        = 3'd0;
	localparam [2:0] ADD_REQ         = 3'd1;
	localparam [2:0] ADD_CAPTURE     = 3'd2;
	localparam [2:0] ADD_SEND        = 3'd3;
	localparam [2:0] ADD_WAIT_RESULT = 3'd4;
	localparam [2:0] ADD_STORE       = 3'd5;

	reg        shadow_valid_r;
	reg        shadow_done_exec_r;
	reg [31:0] shadow_ctrl_r;
	reg [31:0] shadow_id_r;
	reg        shadow_a_buf_r;
	reg        shadow_b_buf_r;
	reg [A_AW-1:0] shadow_a_row_base_r;
	reg [B_AW-1:0] shadow_b_row_base_r;
	reg        shadow_m_wr_buf_r;
	reg [TILE_IDX_W-1:0] shadow_m_tile_idx_r, shadow_n_tile_idx_r;
	reg [3:0] shadow_total_n_tiles_r;
	reg shadow_single_output_r;
	reg shadow_final_tile_r;

	reg        exec_valid_r;
	reg [31:0] exec_ctrl_r;
	reg [31:0] exec_id_r;
	reg        exec_a_buf_r;
	reg        exec_b_buf_r;
	reg [A_AW-1:0] exec_a_row_base_r;
	reg [B_AW-1:0] exec_b_row_base_r;
	reg        exec_m_wr_buf_r;
	reg [TILE_IDX_W-1:0] exec_m_tile_idx_r, exec_n_tile_idx_r;
	reg [3:0] exec_total_n_tiles_r;
	reg exec_single_output_r;
	reg exec_final_tile_r;
	reg [MATMUL_ACC_W-1:0] exec_total_accs_r;
	reg [15:0] exec_issue_cnt_r, exec_rsp_cnt_r;

	reg        drain_valid_r;
	reg [31:0] drain_id_r;
	reg        drain_m_wr_buf_r;
	reg        drain_chunking_r;
	reg [TILE_IDX_W-1:0] drain_m_tile_idx_r, drain_n_tile_idx_r;
	reg [3:0] drain_total_n_tiles_r;
	reg drain_single_output_r;
	reg drain_final_tile_r;
	reg        drain_shadow_valid_r;
	reg [31:0] drain_shadow_id_r;
	reg        drain_shadow_m_wr_buf_r;
	reg [TILE_IDX_W-1:0] drain_shadow_m_tile_idx_r, drain_shadow_n_tile_idx_r;
	reg [3:0] drain_shadow_total_n_tiles_r;
	reg drain_shadow_single_output_r;
	reg drain_shadow_final_tile_r;

	reg        macro_active_r;
	reg [31:0] macro_ctrl_r;
	reg [31:0] macro_id_r;
	reg        macro_a_buf_r;
	reg        macro_b_buf_r;
	reg [A_AW-1:0] macro_a_row_base_r;
	reg [B_AW-1:0] macro_b_row_base_r;
	reg        macro_m_wr_buf_r;
	reg [3:0] macro_m_tiles_r, macro_n_tiles_r, macro_k_tiles_r;
	reg [TILE_IDX_W-1:0] macro_next_m_tile_r, macro_next_n_tile_r;

	reg [2:0] add_state_r;
	reg [31:0] add_id_r;
	reg        add_b_buf_r;
	reg [B_AW-1:0] add_b_row_base_r;
	reg        add_m_src_buf_r;
	reg        add_m_wr_buf_r;
	reg [M_AW-1:0] add_row_idx_r;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] add_lhs_row_r, add_rhs_row_r;

	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] store_result_row_r;
	reg [M_AW-1:0] store_row_addr_r;
	reg store_row_last_r;
	reg [STORE_BASE_W-1:0] store_chunk_base_r;
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] ce_a_local_elem = ce_a_local_base[`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L];
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] ce_b_local_elem = ce_b_local_base[`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L];

	wire incoming_is_matmul = (ce_cmd_ctrl[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L] == `PT_OP_MATMUL);
	wire incoming_is_matadd = (ce_cmd_ctrl[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L] == `PT_OP_MATADD);
	wire [3:0] cmd_matmul_m_tiles = ce_cmd_ctrl[`PT_MATMUL_M_TILES_H:`PT_MATMUL_M_TILES_L];
	wire [3:0] cmd_matmul_n_tiles = ce_cmd_ctrl[`PT_MATMUL_N_TILES_H:`PT_MATMUL_N_TILES_L];
	wire [3:0] cmd_matmul_k_tiles = ce_cmd_ctrl[`PT_MATMUL_K_TILES_H:`PT_MATMUL_K_TILES_L];
	wire cmd_matadd_m_src_buf = ce_cmd_ctrl[`PT_MATADD_M_OFF_L+8];
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] cmd_a_row_base_full = ce_a_local_elem >> A_DIM_SHIFT;
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] cmd_b_row_base_full = ce_b_local_elem >> B_DIM_SHIFT;
	wire [A_AW-1:0] cmd_a_row_base = cmd_a_row_base_full[A_AW-1:0];
	wire [B_AW-1:0] cmd_b_row_base = cmd_b_row_base_full[B_AW-1:0];
	wire incoming_multitile_matmul = incoming_is_matmul &&
	                                ((cmd_matmul_m_tiles != `PT_TILES_1) || (cmd_matmul_n_tiles != `PT_TILES_1));
	wire cmd_single_output_tile = (cmd_matmul_m_tiles == `PT_TILES_1) && (cmd_matmul_n_tiles == `PT_TILES_1);
	wire cmd_macro_has_more_tiles = !cmd_single_output_tile;
	// In DRAIN_FULL_WIDTH mode, drain activates at exec launch and runs
	// concurrently with exec.  Count exec+drain as a single pipeline slot
	// so that the outstanding limit still works correctly.
	wire [1:0] drain_exec_count = DRAIN_FULL_WIDTH ?
	                              {1'b0, (exec_valid_r | drain_valid_r)} :
	                              ({1'b0, drain_valid_r} + {1'b0, exec_valid_r});
	wire [1:0] matmul_outstanding_count = drain_exec_count + {1'b0, shadow_valid_r};
	wire matmul_busy = (matmul_outstanding_count != 0);
	wire matadd_busy = (add_state_r != ADD_IDLE);
	wire shadow_launch_fire = !exec_valid_r &&
	                         (!DRAIN_FULL_WIDTH || !drain_shadow_valid_r) &&
	                         shadow_valid_r && !shadow_done_exec_r && gemm_start_ready;
	wire matmul_ready_for_cmd = !matadd_busy &&
	                            !macro_active_r &&
	                            (incoming_multitile_matmul ? !matmul_busy :
	                             ((matmul_outstanding_count < 2) &&
	                              (!shadow_valid_r || shadow_launch_fire)));
	wire matadd_ready_for_cmd = !matmul_busy && !macro_active_r && (add_state_r == ADD_IDLE);
	wire ce_cmd_fire_matmul = ce_cmd_valid && incoming_is_matmul && ce_cmd_ready;
	wire ce_cmd_fire_matadd = ce_cmd_valid && incoming_is_matadd && ce_cmd_ready;
	wire launch_cmd_direct_fire = ce_cmd_fire_matmul && !shadow_launch_fire && !exec_valid_r &&
	                              !(DRAIN_FULL_WIDTH && drain_valid_r) &&
	                              gemm_start_ready && !shadow_valid_r;
	wire shadow_store_cmd_fire = ce_cmd_fire_matmul && !launch_cmd_direct_fire;
	wire [3:0] launch_k_tiles = shadow_launch_fire ? shadow_ctrl_r[`PT_MATMUL_K_TILES_H:`PT_MATMUL_K_TILES_L] : cmd_matmul_k_tiles;
	wire [MATMUL_ACC_W-1:0] launch_total_accs = launch_k_tiles * K_WORDS_PER_TILE;
	wire [DATA_WIDTH-1:0] launch_total_accs_w = {{(DATA_WIDTH-MATMUL_ACC_W){1'b0}}, launch_total_accs};
	wire [DATA_WIDTH-1:0] exec_total_accs_w = {{(DATA_WIDTH-MATMUL_ACC_W){1'b0}}, exec_total_accs_r};

	wire mm_exec_rsp_valid = exec_valid_r && (exec_rsp_cnt_r < exec_issue_cnt_r);
	wire mm_exec_rsp_fire  = mm_exec_rsp_valid && gemm_a_ready && gemm_b_ready;
	wire mm_exec_req_fire  = exec_valid_r &&
	                         (exec_issue_cnt_r < exec_total_accs_r) &&
	                         ((exec_issue_cnt_r == 0) || mm_exec_rsp_fire);
	wire exec_complete_fire = exec_valid_r &&
	                          mm_exec_rsp_fire &&
	                          ((exec_rsp_cnt_r + 1'b1) >= exec_total_accs_r);

	wire drain_accept_ready = drain_valid_r && (DRAIN_FULL_WIDTH ? 1'b1 : !drain_chunking_r);
	wire drain_accept_fire  = drain_accept_ready && quant_m_valid;
	wire [STORE_BASE_W:0] store_chunk_base_ext = {1'b0, store_chunk_base_r};
	wire [STORE_BASE_W:0] store_chunk_limit = store_chunk_base_ext + M_WRITE_LANES_W;
	wire [31:0] store_chunk_base_u32 = {{(32-STORE_BASE_W){1'b0}}, store_chunk_base_r};
	wire [31:0] store_chunk_limit_u32 = {{(32-(STORE_BASE_W+1)){1'b0}}, store_chunk_limit};
	wire store_chunk_last = (store_chunk_limit >= GEMM_Y_DIM);
	wire drain_write_chunk_fire = drain_valid_r && !DRAIN_FULL_WIDTH && drain_chunking_r;
	wire drain_complete_fire = DRAIN_FULL_WIDTH ?
	                           (drain_accept_fire && quant_m_last) :
	                           (drain_write_chunk_fire && store_chunk_last && store_row_last_r);
	wire drain_slot_will_free = drain_valid_r && drain_complete_fire;
	// In DRAIN_FULL_WIDTH mode, drain is co-launched with exec, so there is
	// no separate promotion from exec to drain.  The legacy (chunked) path
	// still uses the sequential promotion.
	wire promote_exec_to_drain_fire = !DRAIN_FULL_WIDTH &&
	                                  exec_complete_fire &&
	                                  (!drain_valid_r || drain_slot_will_free);
	wire promote_shadow_done_to_drain_fire = !promote_exec_to_drain_fire &&
	                                         !DRAIN_FULL_WIDTH &&
	                                         shadow_valid_r &&
	                                         shadow_done_exec_r &&
	                                         (!drain_valid_r || drain_slot_will_free);

	wire add_send_fire = (add_state_r == ADD_SEND) && gema_in_ready;
	wire add_res_fire = (add_state_r == ADD_WAIT_RESULT) && add_m_valid;
	wire add_req_fire = (add_state_r == ADD_REQ) && !m_mem_wr_en;
	wire selected_m_buf_single_output = cmd_matadd_m_src_buf ? m_buf1_single_output : m_buf0_single_output;
	wire matadd_mwindow_multitile = incoming_is_matadd && !selected_m_buf_single_output;
	wire [31:0] drain_m_tile_idx_u32 = {{(32-TILE_IDX_W){1'b0}}, drain_m_tile_idx_r};
	wire [31:0] drain_n_tile_idx_u32 = {{(32-TILE_IDX_W){1'b0}}, drain_n_tile_idx_r};
	wire [31:0] drain_total_n_tiles_u32 = {{28{1'b0}}, drain_total_n_tiles_r};
	wire [31:0] macro_a_row_base_u32 = {{(32-A_AW){1'b0}}, macro_a_row_base_r};
	wire [31:0] macro_b_row_base_u32 = {{(32-B_AW){1'b0}}, macro_b_row_base_r};
	wire [31:0] macro_next_m_tile_u32 = {{(32-TILE_IDX_W){1'b0}}, macro_next_m_tile_r};
	wire [31:0] macro_next_n_tile_u32 = {{(32-TILE_IDX_W){1'b0}}, macro_next_n_tile_r};
	wire [31:0] macro_k_tiles_u32 = {{28{1'b0}}, macro_k_tiles_r};
	wire [31:0] drain_row_chunk_base =
		(drain_m_tile_idx_u32 * GEMM_X_DIM * drain_total_n_tiles_u32) + drain_n_tile_idx_u32;
	wire [31:0] drain_quant_store_addr = drain_row_chunk_base + (quant_m_idx * drain_total_n_tiles_u32);
	wire schedule_macro_shadow_fire = DRAIN_FULL_WIDTH ?
	                                 (exec_complete_fire && !exec_final_tile_r) :
	                                 (drain_complete_fire && !drain_final_tile_r);
	wire [31:0] macro_next_a_row_base_calc =
		macro_a_row_base_u32 + (macro_next_m_tile_u32 * (macro_k_tiles_u32 * K_WORDS_PER_TILE_U32));
	wire [31:0] macro_next_b_row_base_calc =
		macro_b_row_base_u32 + (macro_next_n_tile_u32 * (macro_k_tiles_u32 * K_WORDS_PER_TILE_U32));
	wire [31:0] macro_total_row_chunks_u32 = ({28'd0, macro_m_tiles_r} * {28'd0, macro_n_tiles_r}) * GEMM_X_DIM;
	wire [`PT_SIZE_W-1:0] macro_total_row_chunks = macro_total_row_chunks_u32[`PT_SIZE_W-1:0];
	wire macro_queued_final_tile =
		(macro_next_m_tile_r == (macro_m_tiles_r[TILE_IDX_W-1:0] - 1'b1)) &&
		(macro_next_n_tile_r == (macro_n_tiles_r[TILE_IDX_W-1:0] - 1'b1));
	wire macro_wrap_n_after_queue = ((macro_next_n_tile_r + 1'b1) >= macro_n_tiles_r[TILE_IDX_W-1:0]);
	wire [TILE_IDX_W-1:0] macro_after_queue_n_tile =
		macro_wrap_n_after_queue ? {TILE_IDX_W{1'b0}} : (macro_next_n_tile_r + 1'b1);
	wire [TILE_IDX_W-1:0] macro_after_queue_m_tile =
		macro_wrap_n_after_queue ? (macro_next_m_tile_r + 1'b1) : macro_next_m_tile_r;
	wire [31:0] launch_drain_id = shadow_launch_fire ? shadow_id_r : ce_cmd_id;
	wire launch_drain_m_wr_buf = shadow_launch_fire ? shadow_m_wr_buf_r : ce_m_wr_buf;
	wire [TILE_IDX_W-1:0] launch_drain_m_tile_idx = shadow_launch_fire ? shadow_m_tile_idx_r : {TILE_IDX_W{1'b0}};
	wire [TILE_IDX_W-1:0] launch_drain_n_tile_idx = shadow_launch_fire ? shadow_n_tile_idx_r : {TILE_IDX_W{1'b0}};
	wire [3:0] launch_drain_total_n_tiles = shadow_launch_fire ? shadow_total_n_tiles_r : cmd_matmul_n_tiles;
	wire launch_drain_single_output = shadow_launch_fire ? shadow_single_output_r : cmd_single_output_tile;
	wire launch_drain_final_tile = shadow_launch_fire ? shadow_final_tile_r : !cmd_macro_has_more_tiles;
	wire drain_queue_launch_fire = DRAIN_FULL_WIDTH && (launch_cmd_direct_fire || shadow_launch_fire) && drain_valid_r;
	wire drain_load_launch_fire = DRAIN_FULL_WIDTH && (launch_cmd_direct_fire || shadow_launch_fire) && !drain_valid_r;
	wire drain_load_exec_fire = promote_exec_to_drain_fire;
	wire drain_load_shadow_done_fire = promote_shadow_done_to_drain_fire;
	wire drain_load_shadow_fire = DRAIN_FULL_WIDTH && drain_complete_fire && drain_shadow_valid_r;
	wire drain_clear_fire = drain_complete_fire && !drain_load_shadow_fire;

	function is_pow2;
		input integer value;
		begin
			is_pow2 = (value > 0) ? (((value & (value - 1)) == 0) ? 1'b1 : 1'b0) : 1'b0;
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

// synthesis translate_off
	`ifndef SYNTHESIS
		initial begin
			if (!is_pow2(GEMM_X_DIM) || !is_pow2(GEMM_Y_DIM)) begin
				$fatal(1, "PT_CE_V3 requires power-of-two GEMM_X_DIM/GEMM_Y_DIM, got %0d x %0d", GEMM_X_DIM, GEMM_Y_DIM);
			end
			if ((PACK_LANES <= 0) || ((GEMM_X_DIM % PACK_LANES) != 0)) begin
				$fatal(1, "PT_CE_V3 requires GEMM_X_DIM %% PACK_LANES == 0, got X=%0d lanes=%0d", GEMM_X_DIM, PACK_LANES);
			end
			if ((M_WRITE_LANES <= 0) || (M_WRITE_LANES > GEMM_Y_DIM)) begin
				$fatal(1, "PT_CE_V2 requires 0 < M_WRITE_LANES <= GEMM_Y_DIM, got %0d for Y=%0d", M_WRITE_LANES, GEMM_Y_DIM);
			end
			if ((GEMM_Y_DIM % M_WRITE_LANES) != 0) begin
				$fatal(1, "PT_CE_V2 currently requires GEMM_Y_DIM %% M_WRITE_LANES == 0, got Y=%0d lanes=%0d", GEMM_Y_DIM, M_WRITE_LANES);
			end
		end
	`endif
// synthesis translate_on

	integer wi;

	assign ce_cmd_ready = incoming_is_matmul ? matmul_ready_for_cmd :
	                      (incoming_is_matadd ? matadd_ready_for_cmd : 1'b0);
	assign gemm_start   = shadow_launch_fire || launch_cmd_direct_fire;
	assign gemm_num_acc = gemm_start ? launch_total_accs_w : exec_total_accs_w;
	assign gemm_a_valid = mm_exec_rsp_valid;
	assign gemm_b_valid = mm_exec_rsp_valid;
	assign a_mem_rd_en  = mm_exec_req_fire;
	assign b_mem_rd_en  = mm_exec_req_fire || add_req_fire;
	assign exec_m_b_rd_en = add_req_fire;
	assign quant_m_ready = drain_accept_ready;
	assign add_m_ready   = (add_state_r == ADD_WAIT_RESULT);
	assign gema_lhs_data = add_lhs_row_r;
	assign gema_rhs_data = add_rhs_row_r;
	assign gema_in_idx   = {{(32-M_AW){1'b0}}, add_row_idx_r};
	assign gema_in_last  = (add_row_idx_r == (GEMM_X_DIM - 1));
	assign gema_in_valid = (add_state_r == ADD_SEND);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			shadow_valid_r      <= 1'b0;
			shadow_done_exec_r  <= 1'b0;
			shadow_ctrl_r       <= 32'd0;
			shadow_id_r         <= 32'd0;
			shadow_a_buf_r      <= 1'b0;
			shadow_b_buf_r      <= 1'b0;
			shadow_a_row_base_r <= {A_AW{1'b0}};
			shadow_b_row_base_r <= {B_AW{1'b0}};
			shadow_m_wr_buf_r   <= 1'b0;
			shadow_m_tile_idx_r <= {TILE_IDX_W{1'b0}};
			shadow_n_tile_idx_r <= {TILE_IDX_W{1'b0}};
			shadow_total_n_tiles_r <= `PT_TILES_1;
			shadow_single_output_r <= 1'b1;
			shadow_final_tile_r <= 1'b1;
			exec_valid_r        <= 1'b0;
			exec_ctrl_r         <= 32'd0;
			exec_id_r           <= 32'd0;
			exec_a_buf_r        <= 1'b0;
			exec_b_buf_r        <= 1'b0;
			exec_a_row_base_r   <= {A_AW{1'b0}};
			exec_b_row_base_r   <= {B_AW{1'b0}};
			exec_m_wr_buf_r     <= 1'b0;
			exec_m_tile_idx_r   <= {TILE_IDX_W{1'b0}};
			exec_n_tile_idx_r   <= {TILE_IDX_W{1'b0}};
			exec_total_n_tiles_r <= `PT_TILES_1;
			exec_single_output_r <= 1'b1;
			exec_final_tile_r   <= 1'b1;
			exec_total_accs_r   <= {MATMUL_ACC_W{1'b0}};
			exec_issue_cnt_r    <= 16'd0;
			exec_rsp_cnt_r      <= 16'd0;
			drain_valid_r       <= 1'b0;
			drain_id_r          <= 32'd0;
			drain_m_wr_buf_r    <= 1'b0;
			drain_chunking_r    <= 1'b0;
			drain_m_tile_idx_r  <= {TILE_IDX_W{1'b0}};
			drain_n_tile_idx_r  <= {TILE_IDX_W{1'b0}};
			drain_total_n_tiles_r <= `PT_TILES_1;
			drain_single_output_r <= 1'b1;
			drain_final_tile_r  <= 1'b1;
			drain_shadow_valid_r <= 1'b0;
			drain_shadow_id_r   <= 32'd0;
			drain_shadow_m_wr_buf_r <= 1'b0;
			drain_shadow_m_tile_idx_r <= {TILE_IDX_W{1'b0}};
			drain_shadow_n_tile_idx_r <= {TILE_IDX_W{1'b0}};
			drain_shadow_total_n_tiles_r <= `PT_TILES_1;
			drain_shadow_single_output_r <= 1'b1;
			drain_shadow_final_tile_r <= 1'b1;
			macro_active_r      <= 1'b0;
			macro_ctrl_r        <= 32'd0;
			macro_id_r          <= 32'd0;
			macro_a_buf_r       <= 1'b0;
			macro_b_buf_r       <= 1'b0;
			macro_a_row_base_r  <= {A_AW{1'b0}};
			macro_b_row_base_r  <= {B_AW{1'b0}};
			macro_m_wr_buf_r    <= 1'b0;
			macro_m_tiles_r     <= `PT_TILES_1;
			macro_n_tiles_r     <= `PT_TILES_1;
			macro_k_tiles_r     <= `PT_TILES_1;
			macro_next_m_tile_r <= {TILE_IDX_W{1'b0}};
			macro_next_n_tile_r <= {TILE_IDX_W{1'b0}};
			add_state_r         <= ADD_IDLE;
			add_id_r            <= 32'd0;
			add_b_buf_r         <= 1'b0;
			add_b_row_base_r    <= {B_AW{1'b0}};
			add_m_src_buf_r     <= 1'b0;
			add_m_wr_buf_r      <= 1'b0;
			add_row_idx_r       <= {M_AW{1'b0}};
			add_lhs_row_r       <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			add_rhs_row_r       <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_result_row_r  <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_row_addr_r    <= {M_AW{1'b0}};
			store_row_last_r    <= 1'b0;
			store_chunk_base_r  <= {STORE_BASE_W{1'b0}};
			exec_a_buf          <= 1'b0;
			exec_a_addr         <= {A_AW{1'b0}};
			exec_b_buf          <= 1'b0;
			exec_b_addr         <= {B_AW{1'b0}};
			exec_m_b_buf        <= 1'b0;
			exec_m_b_addr       <= {M_AW{1'b0}};
			m_mem_wr_en         <= 1'b0;
			m_mem_wr_buf        <= 1'b0;
			m_mem_wr_mask       <= {GEMM_Y_DIM{1'b0}};
			m_mem_wr_addr       <= {M_AW{1'b0}};
			m_mem_wr_data       <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			ce_resp_valid       <= 1'b0;
			ce_resp             <= 32'd0;
			ce_resp_row_chunk_count <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			ce_resp_single_output <= 1'b1;
			ce_irq              <= 1'b0;
		end else if (clear) begin
			shadow_valid_r      <= 1'b0;
			shadow_done_exec_r  <= 1'b0;
			shadow_ctrl_r       <= 32'd0;
			shadow_id_r         <= 32'd0;
			shadow_a_buf_r      <= 1'b0;
			shadow_b_buf_r      <= 1'b0;
			shadow_a_row_base_r <= {A_AW{1'b0}};
			shadow_b_row_base_r <= {B_AW{1'b0}};
			shadow_m_wr_buf_r   <= 1'b0;
			shadow_m_tile_idx_r <= {TILE_IDX_W{1'b0}};
			shadow_n_tile_idx_r <= {TILE_IDX_W{1'b0}};
			shadow_total_n_tiles_r <= `PT_TILES_1;
			shadow_single_output_r <= 1'b1;
			shadow_final_tile_r <= 1'b1;
			exec_valid_r        <= 1'b0;
			exec_ctrl_r         <= 32'd0;
			exec_id_r           <= 32'd0;
			exec_a_buf_r        <= 1'b0;
			exec_b_buf_r        <= 1'b0;
			exec_a_row_base_r   <= {A_AW{1'b0}};
			exec_b_row_base_r   <= {B_AW{1'b0}};
			exec_m_wr_buf_r     <= 1'b0;
			exec_m_tile_idx_r   <= {TILE_IDX_W{1'b0}};
			exec_n_tile_idx_r   <= {TILE_IDX_W{1'b0}};
			exec_total_n_tiles_r <= `PT_TILES_1;
			exec_single_output_r <= 1'b1;
			exec_final_tile_r   <= 1'b1;
			exec_total_accs_r   <= {MATMUL_ACC_W{1'b0}};
			exec_issue_cnt_r    <= 16'd0;
			exec_rsp_cnt_r      <= 16'd0;
			drain_valid_r       <= 1'b0;
			drain_id_r          <= 32'd0;
			drain_m_wr_buf_r    <= 1'b0;
			drain_chunking_r    <= 1'b0;
			drain_m_tile_idx_r  <= {TILE_IDX_W{1'b0}};
			drain_n_tile_idx_r  <= {TILE_IDX_W{1'b0}};
			drain_total_n_tiles_r <= `PT_TILES_1;
			drain_single_output_r <= 1'b1;
			drain_final_tile_r  <= 1'b1;
			drain_shadow_valid_r <= 1'b0;
			drain_shadow_id_r   <= 32'd0;
			drain_shadow_m_wr_buf_r <= 1'b0;
			drain_shadow_m_tile_idx_r <= {TILE_IDX_W{1'b0}};
			drain_shadow_n_tile_idx_r <= {TILE_IDX_W{1'b0}};
			drain_shadow_total_n_tiles_r <= `PT_TILES_1;
			drain_shadow_single_output_r <= 1'b1;
			drain_shadow_final_tile_r <= 1'b1;
			macro_active_r      <= 1'b0;
			macro_ctrl_r        <= 32'd0;
			macro_id_r          <= 32'd0;
			macro_a_buf_r       <= 1'b0;
			macro_b_buf_r       <= 1'b0;
			macro_a_row_base_r  <= {A_AW{1'b0}};
			macro_b_row_base_r  <= {B_AW{1'b0}};
			macro_m_wr_buf_r    <= 1'b0;
			macro_m_tiles_r     <= `PT_TILES_1;
			macro_n_tiles_r     <= `PT_TILES_1;
			macro_k_tiles_r     <= `PT_TILES_1;
			macro_next_m_tile_r <= {TILE_IDX_W{1'b0}};
			macro_next_n_tile_r <= {TILE_IDX_W{1'b0}};
			add_state_r         <= ADD_IDLE;
			add_id_r            <= 32'd0;
			add_b_buf_r         <= 1'b0;
			add_b_row_base_r    <= {B_AW{1'b0}};
			add_m_src_buf_r     <= 1'b0;
			add_m_wr_buf_r      <= 1'b0;
			add_row_idx_r       <= {M_AW{1'b0}};
			add_lhs_row_r       <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			add_rhs_row_r       <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_result_row_r  <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_row_addr_r    <= {M_AW{1'b0}};
			store_row_last_r    <= 1'b0;
			store_chunk_base_r  <= {STORE_BASE_W{1'b0}};
			exec_a_buf          <= 1'b0;
			exec_a_addr         <= {A_AW{1'b0}};
			exec_b_buf          <= 1'b0;
			exec_b_addr         <= {B_AW{1'b0}};
			exec_m_b_buf        <= 1'b0;
			exec_m_b_addr       <= {M_AW{1'b0}};
			m_mem_wr_en         <= 1'b0;
			m_mem_wr_buf        <= 1'b0;
			m_mem_wr_mask       <= {GEMM_Y_DIM{1'b0}};
			m_mem_wr_addr       <= {M_AW{1'b0}};
			m_mem_wr_data       <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			ce_resp_valid       <= 1'b0;
			ce_resp             <= 32'd0;
			ce_resp_row_chunk_count <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			ce_resp_single_output <= 1'b1;
			ce_irq              <= 1'b0;
		end else begin
			ce_resp_valid <= 1'b0;
			ce_irq        <= 1'b0;
			ce_resp_row_chunk_count <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			ce_resp_single_output <= 1'b1;
			m_mem_wr_en   <= 1'b0;
			m_mem_wr_mask <= {GEMM_Y_DIM{1'b0}};

			if (schedule_macro_shadow_fire) begin
				shadow_valid_r      <= 1'b1;
				shadow_done_exec_r  <= 1'b0;
				shadow_ctrl_r       <= macro_ctrl_r;
				shadow_id_r         <= macro_id_r;
				shadow_a_buf_r      <= macro_a_buf_r;
				shadow_b_buf_r      <= macro_b_buf_r;
				shadow_a_row_base_r <= macro_next_a_row_base_calc[A_AW-1:0];
				shadow_b_row_base_r <= macro_next_b_row_base_calc[B_AW-1:0];
				shadow_m_wr_buf_r   <= macro_m_wr_buf_r;
				shadow_m_tile_idx_r <= macro_next_m_tile_r;
				shadow_n_tile_idx_r <= macro_next_n_tile_r;
				shadow_total_n_tiles_r <= macro_n_tiles_r;
				shadow_single_output_r <= 1'b0;
				shadow_final_tile_r <= macro_queued_final_tile;
				macro_next_m_tile_r <= macro_after_queue_m_tile;
				macro_next_n_tile_r <= macro_after_queue_n_tile;
			end else if (shadow_launch_fire) begin
				if (shadow_store_cmd_fire) begin
					shadow_valid_r      <= 1'b1;
					shadow_done_exec_r  <= 1'b0;
					shadow_ctrl_r       <= ce_cmd_ctrl;
					shadow_id_r         <= ce_cmd_id;
					shadow_a_buf_r      <= ce_a_local_base[`PT_LOCAL_BUF_BIT];
					shadow_b_buf_r      <= ce_b_local_base[`PT_LOCAL_BUF_BIT];
					shadow_a_row_base_r <= cmd_a_row_base;
					shadow_b_row_base_r <= cmd_b_row_base;
					shadow_m_wr_buf_r   <= ce_m_wr_buf;
					shadow_m_tile_idx_r <= {TILE_IDX_W{1'b0}};
					shadow_n_tile_idx_r <= {TILE_IDX_W{1'b0}};
					shadow_total_n_tiles_r <= cmd_matmul_n_tiles;
					shadow_single_output_r <= cmd_single_output_tile;
					shadow_final_tile_r <= !cmd_macro_has_more_tiles;
				end else begin
					shadow_valid_r <= 1'b0;
				end
			end else if (!DRAIN_FULL_WIDTH && exec_complete_fire && !promote_exec_to_drain_fire) begin
				shadow_valid_r      <= 1'b1;
				shadow_done_exec_r  <= 1'b1;
				shadow_ctrl_r       <= exec_ctrl_r;
				shadow_id_r         <= exec_id_r;
				shadow_a_buf_r      <= exec_a_buf_r;
				shadow_b_buf_r      <= exec_b_buf_r;
				shadow_a_row_base_r <= exec_a_row_base_r;
				shadow_b_row_base_r <= exec_b_row_base_r;
				shadow_m_wr_buf_r   <= exec_m_wr_buf_r;
				shadow_m_tile_idx_r <= exec_m_tile_idx_r;
				shadow_n_tile_idx_r <= exec_n_tile_idx_r;
				shadow_total_n_tiles_r <= exec_total_n_tiles_r;
				shadow_single_output_r <= exec_single_output_r;
				shadow_final_tile_r <= exec_final_tile_r;
			end else if (promote_shadow_done_to_drain_fire) begin
				shadow_valid_r <= 1'b0;
			end else if (shadow_store_cmd_fire) begin
				shadow_valid_r      <= 1'b1;
				shadow_done_exec_r  <= 1'b0;
				shadow_ctrl_r       <= ce_cmd_ctrl;
				shadow_id_r         <= ce_cmd_id;
				shadow_a_buf_r      <= ce_a_local_base[`PT_LOCAL_BUF_BIT];
				shadow_b_buf_r      <= ce_b_local_base[`PT_LOCAL_BUF_BIT];
				shadow_a_row_base_r <= cmd_a_row_base;
				shadow_b_row_base_r <= cmd_b_row_base;
				shadow_m_wr_buf_r   <= ce_m_wr_buf;
				shadow_m_tile_idx_r <= {TILE_IDX_W{1'b0}};
				shadow_n_tile_idx_r <= {TILE_IDX_W{1'b0}};
				shadow_total_n_tiles_r <= cmd_matmul_n_tiles;
				shadow_single_output_r <= cmd_single_output_tile;
				shadow_final_tile_r <= !cmd_macro_has_more_tiles;
			end

			if (ce_cmd_fire_matmul && cmd_macro_has_more_tiles) begin
				macro_active_r      <= 1'b1;
				macro_ctrl_r        <= ce_cmd_ctrl;
				macro_id_r          <= ce_cmd_id;
				macro_a_buf_r       <= ce_a_local_base[`PT_LOCAL_BUF_BIT];
				macro_b_buf_r       <= ce_b_local_base[`PT_LOCAL_BUF_BIT];
				macro_a_row_base_r  <= cmd_a_row_base;
				macro_b_row_base_r  <= cmd_b_row_base;
				macro_m_wr_buf_r    <= ce_m_wr_buf;
				macro_m_tiles_r     <= cmd_matmul_m_tiles;
				macro_n_tiles_r     <= cmd_matmul_n_tiles;
				macro_k_tiles_r     <= cmd_matmul_k_tiles;
				macro_next_m_tile_r <= (cmd_matmul_n_tiles == `PT_TILES_1) ? {{(TILE_IDX_W-1){1'b0}}, 1'b1} : {TILE_IDX_W{1'b0}};
				macro_next_n_tile_r <= (cmd_matmul_n_tiles == `PT_TILES_1) ? {TILE_IDX_W{1'b0}} : {{(TILE_IDX_W-1){1'b0}}, 1'b1};
			end else if (drain_complete_fire && drain_final_tile_r) begin
				macro_active_r <= 1'b0;
			end

				if (launch_cmd_direct_fire || shadow_launch_fire) begin
					exec_valid_r      <= 1'b1;
				exec_ctrl_r       <= shadow_launch_fire ? shadow_ctrl_r : ce_cmd_ctrl;
				exec_id_r         <= shadow_launch_fire ? shadow_id_r : ce_cmd_id;
				exec_a_buf_r      <= shadow_launch_fire ? shadow_a_buf_r : ce_a_local_base[`PT_LOCAL_BUF_BIT];
				exec_b_buf_r      <= shadow_launch_fire ? shadow_b_buf_r : ce_b_local_base[`PT_LOCAL_BUF_BIT];
				exec_a_row_base_r <= shadow_launch_fire ? shadow_a_row_base_r : cmd_a_row_base;
				exec_b_row_base_r <= shadow_launch_fire ? shadow_b_row_base_r : cmd_b_row_base;
				exec_m_wr_buf_r   <= shadow_launch_fire ? shadow_m_wr_buf_r : ce_m_wr_buf;
				exec_m_tile_idx_r <= shadow_launch_fire ? shadow_m_tile_idx_r : {TILE_IDX_W{1'b0}};
				exec_n_tile_idx_r <= shadow_launch_fire ? shadow_n_tile_idx_r : {TILE_IDX_W{1'b0}};
				exec_total_n_tiles_r <= shadow_launch_fire ? shadow_total_n_tiles_r : cmd_matmul_n_tiles;
				exec_single_output_r <= shadow_launch_fire ? shadow_single_output_r : cmd_single_output_tile;
				exec_final_tile_r <= shadow_launch_fire ? shadow_final_tile_r : !cmd_macro_has_more_tiles;
				exec_total_accs_r <= launch_total_accs;
				exec_issue_cnt_r  <= 16'd0;
				exec_rsp_cnt_r    <= 16'd0;
				exec_a_buf        <= shadow_launch_fire ? shadow_a_buf_r : ce_a_local_base[`PT_LOCAL_BUF_BIT];
				exec_b_buf        <= shadow_launch_fire ? shadow_b_buf_r : ce_b_local_base[`PT_LOCAL_BUF_BIT];
				exec_a_addr       <= shadow_launch_fire ? shadow_a_row_base_r : cmd_a_row_base;
				exec_b_addr       <= shadow_launch_fire ? shadow_b_row_base_r : cmd_b_row_base;
				// In DRAIN_FULL_WIDTH mode, co-launch drain so it can accept
				// quant results while exec is still feeding A/B rows.
				end else if (exec_valid_r) begin
				if (mm_exec_req_fire) begin
					exec_issue_cnt_r <= exec_issue_cnt_r + 1'b1;
					if ((exec_issue_cnt_r + 1'b1) < exec_total_accs_r) begin
						exec_a_addr <= exec_a_row_base_r + exec_issue_cnt_r[A_AW-1:0] + 1'b1;
						exec_b_addr <= exec_b_row_base_r + exec_issue_cnt_r[B_AW-1:0] + 1'b1;
					end
				end
				if (mm_exec_rsp_fire) begin
					exec_rsp_cnt_r <= exec_rsp_cnt_r + 1'b1;
				end
				if (exec_complete_fire) begin
					exec_valid_r <= 1'b0;
				end
			end

				if (drain_queue_launch_fire) begin
					drain_shadow_valid_r <= 1'b1;
					drain_shadow_id_r <= launch_drain_id;
					drain_shadow_m_wr_buf_r <= launch_drain_m_wr_buf;
					drain_shadow_m_tile_idx_r <= launch_drain_m_tile_idx;
					drain_shadow_n_tile_idx_r <= launch_drain_n_tile_idx;
					drain_shadow_total_n_tiles_r <= launch_drain_total_n_tiles;
					drain_shadow_single_output_r <= launch_drain_single_output;
					drain_shadow_final_tile_r <= launch_drain_final_tile;
				end else if (drain_load_shadow_fire) begin
					drain_shadow_valid_r <= 1'b0;
				end

				if (drain_load_launch_fire || drain_load_exec_fire || drain_load_shadow_done_fire || drain_load_shadow_fire) begin
					drain_valid_r <= 1'b1;
					drain_chunking_r <= 1'b0;
					store_chunk_base_r <= {STORE_BASE_W{1'b0}};
					if (drain_load_shadow_fire) begin
						drain_id_r <= drain_shadow_id_r;
						drain_m_wr_buf_r <= drain_shadow_m_wr_buf_r;
						drain_m_tile_idx_r <= drain_shadow_m_tile_idx_r;
						drain_n_tile_idx_r <= drain_shadow_n_tile_idx_r;
						drain_total_n_tiles_r <= drain_shadow_total_n_tiles_r;
						drain_single_output_r <= drain_shadow_single_output_r;
						drain_final_tile_r <= drain_shadow_final_tile_r;
					end else if (drain_load_shadow_done_fire) begin
						drain_id_r <= shadow_id_r;
						drain_m_wr_buf_r <= shadow_m_wr_buf_r;
						drain_m_tile_idx_r <= shadow_m_tile_idx_r;
						drain_n_tile_idx_r <= shadow_n_tile_idx_r;
						drain_total_n_tiles_r <= shadow_total_n_tiles_r;
						drain_single_output_r <= shadow_single_output_r;
						drain_final_tile_r <= shadow_final_tile_r;
					end else if (drain_load_exec_fire) begin
						drain_id_r <= exec_id_r;
						drain_m_wr_buf_r <= exec_m_wr_buf_r;
						drain_m_tile_idx_r <= exec_m_tile_idx_r;
						drain_n_tile_idx_r <= exec_n_tile_idx_r;
						drain_total_n_tiles_r <= exec_total_n_tiles_r;
						drain_single_output_r <= exec_single_output_r;
						drain_final_tile_r <= exec_final_tile_r;
					end else begin
						drain_id_r <= launch_drain_id;
						drain_m_wr_buf_r <= launch_drain_m_wr_buf;
						drain_m_tile_idx_r <= launch_drain_m_tile_idx;
						drain_n_tile_idx_r <= launch_drain_n_tile_idx;
						drain_total_n_tiles_r <= launch_drain_total_n_tiles;
						drain_single_output_r <= launch_drain_single_output;
						drain_final_tile_r <= launch_drain_final_tile;
					end
				end else if (drain_clear_fire) begin
					drain_valid_r <= 1'b0;
					drain_chunking_r <= 1'b0;
				end

			if (drain_valid_r) begin
				if (DRAIN_FULL_WIDTH) begin
					if (drain_accept_fire) begin
						m_mem_wr_en   <= 1'b1;
						m_mem_wr_buf  <= drain_m_wr_buf_r;
						m_mem_wr_mask <= {GEMM_Y_DIM{1'b1}};
						m_mem_wr_addr <= drain_quant_store_addr[M_AW-1:0];
						m_mem_wr_data <= quant_m_data;
						if (quant_m_last) begin
							if (drain_final_tile_r) begin
								ce_resp       <= pack_resp(1'b0, drain_m_wr_buf_r, drain_id_r);
								ce_resp_valid <= 1'b1;
								ce_resp_row_chunk_count <= drain_single_output_r ?
								                           GEMM_X_DIM[`PT_SIZE_W-1:0] :
								                           macro_total_row_chunks;
								ce_resp_single_output <= drain_single_output_r;
								ce_irq        <= 1'b1;
							end
						end
					end
				end else if (!drain_chunking_r) begin
					if (drain_accept_fire) begin
						store_result_row_r <= quant_m_data;
						store_row_addr_r   <= drain_quant_store_addr[M_AW-1:0];
						store_row_last_r   <= quant_m_last;
						store_chunk_base_r <= {STORE_BASE_W{1'b0}};
						drain_chunking_r   <= 1'b1;
					end
				end else begin
					m_mem_wr_en   <= 1'b1;
					m_mem_wr_buf  <= drain_m_wr_buf_r;
					m_mem_wr_mask <= {GEMM_Y_DIM{1'b0}};
					m_mem_wr_addr <= store_row_addr_r;
					m_mem_wr_data <= store_result_row_r;
					for (wi = 0; wi < GEMM_Y_DIM; wi = wi + 1) begin
						if ((wi >= store_chunk_base_u32) && (wi < store_chunk_limit_u32)) begin
							m_mem_wr_mask[wi] <= 1'b1;
						end
					end
					if (store_chunk_last) begin
						drain_chunking_r <= 1'b0;
						if (store_row_last_r) begin
							if (drain_final_tile_r) begin
								ce_resp       <= pack_resp(1'b0, drain_m_wr_buf_r, drain_id_r);
								ce_resp_valid <= 1'b1;
								ce_resp_row_chunk_count <= drain_single_output_r ?
								                           GEMM_X_DIM[`PT_SIZE_W-1:0] :
								                           macro_total_row_chunks;
								ce_resp_single_output <= drain_single_output_r;
								ce_irq        <= 1'b1;
							end
						end
					end else begin
						store_chunk_base_r <= store_chunk_base_r + M_WRITE_LANES;
					end
				end
			end

			if (ce_cmd_fire_matadd) begin
				if (matadd_mwindow_multitile) begin
					ce_resp       <= pack_resp(1'b1, 1'b0, ce_cmd_id);
					ce_resp_valid <= 1'b1;
					ce_irq        <= 1'b1;
				end else begin
					add_state_r      <= ADD_REQ;
					add_id_r         <= ce_cmd_id;
					add_b_buf_r      <= ce_b_local_base[`PT_LOCAL_BUF_BIT];
					add_b_row_base_r <= cmd_b_row_base;
					add_m_src_buf_r  <= cmd_matadd_m_src_buf;
					add_m_wr_buf_r   <= ce_m_wr_buf;
					add_row_idx_r    <= {M_AW{1'b0}};
					exec_b_buf       <= ce_b_local_base[`PT_LOCAL_BUF_BIT];
					exec_b_addr      <= cmd_b_row_base;
					exec_m_b_buf     <= cmd_matadd_m_src_buf;
					exec_m_b_addr    <= {M_AW{1'b0}};
				end
			end else begin
				case (add_state_r)
					ADD_IDLE: begin
					end

					ADD_REQ: begin
						if (add_req_fire) begin
							add_state_r <= ADD_CAPTURE;
						end
					end

					ADD_CAPTURE: begin
						add_lhs_row_r <= m_mem_row_data;
						add_rhs_row_r <= b_mem_row_data;
						add_state_r   <= ADD_SEND;
					end

					ADD_SEND: begin
						if (add_send_fire) begin
							if (add_row_idx_r != (GEMM_X_DIM - 1)) begin
								add_row_idx_r <= add_row_idx_r + 1'b1;
							end
							add_state_r <= ADD_WAIT_RESULT;
						end
					end

					ADD_WAIT_RESULT: begin
						if (add_res_fire) begin
							store_result_row_r <= add_m_data;
							store_row_addr_r   <= add_m_idx[M_AW-1:0];
							store_row_last_r   <= add_m_last;
							store_chunk_base_r <= {STORE_BASE_W{1'b0}};
							add_state_r        <= ADD_STORE;
						end
					end

					ADD_STORE: begin
						m_mem_wr_en   <= 1'b1;
						m_mem_wr_buf  <= add_m_wr_buf_r;
						m_mem_wr_mask <= {GEMM_Y_DIM{1'b0}};
						m_mem_wr_addr <= store_row_addr_r;
						m_mem_wr_data <= store_result_row_r;
						for (wi = 0; wi < GEMM_Y_DIM; wi = wi + 1) begin
							if ((wi >= store_chunk_base_u32) && (wi < store_chunk_limit_u32)) begin
								m_mem_wr_mask[wi] <= 1'b1;
							end
						end
						if (store_chunk_last) begin
							if (store_row_last_r) begin
								ce_resp       <= pack_resp(1'b0, add_m_wr_buf_r, add_id_r);
								ce_resp_valid <= 1'b1;
								ce_resp_row_chunk_count <= GEMM_X_DIM[`PT_SIZE_W-1:0];
								ce_resp_single_output <= 1'b1;
								ce_irq        <= 1'b1;
								add_state_r   <= ADD_IDLE;
							end else begin
								exec_b_buf   <= add_b_buf_r;
								exec_b_addr  <= add_b_row_base_r + add_row_idx_r[B_AW-1:0];
								exec_m_b_buf <= add_m_src_buf_r;
								exec_m_b_addr <= add_row_idx_r;
								add_state_r  <= ADD_REQ;
							end
						end else begin
							store_chunk_base_r <= store_chunk_base_r + M_WRITE_LANES;
						end
					end

					default: begin
						add_state_r <= ADD_IDLE;
					end
				endcase
			end
		end
	end

endmodule
