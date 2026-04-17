`include "param.vh"

module PT_MALLOC #(
	parameter GEMM_X_DIM   = 4,
	parameter GEMM_Y_DIM   = 4,
	parameter LUT_DEPTH    = 8,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,

	input  wire                       malloc_cmd_valid,
	output wire                       malloc_cmd_ready,
	input  wire [`PT_MALLOC_KIND_W-1:0] malloc_cmd_kind,
	input  wire [`INST_WIDTH-1:0]     malloc_cmd_inst,
	input  wire [31:0]                malloc_cmd_id,

	output wire                       fill_req_valid,
	input  wire                       fill_req_ready,
	output wire [`PT_DMA_KIND_W-1:0]  fill_req_kind,
	output wire [31:0]                fill_req_id,
	output wire [`PT_LOCAL_ADDR_W-1:0] fill_req_local_base,
	output wire [`PT_SIZE_W-1:0]      fill_req_len,
	output wire [3:0]                 fill_req_m_tiles,
	output wire [3:0]                 fill_req_n_tiles,
	output wire [3:0]                 fill_req_k_tiles,

	input  wire                       fill_done_valid,
	input  wire [`PT_DMA_KIND_W-1:0]  fill_done_kind,
	input  wire [31:0]                fill_done_id,
	input  wire                       fill_done_err,

	output wire                       ce_cmd_valid,
	input  wire                       ce_cmd_ready,
	output wire [`INST_WIDTH-1:0]     ce_cmd_ctrl,
	output wire [31:0]                ce_cmd_id,
	output wire [`PT_LOCAL_ADDR_W-1:0] ce_a_local_base,
	output wire [`PT_LOCAL_ADDR_W-1:0] ce_b_local_base,
	output wire                       ce_m_wr_buf,
	input  wire                       m_alloc_ready,
	input  wire                       m_alloc_buf,
	output wire                       m_alloc_take,
	input  wire                       m_buf0_single_output,
	input  wire                       m_buf1_single_output,

	input  wire                       ce_resp_valid,
	input  wire [31:0]                ce_resp,

	output reg                        malloc_resp_valid,
	output reg  [31:0]                malloc_resp,
	output reg                        malloc_irq,
	output wire                       exec_busy,
	output wire                       serial_exec_busy
);

	localparam integer LUT_AW = (LUT_DEPTH <= 1) ? 1 : $clog2(LUT_DEPTH);
	localparam integer A_TILE_LEN = GEMM_X_DIM * GEMM_X_DIM;
	localparam integer B_TILE_LEN = GEMM_Y_DIM * GEMM_Y_DIM;
	localparam integer A_CAPACITY = A_BANK_DEPTH * A_TILE_LEN;
	localparam integer B_CAPACITY = B_BANK_DEPTH * B_TILE_LEN;
	localparam integer A_PTR_W = ((2 * A_CAPACITY) <= 1) ? 1 : $clog2((2 * A_CAPACITY) + 1);
	localparam integer B_PTR_W = ((2 * B_CAPACITY) <= 1) ? 1 : $clog2((2 * B_CAPACITY) + 1);

	localparam [3:0] ST_IDLE        = 4'd0;
	localparam [3:0] ST_FILL_REQ_A  = 4'd1;
	localparam [3:0] ST_FILL_WAIT_A = 4'd2;
	localparam [3:0] ST_FILL_REQ_B  = 4'd3;
	localparam [3:0] ST_FILL_WAIT_B = 4'd4;
	localparam [3:0] ST_CE_REQ      = 4'd5;
	localparam [3:0] ST_CE_WAIT     = 4'd6;
	localparam [3:0] ST_RESP        = 4'd7;

	reg [3:0] state_r;
	reg [3:0] state_n;

	reg        lut_valid [0:LUT_DEPTH-1];
	reg [31:0] lut_id [0:LUT_DEPTH-1];
	reg        lut_a_valid [0:LUT_DEPTH-1];
	reg [`PT_LOCAL_ADDR_W-1:0] lut_a_base [0:LUT_DEPTH-1];
	reg [`PT_SIZE_W-1:0] lut_a_len [0:LUT_DEPTH-1];
	reg [3:0] lut_a_m_tiles [0:LUT_DEPTH-1];
	reg [3:0] lut_a_k_tiles [0:LUT_DEPTH-1];
	reg        lut_b_valid [0:LUT_DEPTH-1];
	reg        lut_b_is_c [0:LUT_DEPTH-1];
	reg [`PT_LOCAL_ADDR_W-1:0] lut_b_base [0:LUT_DEPTH-1];
	reg [`PT_SIZE_W-1:0] lut_b_len [0:LUT_DEPTH-1];
	reg [3:0] lut_b_k_tiles [0:LUT_DEPTH-1];
	reg [3:0] lut_b_n_tiles [0:LUT_DEPTH-1];

	reg [A_PTR_W-1:0] a_alloc_next_r;
	reg [B_PTR_W-1:0] b_alloc_next_r;

	reg [`PT_MALLOC_KIND_W-1:0] active_kind_r;
	reg [`INST_WIDTH-1:0]       active_inst_r;
	reg [31:0]                  active_id_r;
	reg [LUT_AW-1:0]            active_slot_idx_r;
	reg                         active_need_a_fill_r;
	reg                         active_need_b_fill_r;
	reg                         active_b_is_c_r;
	reg [3:0]                   active_m_tiles_r;
	reg [3:0]                   active_n_tiles_r;
	reg [3:0]                   active_k_tiles_r;
	reg [`PT_LOCAL_ADDR_W-1:0]  active_a_base_r;
	reg [`PT_LOCAL_ADDR_W-1:0]  active_b_base_r;
	reg [`PT_SIZE_W-1:0]        active_a_len_r;
	reg [`PT_SIZE_W-1:0]        active_b_len_r;
	reg [A_PTR_W-1:0]           active_a_alloc_next_r;
	reg [B_PTR_W-1:0]           active_b_alloc_next_r;
	reg [31:0]                  resp_word_r;
	reg                         resp_irq_r;
	reg [1:0]                   matmul_inflight_count_r;
	reg                         serial_exec_busy_r;

	reg                         slot_found;
	reg [LUT_AW-1:0]            slot_idx;
	reg                         free_found;
	reg [LUT_AW-1:0]            free_idx;

	reg                         cmd_error;
	reg                         cmd_need_a_fill;
	reg                         cmd_need_b_fill;
	reg                         cmd_b_is_c;
	reg                         dec_error;
	reg                         dec_need_a;
	reg                         dec_need_b;
	reg                         dec_b_is_c;
	reg [3:0]                   dec_m_tiles;
	reg [3:0]                   dec_n_tiles;
	reg [3:0]                   dec_k_tiles;
	reg [LUT_AW-1:0]            cmd_slot_idx;
	reg [`PT_LOCAL_ADDR_W-1:0]  cmd_a_base;
	reg [`PT_LOCAL_ADDR_W-1:0]  cmd_b_base;
	reg [`PT_SIZE_W-1:0]        cmd_a_len;
	reg [`PT_SIZE_W-1:0]        cmd_b_len;
	reg [3:0]                   cmd_m_tiles;
	reg [3:0]                   cmd_n_tiles;
	reg [3:0]                   cmd_k_tiles;
	reg [`PT_SIZE_W-1:0]        dec_a_len;
	reg [`PT_SIZE_W-1:0]        dec_b_len;
	reg [A_PTR_W-1:0]           cmd_a_alloc_next;
	reg [B_PTR_W-1:0]           cmd_b_alloc_next;

	reg                         a_alloc_ok;
	reg [`PT_LOCAL_ADDR_W-1:0]  a_alloc_base;
	reg [A_PTR_W-1:0]           a_alloc_next_after;
	reg                         b_alloc_ok;
	reg [`PT_LOCAL_ADDR_W-1:0]  b_alloc_base;
	reg [B_PTR_W-1:0]           b_alloc_next_after;
	wire                        active_is_exec = (active_kind_r == `PT_MALLOC_KIND_MATMUL) || (active_kind_r == `PT_MALLOC_KIND_MATADD);
	wire                        ce_issue_fire;
	wire                        matmul_enqueue_fire;
	wire                        matadd_enqueue_fire;
	wire                        matmul_resp_fire;

	wire [3:0] cmd_opcode = malloc_cmd_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
	wire [3:0] cmd_matmul_m_tiles = malloc_cmd_inst[`PT_MATMUL_M_TILES_H:`PT_MATMUL_M_TILES_L];
	wire [3:0] cmd_matmul_n_tiles = malloc_cmd_inst[`PT_MATMUL_N_TILES_H:`PT_MATMUL_N_TILES_L];
	wire [3:0] cmd_matmul_k_tiles = malloc_cmd_inst[`PT_MATMUL_K_TILES_H:`PT_MATMUL_K_TILES_L];
	wire [7:0] cmd_matmul_reserved_a = malloc_cmd_inst[`PT_MATMUL_RESERVED_A_H:`PT_MATMUL_RESERVED_A_L];
	wire [7:0] cmd_matmul_reserved_b = malloc_cmd_inst[`PT_MATMUL_RESERVED_B_H:`PT_MATMUL_RESERVED_B_L];
	wire [`PT_SIZE_W-1:0] cmd_load_a_size = malloc_cmd_inst[`PT_LOAD_A_SIZE_H:`PT_LOAD_A_SIZE_L];
	wire [`PT_SIZE_W-1:0] cmd_load_b_size = malloc_cmd_inst[`PT_LOAD_B_SIZE_H:`PT_LOAD_B_SIZE_L];
	wire cmd_load_need_a = malloc_cmd_inst[`PT_LOAD_NEED_A_BIT];
	wire cmd_load_need_b = malloc_cmd_inst[`PT_LOAD_NEED_B_BIT];
	wire [5:0] cmd_load_reserved = malloc_cmd_inst[`PT_LOAD_RSV_H:`PT_LOAD_RSV_L];
	wire [1:0] cmd_load_m_code = malloc_cmd_inst[`PT_LOAD_M_CODE_H:`PT_LOAD_M_CODE_L];
	wire [1:0] cmd_load_n_code = malloc_cmd_inst[`PT_LOAD_N_CODE_H:`PT_LOAD_N_CODE_L];
	wire [1:0] cmd_load_k_code = malloc_cmd_inst[`PT_LOAD_K_CODE_H:`PT_LOAD_K_CODE_L];
	wire [9:0] cmd_m_off = malloc_cmd_inst[`PT_MATADD_M_OFF_H:`PT_MATADD_M_OFF_L];
	wire [9:0] cmd_c_field = malloc_cmd_inst[`PT_MATADD_C_FIELD_H:`PT_MATADD_C_FIELD_L];
	wire [5:0] cmd_matadd_reserved_hi = malloc_cmd_inst[`PT_MATADD_RESERVED_HI_H:`PT_MATADD_RESERVED_HI_L];
	wire [1:0] cmd_matadd_reserved_lo = malloc_cmd_inst[`PT_MATADD_RESERVED_LO_H:`PT_MATADD_RESERVED_LO_L];
	wire cmd_matadd_src_single_output = cmd_m_off[8] ? m_buf1_single_output : m_buf0_single_output;
	wire [3:0] cmd_load_m_tiles = (cmd_load_m_code == 2'b00) ? `PT_TILES_1 :
	                              (cmd_load_m_code == 2'b01) ? `PT_TILES_2 :
	                              (cmd_load_m_code == 2'b10) ? `PT_TILES_4 :
	                              4'd0;
	wire [3:0] cmd_load_n_tiles = (cmd_load_n_code == 2'b00) ? `PT_TILES_1 :
	                              (cmd_load_n_code == 2'b01) ? `PT_TILES_2 :
	                              (cmd_load_n_code == 2'b10) ? `PT_TILES_4 :
	                              4'd0;
	wire [3:0] cmd_load_k_tiles = (cmd_load_k_code == 2'b00) ? `PT_TILES_1 :
	                              (cmd_load_k_code == 2'b01) ? `PT_TILES_2 :
	                              (cmd_load_k_code == 2'b10) ? `PT_TILES_4 :
	                              4'd0;
	wire cmd_matmul_m_valid = (cmd_matmul_m_tiles == `PT_TILES_1) || (cmd_matmul_m_tiles == `PT_TILES_2) || (cmd_matmul_m_tiles == `PT_TILES_4);
	wire cmd_matmul_n_valid = (cmd_matmul_n_tiles == `PT_TILES_1) || (cmd_matmul_n_tiles == `PT_TILES_2) || (cmd_matmul_n_tiles == `PT_TILES_4);
	wire cmd_matmul_k_valid = (cmd_matmul_k_tiles == `PT_TILES_1) || (cmd_matmul_k_tiles == `PT_TILES_2) || (cmd_matmul_k_tiles == `PT_TILES_4);
	wire cmd_load_shape_valid = (cmd_load_m_code != 2'b11) && (cmd_load_n_code != 2'b11) && (cmd_load_k_code != 2'b11);
	wire cmd_matmul_legal = (cmd_opcode == `PT_OP_MATMUL) &&
	                        cmd_matmul_m_valid &&
	                        cmd_matmul_n_valid &&
	                        cmd_matmul_k_valid &&
	                        (cmd_matmul_reserved_a == 8'd0) &&
	                        (cmd_matmul_reserved_b == 8'd0);
	wire cmd_load_legal = (cmd_opcode == `PT_OP_LOAD) &&
	                      (cmd_load_need_a || cmd_load_need_b) &&
	                      cmd_load_shape_valid &&
	                      (!cmd_load_need_a || (cmd_load_a_size != {`PT_SIZE_W{1'b0}})) &&
	                      (!cmd_load_need_b || (cmd_load_b_size != {`PT_SIZE_W{1'b0}}));
	wire cmd_matadd_legal = (cmd_opcode == `PT_OP_MATADD) &&
	                        (cmd_matadd_reserved_hi == 6'd0) &&
	                        (cmd_matadd_reserved_lo == 2'b00) &&
	                        (cmd_c_field == 10'd0) &&
	                        cmd_m_off[9] &&
	                        (cmd_m_off[7:0] == 8'd0);

	function [31:0] pack_resp;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp = {err, m_buf, id[29:0]};
		end
	endfunction

	function integer align_up;
		input integer value;
		input integer align;
		integer rem;
		begin
			if (align <= 1) begin
				align_up = value;
			end else begin
				rem = value % align;
				align_up = (rem == 0) ? value : (value + (align - rem));
			end
		end
	endfunction

	function [`PT_LOCAL_ADDR_W-1:0] make_local_base;
		input integer capacity;
		input integer virt_base;
		integer buf_sel;
		integer elem_base;
		begin
			if (virt_base >= capacity) begin
				buf_sel = 1;
				elem_base = virt_base - capacity;
			end else begin
				buf_sel = 0;
				elem_base = virt_base;
			end
			make_local_base = {buf_sel[0], elem_base[`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L]};
		end
	endfunction

	integer si;
	always @(*) begin
		slot_found = 1'b0;
		slot_idx   = {LUT_AW{1'b0}};
		free_found = 1'b0;
		free_idx   = {LUT_AW{1'b0}};
		for (si = 0; si < LUT_DEPTH; si = si + 1) begin
			if (!slot_found && lut_valid[si] && (lut_id[si] == malloc_cmd_id)) begin
				slot_found = 1'b1;
				slot_idx   = si[LUT_AW-1:0];
			end
			if (!free_found && !lut_valid[si]) begin
				free_found = 1'b1;
				free_idx   = si[LUT_AW-1:0];
			end
		end
	end

	integer a_base_int;
	integer a_buf_start;
	always @(*) begin
		a_alloc_ok = 1'b0;
		a_alloc_base = {`PT_LOCAL_ADDR_W{1'b0}};
		a_alloc_next_after = a_alloc_next_r;
		a_base_int = align_up(a_alloc_next_r, GEMM_X_DIM);
		a_buf_start = (a_base_int >= A_CAPACITY) ? A_CAPACITY : 0;
		if (((a_base_int - a_buf_start) + dec_a_len) > A_CAPACITY) begin
			a_base_int = align_up(a_buf_start + A_CAPACITY, GEMM_X_DIM);
		end
		if ((dec_a_len != {`PT_SIZE_W{1'b0}}) && ((a_base_int + dec_a_len) <= (2 * A_CAPACITY))) begin
			a_alloc_ok = 1'b1;
			a_alloc_base = make_local_base(A_CAPACITY, a_base_int);
			a_alloc_next_after = a_base_int + dec_a_len;
		end
	end

	integer b_base_int;
	integer b_buf_start;
	always @(*) begin
		b_alloc_ok = 1'b0;
		b_alloc_base = {`PT_LOCAL_ADDR_W{1'b0}};
		b_alloc_next_after = b_alloc_next_r;
		b_base_int = align_up(b_alloc_next_r, GEMM_Y_DIM);
		b_buf_start = (b_base_int >= B_CAPACITY) ? B_CAPACITY : 0;
		if (((b_base_int - b_buf_start) + dec_b_len) > B_CAPACITY) begin
			b_base_int = align_up(b_buf_start + B_CAPACITY, GEMM_Y_DIM);
		end
		if ((dec_b_len != {`PT_SIZE_W{1'b0}}) && ((b_base_int + dec_b_len) <= (2 * B_CAPACITY))) begin
			b_alloc_ok = 1'b1;
			b_alloc_base = make_local_base(B_CAPACITY, b_base_int);
			b_alloc_next_after = b_base_int + dec_b_len;
		end
	end

	always @(*) begin
		case (malloc_cmd_kind)
			`PT_MALLOC_KIND_LOAD: begin
				dec_need_a = cmd_load_need_a;
				dec_need_b = cmd_load_need_b;
				dec_b_is_c = 1'b0;
				dec_m_tiles = cmd_load_m_tiles;
				dec_n_tiles = cmd_load_n_tiles;
				dec_k_tiles = cmd_load_k_tiles;
				dec_a_len  = cmd_load_need_a ? cmd_load_a_size : {`PT_SIZE_W{1'b0}};
				dec_b_len  = cmd_load_need_b ? cmd_load_b_size : {`PT_SIZE_W{1'b0}};
				dec_error  = !cmd_load_legal;
				if (cmd_load_need_a && (cmd_load_a_size != (cmd_load_m_tiles * cmd_load_k_tiles * A_TILE_LEN))) begin
					dec_error = 1'b1;
				end
				if (cmd_load_need_b && (cmd_load_b_size != (cmd_load_k_tiles * cmd_load_n_tiles * B_TILE_LEN))) begin
					dec_error = 1'b1;
				end
			end

			`PT_MALLOC_KIND_MATMUL: begin
				dec_need_a = 1'b1;
				dec_need_b = 1'b1;
				dec_b_is_c = 1'b0;
				dec_m_tiles = cmd_matmul_m_tiles;
				dec_n_tiles = cmd_matmul_n_tiles;
				dec_k_tiles = cmd_matmul_k_tiles;
				dec_a_len  = cmd_matmul_m_tiles * cmd_matmul_k_tiles * A_TILE_LEN;
				dec_b_len  = cmd_matmul_k_tiles * cmd_matmul_n_tiles * B_TILE_LEN;
				dec_error  = !cmd_matmul_legal;
			end

			`PT_MALLOC_KIND_MATADD: begin
				dec_need_a = 1'b0;
				dec_need_b = 1'b1;
				dec_b_is_c = 1'b1;
				dec_m_tiles = `PT_TILES_1;
				dec_n_tiles = `PT_TILES_1;
				dec_k_tiles = `PT_TILES_1;
				dec_a_len  = {`PT_SIZE_W{1'b0}};
				dec_b_len  = B_TILE_LEN[`PT_SIZE_W-1:0];
				dec_error  = !cmd_matadd_legal || !cmd_matadd_src_single_output;
			end

			default: begin
				dec_need_a = 1'b0;
				dec_need_b = 1'b0;
				dec_b_is_c = 1'b0;
				dec_m_tiles = `PT_TILES_1;
				dec_n_tiles = `PT_TILES_1;
				dec_k_tiles = `PT_TILES_1;
				dec_a_len  = {`PT_SIZE_W{1'b0}};
				dec_b_len  = {`PT_SIZE_W{1'b0}};
				dec_error  = 1'b1;
			end
		endcase
	end

	always @(*) begin
		cmd_error        = dec_error;
		cmd_need_a_fill  = 1'b0;
		cmd_need_b_fill  = 1'b0;
		cmd_b_is_c       = dec_b_is_c;
		cmd_slot_idx     = slot_found ? slot_idx : free_idx;
		cmd_a_base       = {`PT_LOCAL_ADDR_W{1'b0}};
		cmd_b_base       = {`PT_LOCAL_ADDR_W{1'b0}};
		cmd_a_len        = dec_a_len;
		cmd_b_len        = dec_b_len;
		cmd_m_tiles      = dec_m_tiles;
		cmd_n_tiles      = dec_n_tiles;
		cmd_k_tiles      = dec_k_tiles;
		cmd_a_alloc_next = a_alloc_next_r;
		cmd_b_alloc_next = b_alloc_next_r;

		if (!dec_error) begin
			if (!slot_found && !free_found) begin
				cmd_error = 1'b1;
			end else begin
				case (malloc_cmd_kind)
					`PT_MALLOC_KIND_LOAD: begin
						if (dec_need_a) begin
							if (slot_found && lut_a_valid[slot_idx]) begin
								if ((lut_a_len[slot_idx] == dec_a_len) &&
								    (lut_a_m_tiles[slot_idx] == dec_m_tiles) &&
								    (lut_a_k_tiles[slot_idx] == dec_k_tiles)) begin
									cmd_a_base = lut_a_base[slot_idx];
								end else begin
									cmd_error = 1'b1;
								end
							end else if (a_alloc_ok) begin
								cmd_need_a_fill  = 1'b1;
								cmd_a_base       = a_alloc_base;
								cmd_a_alloc_next = a_alloc_next_after;
							end else begin
								cmd_error = 1'b1;
							end
						end

						if (dec_need_b && !cmd_error) begin
							if (slot_found && lut_b_valid[slot_idx] && !lut_b_is_c[slot_idx]) begin
								if ((lut_b_len[slot_idx] == dec_b_len) &&
								    (lut_b_k_tiles[slot_idx] == dec_k_tiles) &&
								    (lut_b_n_tiles[slot_idx] == dec_n_tiles)) begin
									cmd_b_base = lut_b_base[slot_idx];
								end else begin
									cmd_error = 1'b1;
								end
							end else if (b_alloc_ok) begin
								cmd_need_b_fill  = 1'b1;
								cmd_b_base       = b_alloc_base;
								cmd_b_alloc_next = b_alloc_next_after;
							end else begin
								cmd_error = 1'b1;
							end
						end
					end

					`PT_MALLOC_KIND_MATMUL: begin
						if (slot_found && lut_a_valid[slot_idx]) begin
							if ((lut_a_len[slot_idx] == dec_a_len) &&
							    (lut_a_m_tiles[slot_idx] == dec_m_tiles) &&
							    (lut_a_k_tiles[slot_idx] == dec_k_tiles)) begin
								cmd_a_base = lut_a_base[slot_idx];
							end else begin
								cmd_error = 1'b1;
							end
						end else if (a_alloc_ok) begin
							cmd_need_a_fill  = 1'b1;
							cmd_a_base       = a_alloc_base;
							cmd_a_alloc_next = a_alloc_next_after;
						end else begin
							cmd_error = 1'b1;
						end

						if (!cmd_error) begin
							if (slot_found && lut_b_valid[slot_idx] && !lut_b_is_c[slot_idx]) begin
								if ((lut_b_len[slot_idx] == dec_b_len) &&
								    (lut_b_k_tiles[slot_idx] == dec_k_tiles) &&
								    (lut_b_n_tiles[slot_idx] == dec_n_tiles)) begin
									cmd_b_base = lut_b_base[slot_idx];
								end else begin
									cmd_error = 1'b1;
								end
							end else if (b_alloc_ok) begin
								cmd_need_b_fill  = 1'b1;
								cmd_b_base       = b_alloc_base;
								cmd_b_alloc_next = b_alloc_next_after;
							end else begin
								cmd_error = 1'b1;
							end
						end
					end

					`PT_MALLOC_KIND_MATADD: begin
						if (slot_found && lut_b_valid[slot_idx] && lut_b_is_c[slot_idx]) begin
							if (lut_b_len[slot_idx] == dec_b_len) begin
								cmd_b_base = lut_b_base[slot_idx];
							end else begin
								cmd_error = 1'b1;
							end
						end else if (b_alloc_ok) begin
							cmd_need_b_fill  = 1'b1;
							cmd_b_base       = b_alloc_base;
							cmd_b_alloc_next = b_alloc_next_after;
						end else begin
							cmd_error = 1'b1;
						end
					end

					default: begin
						cmd_error = 1'b1;
					end
				endcase
			end
		end
	end

	assign malloc_cmd_ready = (state_r == ST_IDLE);

	assign fill_req_valid      = (state_r == ST_FILL_REQ_A) || (state_r == ST_FILL_REQ_B);
	assign fill_req_kind       = (state_r == ST_FILL_REQ_A) ? `PT_DMA_KIND_A
	                               : (active_b_is_c_r ? `PT_DMA_KIND_C : `PT_DMA_KIND_B);
	assign fill_req_id         = active_id_r;
	assign fill_req_local_base = (state_r == ST_FILL_REQ_A) ? active_a_base_r : active_b_base_r;
	assign fill_req_len        = (state_r == ST_FILL_REQ_A) ? active_a_len_r : active_b_len_r;
	assign fill_req_m_tiles    = active_m_tiles_r;
	assign fill_req_n_tiles    = active_n_tiles_r;
	assign fill_req_k_tiles    = active_k_tiles_r;

	assign ce_cmd_valid        = (state_r == ST_CE_REQ) && (!active_is_exec || m_alloc_ready);
	assign ce_cmd_ctrl         = active_inst_r;
	assign ce_cmd_id           = active_id_r;
	assign ce_a_local_base     = active_a_base_r;
	assign ce_b_local_base     = active_b_base_r;
	assign ce_m_wr_buf         = m_alloc_buf;
	assign m_alloc_take        = ce_cmd_valid && ce_cmd_ready && active_is_exec;
	assign ce_issue_fire       = ce_cmd_valid && ce_cmd_ready;
	assign matmul_enqueue_fire = ce_issue_fire && (active_kind_r == `PT_MALLOC_KIND_MATMUL);
	assign matadd_enqueue_fire = ce_issue_fire && (active_kind_r == `PT_MALLOC_KIND_MATADD);
	assign matmul_resp_fire    = ce_resp_valid && !serial_exec_busy_r && (matmul_inflight_count_r != 0);
	assign exec_busy           = serial_exec_busy_r || (matmul_inflight_count_r != 0);
	assign serial_exec_busy    = serial_exec_busy_r;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state_r            <= ST_IDLE;
		end else if (clear) begin
			state_r            <= ST_IDLE;
		end else begin
			state_r            <= state_n;
		end
	end

	always @(*) begin
		state_n = state_r;
		case (state_r)
			ST_IDLE: begin
				if (malloc_cmd_valid) begin
					if (cmd_error || ((malloc_cmd_kind == `PT_MALLOC_KIND_LOAD) && !cmd_need_a_fill && !cmd_need_b_fill)) begin
						state_n = ST_RESP;
					end else if (cmd_need_a_fill) begin
						state_n = ST_FILL_REQ_A;
					end else if (cmd_need_b_fill) begin
						state_n = ST_FILL_REQ_B;
					end else begin
						state_n = ST_CE_REQ;
					end
				end
			end

			ST_FILL_REQ_A: begin
				if (fill_req_ready) begin
					state_n = ST_FILL_WAIT_A;
				end
			end

			ST_FILL_WAIT_A: begin
				if (fill_done_valid && (fill_done_id == active_id_r) && (fill_done_kind == `PT_DMA_KIND_A)) begin
					if (fill_done_err) begin
						state_n = ST_RESP;
					end else if (active_need_b_fill_r) begin
						state_n = ST_FILL_REQ_B;
					end else if (active_kind_r == `PT_MALLOC_KIND_LOAD) begin
						state_n = ST_RESP;
					end else begin
						state_n = ST_CE_REQ;
					end
				end
			end

			ST_FILL_REQ_B: begin
				if (fill_req_ready) begin
					state_n = ST_FILL_WAIT_B;
				end
			end

			ST_FILL_WAIT_B: begin
				if (fill_done_valid &&
				    (fill_done_id == active_id_r) &&
				    (fill_done_kind == (active_b_is_c_r ? `PT_DMA_KIND_C : `PT_DMA_KIND_B))) begin
					state_n = ST_RESP;
					if (!fill_done_err && (active_kind_r != `PT_MALLOC_KIND_LOAD)) begin
						state_n = ST_CE_REQ;
					end
				end
			end

			ST_CE_REQ: begin
				if (ce_issue_fire) begin
					state_n = ST_IDLE;
				end
			end

			ST_CE_WAIT: begin
				if (ce_resp_valid) begin
					state_n = ST_RESP;
				end
			end

			ST_RESP: begin
				state_n = ST_IDLE;
			end

			default: begin
				state_n = ST_IDLE;
			end
		endcase
	end

	integer li;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			malloc_resp_valid    <= 1'b0;
			malloc_resp          <= 32'd0;
			malloc_irq           <= 1'b0;
			a_alloc_next_r       <= {A_PTR_W{1'b0}};
			b_alloc_next_r       <= {B_PTR_W{1'b0}};
			active_kind_r        <= {`PT_MALLOC_KIND_W{1'b0}};
			active_inst_r        <= {`INST_WIDTH{1'b0}};
			active_id_r          <= 32'd0;
			active_slot_idx_r    <= {LUT_AW{1'b0}};
			active_need_a_fill_r <= 1'b0;
			active_need_b_fill_r <= 1'b0;
			active_b_is_c_r      <= 1'b0;
			active_m_tiles_r     <= `PT_TILES_1;
			active_n_tiles_r     <= `PT_TILES_1;
			active_k_tiles_r     <= `PT_TILES_1;
			active_a_base_r      <= {`PT_LOCAL_ADDR_W{1'b0}};
			active_b_base_r      <= {`PT_LOCAL_ADDR_W{1'b0}};
			active_a_len_r       <= {`PT_SIZE_W{1'b0}};
			active_b_len_r       <= {`PT_SIZE_W{1'b0}};
			active_a_alloc_next_r <= {A_PTR_W{1'b0}};
			active_b_alloc_next_r <= {B_PTR_W{1'b0}};
			resp_word_r          <= 32'd0;
			resp_irq_r           <= 1'b0;
			matmul_inflight_count_r <= 2'd0;
			serial_exec_busy_r      <= 1'b0;
			for (li = 0; li < LUT_DEPTH; li = li + 1) begin
				lut_valid[li]   <= 1'b0;
				lut_id[li]      <= 32'd0;
				lut_a_valid[li] <= 1'b0;
				lut_a_base[li]  <= {`PT_LOCAL_ADDR_W{1'b0}};
				lut_a_len[li]   <= {`PT_SIZE_W{1'b0}};
				lut_a_m_tiles[li] <= `PT_TILES_1;
				lut_a_k_tiles[li] <= `PT_TILES_1;
				lut_b_valid[li] <= 1'b0;
				lut_b_is_c[li]  <= 1'b0;
				lut_b_base[li]  <= {`PT_LOCAL_ADDR_W{1'b0}};
				lut_b_len[li]   <= {`PT_SIZE_W{1'b0}};
				lut_b_k_tiles[li] <= `PT_TILES_1;
				lut_b_n_tiles[li] <= `PT_TILES_1;
			end
		end else if (clear) begin
			malloc_resp_valid    <= 1'b0;
			malloc_resp          <= 32'd0;
			malloc_irq           <= 1'b0;
			a_alloc_next_r       <= {A_PTR_W{1'b0}};
			b_alloc_next_r       <= {B_PTR_W{1'b0}};
			active_kind_r        <= {`PT_MALLOC_KIND_W{1'b0}};
			active_inst_r        <= {`INST_WIDTH{1'b0}};
			active_id_r          <= 32'd0;
			active_slot_idx_r    <= {LUT_AW{1'b0}};
			active_need_a_fill_r <= 1'b0;
			active_need_b_fill_r <= 1'b0;
			active_b_is_c_r      <= 1'b0;
			active_m_tiles_r     <= `PT_TILES_1;
			active_n_tiles_r     <= `PT_TILES_1;
			active_k_tiles_r     <= `PT_TILES_1;
			active_a_base_r      <= {`PT_LOCAL_ADDR_W{1'b0}};
			active_b_base_r      <= {`PT_LOCAL_ADDR_W{1'b0}};
			active_a_len_r       <= {`PT_SIZE_W{1'b0}};
			active_b_len_r       <= {`PT_SIZE_W{1'b0}};
			active_a_alloc_next_r <= {A_PTR_W{1'b0}};
			active_b_alloc_next_r <= {B_PTR_W{1'b0}};
			resp_word_r          <= 32'd0;
			resp_irq_r           <= 1'b0;
			matmul_inflight_count_r <= 2'd0;
			serial_exec_busy_r      <= 1'b0;
			for (li = 0; li < LUT_DEPTH; li = li + 1) begin
				lut_valid[li]   <= 1'b0;
				lut_id[li]      <= 32'd0;
				lut_a_valid[li] <= 1'b0;
				lut_a_base[li]  <= {`PT_LOCAL_ADDR_W{1'b0}};
				lut_a_len[li]   <= {`PT_SIZE_W{1'b0}};
				lut_a_m_tiles[li] <= `PT_TILES_1;
				lut_a_k_tiles[li] <= `PT_TILES_1;
				lut_b_valid[li] <= 1'b0;
				lut_b_is_c[li]  <= 1'b0;
				lut_b_base[li]  <= {`PT_LOCAL_ADDR_W{1'b0}};
				lut_b_len[li]   <= {`PT_SIZE_W{1'b0}};
				lut_b_k_tiles[li] <= `PT_TILES_1;
				lut_b_n_tiles[li] <= `PT_TILES_1;
			end
		end else begin
			malloc_resp_valid <= 1'b0;
			malloc_irq        <= 1'b0;
			matmul_inflight_count_r <= matmul_inflight_count_r
				+ (matmul_enqueue_fire ? 1'b1 : 1'b0)
				- (matmul_resp_fire ? 1'b1 : 1'b0);
			if (matadd_enqueue_fire) begin
				serial_exec_busy_r <= 1'b1;
			end
			if (ce_resp_valid && serial_exec_busy_r) begin
				serial_exec_busy_r <= 1'b0;
			end

			case (state_r)
				ST_IDLE: begin
					if (malloc_cmd_valid && malloc_cmd_ready) begin
						active_kind_r         <= malloc_cmd_kind;
						active_inst_r         <= malloc_cmd_inst;
						active_id_r           <= malloc_cmd_id;
						active_slot_idx_r     <= cmd_slot_idx;
						active_need_a_fill_r  <= cmd_need_a_fill;
						active_need_b_fill_r  <= cmd_need_b_fill;
						active_b_is_c_r       <= cmd_b_is_c;
						active_m_tiles_r      <= cmd_m_tiles;
						active_n_tiles_r      <= cmd_n_tiles;
						active_k_tiles_r      <= cmd_k_tiles;
						active_a_base_r       <= cmd_a_base;
						active_b_base_r       <= cmd_b_base;
						active_a_len_r        <= cmd_a_len;
						active_b_len_r        <= cmd_b_len;
						active_a_alloc_next_r <= cmd_a_alloc_next;
						active_b_alloc_next_r <= cmd_b_alloc_next;
						if (cmd_error) begin
							resp_word_r <= pack_resp(1'b1, 1'b0, malloc_cmd_id);
							resp_irq_r  <= 1'b1;
						end else if ((malloc_cmd_kind == `PT_MALLOC_KIND_LOAD) && !cmd_need_a_fill && !cmd_need_b_fill) begin
							resp_word_r <= pack_resp(1'b0, 1'b0, malloc_cmd_id);
							resp_irq_r  <= 1'b0;
						end
					end
				end

				ST_FILL_WAIT_A: begin
					if (fill_done_valid && (fill_done_id == active_id_r) && (fill_done_kind == `PT_DMA_KIND_A)) begin
						if (fill_done_err) begin
							resp_word_r <= pack_resp(1'b1, 1'b0, active_id_r);
							resp_irq_r  <= 1'b1;
						end else begin
							lut_valid[active_slot_idx_r]   <= 1'b1;
							lut_id[active_slot_idx_r]      <= active_id_r;
							lut_a_valid[active_slot_idx_r] <= 1'b1;
							lut_a_base[active_slot_idx_r]  <= active_a_base_r;
							lut_a_len[active_slot_idx_r]   <= active_a_len_r;
							lut_a_m_tiles[active_slot_idx_r] <= active_m_tiles_r;
							lut_a_k_tiles[active_slot_idx_r] <= active_k_tiles_r;
							a_alloc_next_r                 <= active_a_alloc_next_r;
							active_need_a_fill_r          <= 1'b0;
							if (!active_need_b_fill_r && (active_kind_r == `PT_MALLOC_KIND_LOAD)) begin
								resp_word_r <= pack_resp(1'b0, 1'b0, active_id_r);
								resp_irq_r  <= 1'b0;
							end
						end
					end
				end

				ST_FILL_WAIT_B: begin
					if (fill_done_valid &&
					    (fill_done_id == active_id_r) &&
					    (fill_done_kind == (active_b_is_c_r ? `PT_DMA_KIND_C : `PT_DMA_KIND_B))) begin
						if (fill_done_err) begin
							resp_word_r <= pack_resp(1'b1, 1'b0, active_id_r);
							resp_irq_r  <= 1'b1;
						end else begin
							lut_valid[active_slot_idx_r]   <= 1'b1;
							lut_id[active_slot_idx_r]      <= active_id_r;
							lut_b_valid[active_slot_idx_r] <= 1'b1;
							lut_b_is_c[active_slot_idx_r]  <= active_b_is_c_r;
							lut_b_base[active_slot_idx_r]  <= active_b_base_r;
							lut_b_len[active_slot_idx_r]   <= active_b_len_r;
							lut_b_k_tiles[active_slot_idx_r] <= active_k_tiles_r;
							lut_b_n_tiles[active_slot_idx_r] <= active_n_tiles_r;
							b_alloc_next_r                 <= active_b_alloc_next_r;
							active_need_b_fill_r          <= 1'b0;
							if (active_kind_r == `PT_MALLOC_KIND_LOAD) begin
								resp_word_r <= pack_resp(1'b0, 1'b0, active_id_r);
								resp_irq_r  <= 1'b0;
							end
						end
					end
				end

				ST_RESP: begin
					malloc_resp_valid <= 1'b1;
					malloc_resp       <= resp_word_r;
					malloc_irq        <= resp_irq_r;
				end

				default: begin
				end
			endcase
		end
	end

endmodule
