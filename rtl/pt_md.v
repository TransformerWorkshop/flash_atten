`include "param.vh"

module PT_MD #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4 ,
	parameter GEMM_Y_DIM   = 4 ,
	parameter EXT_ADDR_W   = 32,
	parameter DMA_BEATS_W  = 16,
	parameter LUT_DEPTH    = 8 ,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16
) (
	input  wire                       clk ,
	input  wire                       rstn,
	input  wire                       clear,

	// host control stream
	input  wire                       ctrl_valid,
	output wire                       ctrl_ready,
	input  wire [`INST_WIDTH-1:0]     ctrl_inst ,
	input  wire [               31:0] ctrl_id   ,
	output reg                        md_resp_valid,
	output reg  [               31:0] md_resp,

	// stream payload for DMA load
	input  wire                       s_axis_tvalid,
	input  wire [     DATA_WIDTH-1:0] s_axis_tdata ,
	input  wire [                1:0] s_axis_tuser ,
	output wire                       s_axis_tready,

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

	// memory write path
	output reg                        a_mem_wr_en  ,
	output reg                        a_mem_wr_buf ,
	output reg  [((GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM))-1:0] a_mem_wr_lane ,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] a_mem_wr_addr ,
	output reg  [         DATA_WIDTH-1:0] a_mem_wr_data ,

	output reg                        b_mem_wr_en  ,
	output reg                        b_mem_wr_buf ,
	output reg  [((GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM))-1:0] b_mem_wr_lane ,
	output reg  [((B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH))-1:0] b_mem_wr_addr ,
	output reg  [         DATA_WIDTH-1:0] b_mem_wr_data ,

	// issue queue output toward CE
	output wire                       ce_inst_valid,
	input  wire                       ce_inst_ready,
	output wire [`INST_WIDTH-1:0]     ce_inst      ,
	output wire [               31:0] ce_id        ,

	// irq
	output wire                       irq
);

	localparam [1:0] MATRIX_A = 2'b01;
	localparam [1:0] MATRIX_B = 2'b10;

	localparam integer IQ_WIDTH = `INST_WIDTH + 32;
	localparam integer A_ELEMS  = GEMM_X_DIM * GEMM_X_DIM;
	localparam integer B_ELEMS  = GEMM_Y_DIM * GEMM_Y_DIM;
	localparam integer A_LW     = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW     = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_AW     = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW     = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);
	localparam integer LUT_AW   = (LUT_DEPTH <= 1) ? 1 : $clog2(LUT_DEPTH);
	localparam integer ELEM_SHIFT = (DATA_WIDTH <= 8) ? 0 : $clog2(DATA_WIDTH / 8);

	localparam [2:0] ST_IDLE      = 3'd0;
	localparam [2:0] ST_LUT_CHECK = 3'd1;
	localparam [2:0] ST_DMA_REQ   = 3'd2;
	localparam [2:0] ST_DMA_RECV  = 3'd3;
	localparam [2:0] ST_ENQ_CE    = 3'd4;

	reg [2:0] state;
	reg [2:0] next_state;

	function [9:0] make_local_off;
		input buf_sel;
		begin
			make_local_off = {buf_sel, 9'd0};
		end
	endfunction

	// ingress command queue
	wire [IQ_WIDTH-1:0] cmd_q_out_data;
	wire                cmd_q_out_valid;
	wire                cmd_q_out_ready;
	wire                cmd_q_in_ready;
	wire [`INST_WIDTH-1:0] cmd_inst = cmd_q_out_data[IQ_WIDTH-1:32];
	wire [31:0]            cmd_id   = cmd_q_out_data[31:0];

	sync_fifo #(
		.WIDTH(IQ_WIDTH),
		.DEPTH(`QUEUE_LEN)
	) cmd_queue (
		.clk      (clk            ),
		.resetn   (rstn           ),
		.clear    (clear          ),
		.data_in  ({ctrl_inst, ctrl_id}),
		.valid_in (ctrl_valid     ),
		.ready_in (cmd_q_in_ready ),
		.data_out (cmd_q_out_data ),
		.valid_out(cmd_q_out_valid),
		.ready_out(cmd_q_out_ready)
	);

	assign ctrl_ready   = cmd_q_in_ready;
	assign cmd_q_out_ready = (state == ST_IDLE);

	// CE issue queue
	reg [`INST_WIDTH-1:0] enq_inst;
	reg [31:0]            enq_id;
	wire [IQ_WIDTH-1:0]   ce_q_out_data;
	wire                  ce_q_out_valid;
	wire                  ce_q_out_ready;
	wire                  ce_q_in_ready;

	sync_fifo #(
		.WIDTH(IQ_WIDTH),
		.DEPTH(`QUEUE_LEN)
	) ce_queue (
		.clk      (clk             ),
		.resetn   (rstn            ),
		.clear    (clear           ),
		.data_in  ({enq_inst, enq_id}),
		.valid_in (state == ST_ENQ_CE),
		.ready_in (ce_q_in_ready   ),
		.data_out (ce_q_out_data   ),
		.valid_out(ce_q_out_valid  ),
		.ready_out(ce_q_out_ready  )
	);

	assign ce_inst_valid = ce_q_out_valid;
	assign ce_inst       = ce_q_out_data[IQ_WIDTH-1:32];
	assign ce_id         = ce_q_out_data[31:0];
	assign ce_q_out_ready = ce_inst_ready;

	// current command
	reg [`INST_WIDTH-1:0] cur_inst;
	reg [31:0]            cur_id;

	wire [3:0] cmd_opcode = cmd_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
	wire [1:0] cmd_m      = cmd_inst[`PT_INST_M_H:`PT_INST_M_L];
	wire [1:0] cmd_n      = cmd_inst[`PT_INST_N_H:`PT_INST_N_L];
	wire [1:0] cmd_k      = cmd_inst[`PT_INST_K_H:`PT_INST_K_L];

	wire [9:0] cur_a_off  = cur_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
	wire [9:0] cur_b_off  = cur_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];

	wire cmd_mnk_is_full = (cmd_m == `PT_SCALE_FULL) &&
	                       (cmd_n == `PT_SCALE_FULL) &&
	                       (cmd_k == `PT_SCALE_FULL);

	// pcsr base registers
	reg [31:0] pcsr_a_base;
	reg [31:0] pcsr_b_base;

	// LUT
	reg              lut_valid     [0:LUT_DEPTH-1];
	reg [31:0]       lut_id        [0:LUT_DEPTH-1];
	reg              lut_a_valid   [0:LUT_DEPTH-1];
	reg              lut_a_buf     [0:LUT_DEPTH-1];
	reg [9:0]        lut_a_ext_off [0:LUT_DEPTH-1];
	reg [9:0]        lut_a_loc_off [0:LUT_DEPTH-1];
	reg              lut_b_valid   [0:LUT_DEPTH-1];
	reg              lut_b_buf     [0:LUT_DEPTH-1];
	reg [9:0]        lut_b_ext_off [0:LUT_DEPTH-1];
	reg [9:0]        lut_b_loc_off [0:LUT_DEPTH-1];

	reg [LUT_AW-1:0] lut_alloc_ptr;
	reg [LUT_AW-1:0] work_lut_idx;
	reg              lut_found;
	reg [LUT_AW-1:0] lut_found_idx;
	reg              a_hit;
	reg              b_hit;

	integer li;
	always @(*) begin
		lut_found     = 1'b0;
		lut_found_idx = {LUT_AW{1'b0}};
		for (li = 0; li < LUT_DEPTH; li = li + 1) begin
			if (lut_valid[li] && (lut_id[li] == cur_id) && !lut_found) begin
				lut_found     = 1'b1;
				lut_found_idx = li[LUT_AW-1:0];
			end
		end

		a_hit = 1'b0;
		b_hit = 1'b0;
		if (lut_found) begin
			a_hit = lut_a_valid[lut_found_idx] &&
			        ((cur_a_off == lut_a_ext_off[lut_found_idx]) ||
			         (cur_a_off == lut_a_loc_off[lut_found_idx]));
			b_hit = lut_b_valid[lut_found_idx] &&
			        ((cur_b_off == lut_b_ext_off[lut_found_idx]) ||
			         (cur_b_off == lut_b_loc_off[lut_found_idx]));
		end
	end

	reg a_wr_buf_sel;
	reg b_wr_buf_sel;

	// DMA load context
	reg                   load_is_b;
	reg                   load_buf_sel;
	reg [9:0]             load_ext_off;
	reg [DMA_BEATS_W-1:0] load_total_beats;
	reg [DMA_BEATS_W-1:0] load_recv_count;

	wire [31:0] dma_base_sel = load_is_b ? pcsr_b_base : pcsr_a_base;
	wire [EXT_ADDR_W-1:0] dma_off_bytes =
		({{(EXT_ADDR_W-10){1'b0}}, load_ext_off} << ELEM_SHIFT);

	assign dma_req_valid      = (state == ST_DMA_REQ);
	assign dma_req_tuser      = load_is_b ? MATRIX_B : MATRIX_A;
	assign dma_req_id         = cur_id;
	assign dma_req_ext_addr   = dma_base_sel[EXT_ADDR_W-1:0] + dma_off_bytes;
	assign dma_req_local_addr = make_local_off(load_buf_sel);
	assign dma_req_beats      = load_total_beats;
	assign s_axis_tready      = (state == ST_DMA_RECV);

	reg [`INST_WIDTH-1:0] patched_inst;
	reg irq_r;
	assign irq = irq_r;

	integer dma_row;
	integer dma_col;
	integer ri;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state <= ST_IDLE;
		end else if (clear) begin
			state <= ST_IDLE;
		end else begin
			state <= next_state;
		end
	end

	always @(*) begin
		next_state = state;
		case (state)
			ST_IDLE: begin
				if (cmd_q_out_valid && (cmd_opcode == `PT_OP_MATMUL) && cmd_mnk_is_full) begin
					next_state = ST_LUT_CHECK;
				end
			end

			ST_LUT_CHECK: begin
				if (a_hit && b_hit) begin
					next_state = ST_ENQ_CE;
				end else if (!a_hit) begin
					next_state = ST_DMA_REQ;
				end else if (!b_hit) begin
					next_state = ST_DMA_REQ;
				end else begin
					next_state = ST_ENQ_CE;
				end
			end

			ST_DMA_REQ: begin
				if (dma_req_ready) begin
					next_state = ST_DMA_RECV;
				end
			end

			ST_DMA_RECV: begin
				if (dma_error) begin
					next_state = ST_IDLE;
				end
				if (s_axis_tvalid && (load_recv_count + 1'b1 >= load_total_beats)) begin
					if (!load_is_b) begin
						if (!b_hit) begin
							next_state = ST_DMA_REQ;
						end else begin
							next_state = ST_ENQ_CE;
						end
					end else begin
						next_state = ST_ENQ_CE;
					end
				end
			end

			ST_ENQ_CE: begin
				if (ce_q_in_ready) begin
					next_state = ST_IDLE;
				end
			end

			default: begin
				next_state = ST_IDLE;
			end
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cur_inst         <= {`INST_WIDTH{1'b0}};
			cur_id           <= 32'd0;
			pcsr_a_base      <= 32'd0;
			pcsr_b_base      <= 32'd0;
			lut_alloc_ptr    <= {LUT_AW{1'b0}};
			work_lut_idx     <= {LUT_AW{1'b0}};
			a_wr_buf_sel     <= 1'b0;
			b_wr_buf_sel     <= 1'b0;
			load_is_b        <= 1'b0;
			load_buf_sel     <= 1'b0;
			load_ext_off     <= 10'd0;
			load_total_beats <= {DMA_BEATS_W{1'b0}};
			load_recv_count  <= {DMA_BEATS_W{1'b0}};
			enq_inst         <= {`INST_WIDTH{1'b0}};
			enq_id           <= 32'd0;
			md_resp_valid    <= 1'b0;
			md_resp          <= 32'd0;
			irq_r            <= 1'b0;
			a_mem_wr_en      <= 1'b0;
			a_mem_wr_buf     <= 1'b0;
			a_mem_wr_lane    <= {A_LW{1'b0}};
			a_mem_wr_addr    <= {A_AW{1'b0}};
			a_mem_wr_data    <= {DATA_WIDTH{1'b0}};
			b_mem_wr_en      <= 1'b0;
			b_mem_wr_buf     <= 1'b0;
			b_mem_wr_lane    <= {B_LW{1'b0}};
			b_mem_wr_addr    <= {B_AW{1'b0}};
			b_mem_wr_data    <= {DATA_WIDTH{1'b0}};

			for (ri = 0; ri < LUT_DEPTH; ri = ri + 1) begin
				lut_valid[ri]     <= 1'b0;
				lut_id[ri]        <= 32'd0;
				lut_a_valid[ri]   <= 1'b0;
				lut_a_buf[ri]     <= 1'b0;
				lut_a_ext_off[ri] <= 10'd0;
				lut_a_loc_off[ri] <= 10'd0;
				lut_b_valid[ri]   <= 1'b0;
				lut_b_buf[ri]     <= 1'b0;
				lut_b_ext_off[ri] <= 10'd0;
				lut_b_loc_off[ri] <= 10'd0;
			end
		end else if (clear) begin
			cur_inst         <= {`INST_WIDTH{1'b0}};
			cur_id           <= 32'd0;
			pcsr_a_base      <= 32'd0;
			pcsr_b_base      <= 32'd0;
			lut_alloc_ptr    <= {LUT_AW{1'b0}};
			work_lut_idx     <= {LUT_AW{1'b0}};
			a_wr_buf_sel     <= 1'b0;
			b_wr_buf_sel     <= 1'b0;
			load_is_b        <= 1'b0;
			load_buf_sel     <= 1'b0;
			load_ext_off     <= 10'd0;
			load_total_beats <= {DMA_BEATS_W{1'b0}};
			load_recv_count  <= {DMA_BEATS_W{1'b0}};
			enq_inst         <= {`INST_WIDTH{1'b0}};
			enq_id           <= 32'd0;
			md_resp_valid    <= 1'b0;
			md_resp          <= 32'd0;
			irq_r            <= 1'b0;
			a_mem_wr_en      <= 1'b0;
			b_mem_wr_en      <= 1'b0;

			for (ri = 0; ri < LUT_DEPTH; ri = ri + 1) begin
				lut_valid[ri]     <= 1'b0;
				lut_id[ri]        <= 32'd0;
				lut_a_valid[ri]   <= 1'b0;
				lut_a_buf[ri]     <= 1'b0;
				lut_a_ext_off[ri] <= 10'd0;
				lut_a_loc_off[ri] <= 10'd0;
				lut_b_valid[ri]   <= 1'b0;
				lut_b_buf[ri]     <= 1'b0;
				lut_b_ext_off[ri] <= 10'd0;
				lut_b_loc_off[ri] <= 10'd0;
			end
		end else begin
			md_resp_valid <= 1'b0;
			irq_r         <= 1'b0;
			a_mem_wr_en   <= 1'b0;
			b_mem_wr_en   <= 1'b0;

				case (state)
					ST_IDLE: begin
						if (cmd_q_out_valid) begin
							if (cmd_opcode == `PT_OP_CFG) begin
								case (cmd_inst[27:24])
									`PT_CFG_A_BASE_LO: pcsr_a_base[15:0]  <= cmd_inst[15:0];
									`PT_CFG_A_BASE_HI: pcsr_a_base[31:16] <= cmd_inst[15:0];
									`PT_CFG_B_BASE_LO: pcsr_b_base[15:0]  <= cmd_inst[15:0];
									`PT_CFG_B_BASE_HI: pcsr_b_base[31:16] <= cmd_inst[15:0];
									default: begin
									end
								endcase
								md_resp       <= cmd_id;
								md_resp_valid <= 1'b1;
							end else if (cmd_opcode == `PT_OP_MATMUL) begin
								if (!cmd_mnk_is_full) begin
									md_resp       <= {1'b1, cmd_id[30:0]};
									md_resp_valid <= 1'b1;
									irq_r         <= 1'b1;
								end else begin
									cur_inst <= cmd_inst;
									cur_id   <= cmd_id;
								end
							end else begin
								md_resp       <= {1'b1, cmd_id[30:0]};
								md_resp_valid <= 1'b1;
								irq_r         <= 1'b1;
							end
						end
					end

					ST_LUT_CHECK: begin
						if (!lut_found) begin
							work_lut_idx <= lut_alloc_ptr;
							lut_valid[lut_alloc_ptr]     <= 1'b1;
							lut_id[lut_alloc_ptr]        <= cur_id;
							lut_a_valid[lut_alloc_ptr]   <= 1'b0;
							lut_b_valid[lut_alloc_ptr]   <= 1'b0;
							lut_a_ext_off[lut_alloc_ptr] <= 10'd0;
							lut_a_loc_off[lut_alloc_ptr] <= 10'd0;
							lut_b_ext_off[lut_alloc_ptr] <= 10'd0;
							lut_b_loc_off[lut_alloc_ptr] <= 10'd0;
							lut_alloc_ptr <= lut_alloc_ptr + 1'b1;
						end else begin
							work_lut_idx <= lut_found_idx;
						end

						if (a_hit && b_hit) begin
							patched_inst = cur_inst;
							patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = lut_a_loc_off[lut_found_idx];
							patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = lut_b_loc_off[lut_found_idx];
							enq_inst <= patched_inst;
							enq_id   <= cur_id;
						end else if (!a_hit) begin
							load_is_b        <= 1'b0;
							load_buf_sel     <= a_wr_buf_sel;
							load_ext_off     <= cur_a_off;
							load_total_beats <= A_ELEMS[DMA_BEATS_W-1:0];
							load_recv_count  <= {DMA_BEATS_W{1'b0}};
							irq_r            <= 1'b1;
						end else if (!b_hit) begin
							load_is_b        <= 1'b1;
							load_buf_sel     <= b_wr_buf_sel;
							load_ext_off     <= cur_b_off;
							load_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
							load_recv_count  <= {DMA_BEATS_W{1'b0}};
							irq_r            <= 1'b1;
						end else begin
							patched_inst = cur_inst;
							patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = lut_a_loc_off[work_lut_idx];
							patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = lut_b_loc_off[work_lut_idx];
							enq_inst <= patched_inst;
							enq_id   <= cur_id;
						end
					end

				ST_DMA_REQ: begin
					if (dma_req_ready) begin
						load_recv_count <= {DMA_BEATS_W{1'b0}};
					end
				end

				ST_DMA_RECV: begin
					if (dma_error) begin
						md_resp       <= {1'b1, cur_id[30:0]};
						md_resp_valid <= 1'b1;
						irq_r         <= 1'b1;
					end else if (s_axis_tvalid) begin
						if (!load_is_b) begin
							if (s_axis_tuser == MATRIX_A) begin
								dma_row = load_recv_count / GEMM_X_DIM;
								dma_col = load_recv_count % GEMM_X_DIM;
								a_mem_wr_en   <= 1'b1;
								a_mem_wr_buf  <= load_buf_sel;
								a_mem_wr_lane <= dma_col[A_LW-1:0];
								a_mem_wr_addr <= dma_row[A_AW-1:0];
								a_mem_wr_data <= s_axis_tdata;
							end else begin
								md_resp       <= {1'b1, cur_id[30:0]};
								md_resp_valid <= 1'b1;
								irq_r         <= 1'b1;
							end
						end else begin
							if (s_axis_tuser == MATRIX_B) begin
								dma_row = load_recv_count / GEMM_Y_DIM;
								dma_col = load_recv_count % GEMM_Y_DIM;
								b_mem_wr_en   <= 1'b1;
								b_mem_wr_buf  <= load_buf_sel;
								b_mem_wr_lane <= dma_row[B_LW-1:0];
								b_mem_wr_addr <= dma_col[B_AW-1:0];
								b_mem_wr_data <= s_axis_tdata;
							end else begin
								md_resp       <= {1'b1, cur_id[30:0]};
								md_resp_valid <= 1'b1;
								irq_r         <= 1'b1;
							end
						end

						load_recv_count <= load_recv_count + 1'b1;
					end

						if (s_axis_tvalid && (load_recv_count + 1'b1 >= load_total_beats)) begin
							if (!load_is_b) begin
								lut_a_valid[work_lut_idx]   <= 1'b1;
								lut_a_buf[work_lut_idx]     <= load_buf_sel;
								lut_a_ext_off[work_lut_idx] <= load_ext_off;
								lut_a_loc_off[work_lut_idx] <= make_local_off(load_buf_sel);
								a_wr_buf_sel <= ~a_wr_buf_sel;
								if (!b_hit) begin
									load_is_b        <= 1'b1;
									load_buf_sel     <= b_wr_buf_sel;
									load_ext_off     <= cur_b_off;
									load_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
									load_recv_count  <= {DMA_BEATS_W{1'b0}};
									irq_r            <= 1'b1;
								end else begin
									patched_inst = cur_inst;
									patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = make_local_off(load_buf_sel);
									patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = lut_b_loc_off[work_lut_idx];
									enq_inst <= patched_inst;
									enq_id   <= cur_id;
								end
							end else begin
								lut_b_valid[work_lut_idx]   <= 1'b1;
								lut_b_buf[work_lut_idx]     <= load_buf_sel;
								lut_b_ext_off[work_lut_idx] <= load_ext_off;
								lut_b_loc_off[work_lut_idx] <= make_local_off(load_buf_sel);
								b_wr_buf_sel <= ~b_wr_buf_sel;
								patched_inst = cur_inst;
								patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = lut_a_loc_off[work_lut_idx];
								patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = make_local_off(load_buf_sel);
								enq_inst <= patched_inst;
								enq_id   <= cur_id;
							end
						end
					end

				ST_ENQ_CE: begin
					if (ce_q_in_ready) begin
						md_resp       <= cur_id;
						md_resp_valid <= 1'b1;
					end
				end

				default: begin
				end
			endcase
		end
	end

	// keep currently unused DMA input explicitly referenced
	wire _unused_dma_done = dma_done;

endmodule
