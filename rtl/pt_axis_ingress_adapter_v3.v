module PT_AXIS_INGRESS_ADAPTER_V3 #(
	parameter DATA_WIDTH = 32,
	parameter INTERNAL_WORDS = 16,
	parameter STREAM_CHANNELS = 1,
	parameter CHANNEL_WIDTH = INTERNAL_WORDS * DATA_WIDTH,
	parameter STREAM_ALIGN_FIFO_DEPTH = 4,
	parameter STREAM_ALIGN_TIMEOUT_CYCLES = 32,
	parameter STREAM_ALIGN_BP_GAP = 3,
	parameter STREAM_ALIGN_ERR_GAP = 4
) (
	input  wire                                           clk,
	input  wire                                           rstn,
	input  wire                                           clear,
	input  wire [STREAM_CHANNELS-1:0]                     active_channel_mask,
	input  wire [STREAM_CHANNELS-1:0]                     s_axis_tvalid,
	output wire [STREAM_CHANNELS-1:0]                     s_axis_tready,
	input  wire [STREAM_CHANNELS*CHANNEL_WIDTH-1:0]       s_axis_tdata,
	input  wire [STREAM_CHANNELS*CHANNEL_WIDTH/8-1:0]     s_axis_tstrb,
	input  wire [STREAM_CHANNELS-1:0]                     s_axis_tlast,
	input  wire [STREAM_CHANNELS-1:0]                     s_axis_tkeep,
	input  wire [STREAM_CHANNELS-1:0]                     s_axis_tid,
	input  wire [STREAM_CHANNELS-1:0]                     s_axis_tdest,
	input  wire [STREAM_CHANNELS*2-1:0]                   s_axis_tuser,
	output wire                                           m_axis_tvalid,
	input  wire                                           m_axis_tready,
	output wire [INTERNAL_WORDS*DATA_WIDTH-1:0]           m_axis_tdata,
	output wire [INTERNAL_WORDS*DATA_WIDTH/8-1:0]         m_axis_tstrb,
	output wire [1:0]                                     m_axis_tuser,
	output wire                                           align_error
);

	localparam integer CHANNEL_WORDS = CHANNEL_WIDTH / DATA_WIDTH;
	localparam integer GROUP_WORDS = STREAM_CHANNELS * CHANNEL_WORDS;
	localparam integer INTERNAL_WIDTH = INTERNAL_WORDS * DATA_WIDTH;
	localparam integer INTERNAL_STRB_W = INTERNAL_WORDS * DATA_WIDTH / 8;
	localparam integer GROUPS_PER_BEAT = INTERNAL_WORDS / GROUP_WORDS;
	localparam integer MAX_GROUPS_PER_BEAT = INTERNAL_WORDS / CHANNEL_WORDS;
	localparam integer GROUP_COUNT_W = (MAX_GROUPS_PER_BEAT <= 1) ? 1 : $clog2(MAX_GROUPS_PER_BEAT + 1);
	localparam integer FIFO_AW = (STREAM_ALIGN_FIFO_DEPTH <= 1) ? 1 : $clog2(STREAM_ALIGN_FIFO_DEPTH);
	localparam integer FIFO_COUNT_W = FIFO_AW + 1;
	localparam integer ALIGN_IDX_W = 16;
	localparam integer ALIGN_TIMEOUT_W = (STREAM_ALIGN_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STREAM_ALIGN_TIMEOUT_CYCLES + 1);

	generate
		if (STREAM_CHANNELS == 1) begin : g_single_channel
			reg [INTERNAL_WIDTH-1:0]   accum_data_r;
			reg [INTERNAL_STRB_W-1:0]  accum_strb_r;
			reg [GROUP_COUNT_W-1:0]    group_idx_r;
			reg                        m_valid_r;
			reg [INTERNAL_WIDTH-1:0]   m_data_r;
			reg [INTERNAL_STRB_W-1:0]  m_strb_r;
			reg [1:0]                  m_user_r;

			wire all_valid = &s_axis_tvalid;
			wire accept_group = !m_valid_r && all_valid;

			assign s_axis_tready = accept_group ? {STREAM_CHANNELS{1'b1}} : {STREAM_CHANNELS{1'b0}};
			assign m_axis_tvalid = m_valid_r;
			assign m_axis_tdata  = m_data_r;
			assign m_axis_tstrb  = m_strb_r;
			assign m_axis_tuser  = m_user_r;
			assign align_error   = 1'b0;

			integer ch_idx;
			integer lane_idx;
			integer word_idx;
			reg [INTERNAL_WIDTH-1:0]  next_accum_data;
			reg [INTERNAL_STRB_W-1:0] next_accum_strb;

			always @(*) begin
				next_accum_data = accum_data_r;
				next_accum_strb = accum_strb_r;
				for (ch_idx = 0; ch_idx < STREAM_CHANNELS; ch_idx = ch_idx + 1) begin
					for (lane_idx = 0; lane_idx < CHANNEL_WORDS; lane_idx = lane_idx + 1) begin
						word_idx = (group_idx_r * GROUP_WORDS) + (ch_idx * CHANNEL_WORDS) + lane_idx;
						next_accum_data[(word_idx * DATA_WIDTH) +: DATA_WIDTH] =
							s_axis_tdata[((ch_idx * CHANNEL_WIDTH) + (lane_idx * DATA_WIDTH)) +: DATA_WIDTH];
						next_accum_strb[(word_idx * DATA_WIDTH/8) +: (DATA_WIDTH/8)] =
							s_axis_tstrb[((ch_idx * CHANNEL_WIDTH/8) + (lane_idx * DATA_WIDTH/8)) +: (DATA_WIDTH/8)];
					end
				end
			end

			always @(posedge clk or negedge rstn) begin
				if (!rstn) begin
					accum_data_r <= {INTERNAL_WIDTH{1'b0}};
					accum_strb_r <= {INTERNAL_STRB_W{1'b0}};
					group_idx_r  <= {GROUP_COUNT_W{1'b0}};
					m_valid_r    <= 1'b0;
					m_data_r     <= {INTERNAL_WIDTH{1'b0}};
					m_strb_r     <= {INTERNAL_STRB_W{1'b0}};
					m_user_r     <= 2'b00;
				end else if (clear) begin
					accum_data_r <= {INTERNAL_WIDTH{1'b0}};
					accum_strb_r <= {INTERNAL_STRB_W{1'b0}};
					group_idx_r  <= {GROUP_COUNT_W{1'b0}};
					m_valid_r    <= 1'b0;
					m_data_r     <= {INTERNAL_WIDTH{1'b0}};
					m_strb_r     <= {INTERNAL_STRB_W{1'b0}};
					m_user_r     <= 2'b00;
				end else begin
					if (m_valid_r && m_axis_tready) begin
						m_valid_r <= 1'b0;
					end
					if (accept_group) begin
						accum_data_r <= next_accum_data;
						accum_strb_r <= next_accum_strb;
						if (GROUPS_PER_BEAT == 1 || ((group_idx_r + 1'b1) >= GROUPS_PER_BEAT)) begin
							m_valid_r <= 1'b1;
							m_data_r  <= next_accum_data;
							m_strb_r  <= next_accum_strb;
							m_user_r  <= s_axis_tuser[1:0];
							group_idx_r <= {GROUP_COUNT_W{1'b0}};
							accum_data_r <= {INTERNAL_WIDTH{1'b0}};
							accum_strb_r <= {INTERNAL_STRB_W{1'b0}};
						end else begin
							group_idx_r <= group_idx_r + 1'b1;
						end
					end
				end
			end
		end else begin : g_multi_channel
			reg [CHANNEL_WIDTH-1:0]         fifo_data_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg [CHANNEL_WIDTH/8-1:0]       fifo_strb_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg [1:0]                       fifo_user_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg                             fifo_last_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg                             fifo_keep_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg                             fifo_tid_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg                             fifo_tdest_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg                             fifo_phase_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];
			reg [ALIGN_IDX_W-1:0]           fifo_idx_r [0:STREAM_CHANNELS-1][0:STREAM_ALIGN_FIFO_DEPTH-1];

			reg [FIFO_AW-1:0]               wr_ptr_r [0:STREAM_CHANNELS-1];
			reg [FIFO_AW-1:0]               rd_ptr_r [0:STREAM_CHANNELS-1];
			reg [FIFO_COUNT_W-1:0]          fifo_count_r [0:STREAM_CHANNELS-1];
			reg                             phase_state_r [0:STREAM_CHANNELS-1];
			reg [ALIGN_IDX_W-1:0]           idx_state_r [0:STREAM_CHANNELS-1];
			reg [ALIGN_IDX_W-1:0]           recv_total_r [0:STREAM_CHANNELS-1];
			reg [ALIGN_TIMEOUT_W-1:0]       align_wait_r;
			reg                             align_error_r;
			reg [INTERNAL_WIDTH-1:0]        accum_data_r;
			reg [INTERNAL_STRB_W-1:0]       accum_strb_r;
			reg [GROUP_COUNT_W-1:0]         group_idx_r;
			reg                             m_valid_r;
			reg [INTERNAL_WIDTH-1:0]        m_data_r;
			reg [INTERNAL_STRB_W-1:0]       m_strb_r;
			reg [1:0]                       m_user_r;

			reg [STREAM_CHANNELS-1:0]       push_fire_w;
			reg [STREAM_CHANNELS-1:0]       ready_mask_w;
			reg [STREAM_CHANNELS-1:0]       active_mask_w;
			reg                             any_nonempty_w;
			reg                             all_nonempty_w;
			reg                             active_nonzero_w;
			reg                             active_mask_invalid_w;
			reg [ALIGN_IDX_W-1:0]           min_total_w;
			reg [ALIGN_IDX_W-1:0]           max_total_w;
			reg [ALIGN_IDX_W-1:0]           active_count_w;
			reg [ALIGN_IDX_W-1:0]           active_group_words_w;
			reg [ALIGN_IDX_W-1:0]           groups_per_beat_w;
			reg                             active_found_w;
			reg                             keys_equal_w;
			reg                             sideband_equal_w;
			reg                             ref_valid_w;
			reg                             ref_phase_w;
			reg [ALIGN_IDX_W-1:0]           ref_idx_w;
			reg [1:0]                       ref_user_w;
			reg                             ref_last_w;
			reg                             ref_keep_w;
			reg                             ref_tid_w;
			reg                             ref_tdest_w;
			reg [1:0]                       next_user_w;
			reg [INTERNAL_WIDTH-1:0]        next_accum_data_w;
			reg [INTERNAL_STRB_W-1:0]       next_accum_strb_w;
			reg                             partial_last_error_w;
			reg                             gap_error_w;
			reg                             timeout_error_w;
			reg                             sideband_error_w;
			reg                             emit_group_fire_w;
			reg                             timeout_track_w;
			reg [ALIGN_IDX_W-1:0]           gap_value_w;
			integer                         ch_idx;
			integer                         lane_idx;
			integer                         word_idx;

			assign s_axis_tready = ready_mask_w;
			assign m_axis_tvalid = m_valid_r;
			assign m_axis_tdata  = m_data_r;
			assign m_axis_tstrb  = m_strb_r;
			assign m_axis_tuser  = m_user_r;
			assign align_error   = align_error_r;

			always @(*) begin
				min_total_w = recv_total_r[0];
				max_total_w = recv_total_r[0];
				any_nonempty_w = 1'b0;
				all_nonempty_w = 1'b1;
				active_nonzero_w = 1'b0;
				active_mask_invalid_w = 1'b0;
				active_count_w = {ALIGN_IDX_W{1'b0}};
				active_group_words_w = {ALIGN_IDX_W{1'b0}};
				groups_per_beat_w = {ALIGN_IDX_W{1'b0}};
				active_found_w = 1'b0;
				keys_equal_w = 1'b1;
				sideband_equal_w = 1'b1;
				ref_valid_w = 1'b0;
				ref_phase_w = 1'b0;
				ref_idx_w = {ALIGN_IDX_W{1'b0}};
				ref_user_w = 2'b00;
				ref_last_w = 1'b0;
				ref_keep_w = 1'b0;
				ref_tid_w = 1'b0;
				ref_tdest_w = 1'b0;
				next_user_w = 2'b00;
				next_accum_data_w = accum_data_r;
				next_accum_strb_w = accum_strb_r;
				gap_value_w = {ALIGN_IDX_W{1'b0}};
				active_mask_w = active_channel_mask;

				for (ch_idx = 0; ch_idx < STREAM_CHANNELS; ch_idx = ch_idx + 1) begin
					if (active_mask_w[ch_idx]) begin
						active_nonzero_w = 1'b1;
						active_count_w = active_count_w + 1'b1;
						if (!active_found_w) begin
							min_total_w = recv_total_r[ch_idx];
							max_total_w = recv_total_r[ch_idx];
							active_found_w = 1'b1;
						end else if (recv_total_r[ch_idx] < min_total_w) begin
							min_total_w = recv_total_r[ch_idx];
						end
						if (recv_total_r[ch_idx] > max_total_w) begin
							max_total_w = recv_total_r[ch_idx];
						end
						if (fifo_count_r[ch_idx] != 0) begin
							any_nonempty_w = 1'b1;
						end else begin
							all_nonempty_w = 1'b0;
						end
					end
				end

				if (active_nonzero_w) begin
					active_group_words_w = active_count_w * CHANNEL_WORDS;
					if ((active_group_words_w == 0) || ((INTERNAL_WORDS % active_group_words_w) != 0)) begin
						active_mask_invalid_w = 1'b1;
					end else begin
						groups_per_beat_w = INTERNAL_WORDS / active_group_words_w;
					end
				end else begin
					all_nonempty_w = 1'b0;
				end

				if (all_nonempty_w && active_nonzero_w && !active_mask_invalid_w) begin
					for (ch_idx = 0; ch_idx < STREAM_CHANNELS; ch_idx = ch_idx + 1) begin
						if (active_mask_w[ch_idx] && !ref_valid_w) begin
							ref_phase_w = fifo_phase_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_idx_w = fifo_idx_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_user_w = fifo_user_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_last_w = fifo_last_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_keep_w = fifo_keep_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_tid_w = fifo_tid_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_tdest_w = fifo_tdest_r[ch_idx][rd_ptr_r[ch_idx]];
							next_user_w = fifo_user_r[ch_idx][rd_ptr_r[ch_idx]];
							ref_valid_w = 1'b1;
						end
					end
					word_idx = 0;
					for (ch_idx = 0; ch_idx < STREAM_CHANNELS; ch_idx = ch_idx + 1) begin
						if (active_mask_w[ch_idx]) begin
							if ((fifo_phase_r[ch_idx][rd_ptr_r[ch_idx]] != ref_phase_w) || (fifo_idx_r[ch_idx][rd_ptr_r[ch_idx]] != ref_idx_w)) begin
								keys_equal_w = 1'b0;
							end
							if ((fifo_user_r[ch_idx][rd_ptr_r[ch_idx]] != ref_user_w)
							 || (fifo_last_r[ch_idx][rd_ptr_r[ch_idx]] != ref_last_w)
							 || (fifo_keep_r[ch_idx][rd_ptr_r[ch_idx]] != ref_keep_w)
							 || (fifo_tid_r[ch_idx][rd_ptr_r[ch_idx]] != ref_tid_w)
							 || (fifo_tdest_r[ch_idx][rd_ptr_r[ch_idx]] != ref_tdest_w)) begin
								sideband_equal_w = 1'b0;
							end
							for (lane_idx = 0; lane_idx < CHANNEL_WORDS; lane_idx = lane_idx + 1) begin
								next_accum_data_w[(((group_idx_r * active_group_words_w) + (word_idx * CHANNEL_WORDS) + lane_idx) * DATA_WIDTH) +: DATA_WIDTH] =
									fifo_data_r[ch_idx][rd_ptr_r[ch_idx]][(lane_idx * DATA_WIDTH) +: DATA_WIDTH];
								next_accum_strb_w[(((group_idx_r * active_group_words_w) + (word_idx * CHANNEL_WORDS) + lane_idx) * DATA_WIDTH/8) +: (DATA_WIDTH/8)] =
									fifo_strb_r[ch_idx][rd_ptr_r[ch_idx]][(lane_idx * DATA_WIDTH/8) +: (DATA_WIDTH/8)];
							end
							word_idx = word_idx + 1;
						end
					end
				end

				gap_value_w = max_total_w - min_total_w;
				gap_error_w = active_nonzero_w && (gap_value_w >= STREAM_ALIGN_ERR_GAP);
				sideband_error_w = all_nonempty_w && active_nonzero_w && keys_equal_w && !sideband_equal_w;
				partial_last_error_w = all_nonempty_w && active_nonzero_w && keys_equal_w && sideband_equal_w &&
					ref_last_w && (groups_per_beat_w != 1) && ((group_idx_r + 1'b1) < groups_per_beat_w);
				emit_group_fire_w = !align_error_r && !m_valid_r &&
					all_nonempty_w && active_nonzero_w && !active_mask_invalid_w &&
					keys_equal_w && sideband_equal_w &&
					!gap_error_w && !partial_last_error_w;
				timeout_track_w = !align_error_r && !m_valid_r && any_nonempty_w && !emit_group_fire_w;
				timeout_error_w = timeout_track_w && (align_wait_r >= (STREAM_ALIGN_TIMEOUT_CYCLES - 1));

				for (ch_idx = 0; ch_idx < STREAM_CHANNELS; ch_idx = ch_idx + 1) begin
					ready_mask_w[ch_idx] = 1'b0;
					if (!align_error_r && active_mask_w[ch_idx] && !active_mask_invalid_w) begin
						if ((recv_total_r[ch_idx] - min_total_w) < STREAM_ALIGN_BP_GAP) begin
							if ((fifo_count_r[ch_idx] < STREAM_ALIGN_FIFO_DEPTH) || (emit_group_fire_w && active_mask_w[ch_idx])) begin
								ready_mask_w[ch_idx] = 1'b1;
							end
						end
					end
					push_fire_w[ch_idx] = s_axis_tvalid[ch_idx] && ready_mask_w[ch_idx];
				end
			end

			integer fifo_ch;
			integer fifo_idx;
			always @(posedge clk or negedge rstn) begin
				if (!rstn) begin
					align_wait_r <= {ALIGN_TIMEOUT_W{1'b0}};
					align_error_r <= 1'b0;
					accum_data_r <= {INTERNAL_WIDTH{1'b0}};
					accum_strb_r <= {INTERNAL_STRB_W{1'b0}};
					group_idx_r <= {GROUP_COUNT_W{1'b0}};
					m_valid_r <= 1'b0;
					m_data_r <= {INTERNAL_WIDTH{1'b0}};
					m_strb_r <= {INTERNAL_STRB_W{1'b0}};
					m_user_r <= 2'b00;
					for (fifo_ch = 0; fifo_ch < STREAM_CHANNELS; fifo_ch = fifo_ch + 1) begin
						wr_ptr_r[fifo_ch] <= {FIFO_AW{1'b0}};
						rd_ptr_r[fifo_ch] <= {FIFO_AW{1'b0}};
						fifo_count_r[fifo_ch] <= {FIFO_COUNT_W{1'b0}};
						phase_state_r[fifo_ch] <= 1'b0;
						idx_state_r[fifo_ch] <= {ALIGN_IDX_W{1'b0}};
						recv_total_r[fifo_ch] <= {ALIGN_IDX_W{1'b0}};
						for (fifo_idx = 0; fifo_idx < STREAM_ALIGN_FIFO_DEPTH; fifo_idx = fifo_idx + 1) begin
							fifo_data_r[fifo_ch][fifo_idx] <= {CHANNEL_WIDTH{1'b0}};
							fifo_strb_r[fifo_ch][fifo_idx] <= {CHANNEL_WIDTH/8{1'b0}};
							fifo_user_r[fifo_ch][fifo_idx] <= 2'b00;
							fifo_last_r[fifo_ch][fifo_idx] <= 1'b0;
							fifo_keep_r[fifo_ch][fifo_idx] <= 1'b0;
							fifo_tid_r[fifo_ch][fifo_idx] <= 1'b0;
							fifo_tdest_r[fifo_ch][fifo_idx] <= 1'b0;
							fifo_phase_r[fifo_ch][fifo_idx] <= 1'b0;
							fifo_idx_r[fifo_ch][fifo_idx] <= {ALIGN_IDX_W{1'b0}};
						end
					end
				end else if (clear) begin
					align_wait_r <= {ALIGN_TIMEOUT_W{1'b0}};
					align_error_r <= 1'b0;
					accum_data_r <= {INTERNAL_WIDTH{1'b0}};
					accum_strb_r <= {INTERNAL_STRB_W{1'b0}};
					group_idx_r <= {GROUP_COUNT_W{1'b0}};
					m_valid_r <= 1'b0;
					m_data_r <= {INTERNAL_WIDTH{1'b0}};
					m_strb_r <= {INTERNAL_STRB_W{1'b0}};
					m_user_r <= 2'b00;
					for (fifo_ch = 0; fifo_ch < STREAM_CHANNELS; fifo_ch = fifo_ch + 1) begin
						wr_ptr_r[fifo_ch] <= {FIFO_AW{1'b0}};
						rd_ptr_r[fifo_ch] <= {FIFO_AW{1'b0}};
						fifo_count_r[fifo_ch] <= {FIFO_COUNT_W{1'b0}};
						phase_state_r[fifo_ch] <= 1'b0;
						idx_state_r[fifo_ch] <= {ALIGN_IDX_W{1'b0}};
						recv_total_r[fifo_ch] <= {ALIGN_IDX_W{1'b0}};
					end
				end else begin
					if (m_valid_r && m_axis_tready) begin
						m_valid_r <= 1'b0;
					end

					for (fifo_ch = 0; fifo_ch < STREAM_CHANNELS; fifo_ch = fifo_ch + 1) begin
						if (push_fire_w[fifo_ch]) begin
							fifo_data_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tdata[(fifo_ch * CHANNEL_WIDTH) +: CHANNEL_WIDTH];
							fifo_strb_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tstrb[(fifo_ch * CHANNEL_WIDTH/8) +: (CHANNEL_WIDTH/8)];
							fifo_user_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tuser[(fifo_ch * 2) +: 2];
							fifo_last_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tlast[fifo_ch];
							fifo_keep_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tkeep[fifo_ch];
							fifo_tid_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tid[fifo_ch];
							fifo_tdest_r[fifo_ch][wr_ptr_r[fifo_ch]] <= s_axis_tdest[fifo_ch];
							fifo_phase_r[fifo_ch][wr_ptr_r[fifo_ch]] <= phase_state_r[fifo_ch];
							fifo_idx_r[fifo_ch][wr_ptr_r[fifo_ch]] <= idx_state_r[fifo_ch];
						end

						case ({push_fire_w[fifo_ch], (emit_group_fire_w && active_mask_w[fifo_ch])})
							2'b10: begin
								wr_ptr_r[fifo_ch] <= wr_ptr_r[fifo_ch] + 1'b1;
								fifo_count_r[fifo_ch] <= fifo_count_r[fifo_ch] + 1'b1;
							end
							2'b01: begin
								rd_ptr_r[fifo_ch] <= rd_ptr_r[fifo_ch] + 1'b1;
								fifo_count_r[fifo_ch] <= fifo_count_r[fifo_ch] - 1'b1;
							end
							2'b11: begin
								wr_ptr_r[fifo_ch] <= wr_ptr_r[fifo_ch] + 1'b1;
								rd_ptr_r[fifo_ch] <= rd_ptr_r[fifo_ch] + 1'b1;
							end
							default: begin end
						endcase

						if (push_fire_w[fifo_ch]) begin
							recv_total_r[fifo_ch] <= recv_total_r[fifo_ch] + 1'b1;
							if (s_axis_tlast[fifo_ch]) begin
								phase_state_r[fifo_ch] <= ~phase_state_r[fifo_ch];
								idx_state_r[fifo_ch] <= {ALIGN_IDX_W{1'b0}};
							end else begin
								idx_state_r[fifo_ch] <= idx_state_r[fifo_ch] + 1'b1;
							end
						end
					end

					if (emit_group_fire_w) begin
						align_wait_r <= {ALIGN_TIMEOUT_W{1'b0}};
						accum_data_r <= next_accum_data_w;
						accum_strb_r <= next_accum_strb_w;
						if ((groups_per_beat_w == 1) || ((group_idx_r + 1'b1) >= groups_per_beat_w)) begin
							m_valid_r <= 1'b1;
							m_data_r <= next_accum_data_w;
							m_strb_r <= next_accum_strb_w;
							m_user_r <= next_user_w;
							group_idx_r <= {GROUP_COUNT_W{1'b0}};
							accum_data_r <= {INTERNAL_WIDTH{1'b0}};
							accum_strb_r <= {INTERNAL_STRB_W{1'b0}};
						end else begin
							group_idx_r <= group_idx_r + 1'b1;
						end
					end else if (timeout_track_w) begin
						if (align_wait_r < STREAM_ALIGN_TIMEOUT_CYCLES) begin
							align_wait_r <= align_wait_r + 1'b1;
						end
					end else begin
						align_wait_r <= {ALIGN_TIMEOUT_W{1'b0}};
					end

					if (active_mask_invalid_w || sideband_error_w || partial_last_error_w || gap_error_w || timeout_error_w) begin
						align_error_r <= 1'b1;
					end
				end
			end
		end
	endgenerate

// synthesis translate_off
	`ifndef SYNTHESIS
		initial begin
			if ((STREAM_CHANNELS != 1) && (STREAM_CHANNELS != 2) && (STREAM_CHANNELS != 4)) begin
				$fatal(1, "PT_AXIS_INGRESS_ADAPTER_V3 requires STREAM_CHANNELS in {1,2,4}, got %0d", STREAM_CHANNELS);
			end
			if ((CHANNEL_WIDTH <= 0) || ((CHANNEL_WIDTH % DATA_WIDTH) != 0)) begin
				$fatal(1, "PT_AXIS_INGRESS_ADAPTER_V3 requires CHANNEL_WIDTH %% DATA_WIDTH == 0, got width=%0d data=%0d", CHANNEL_WIDTH, DATA_WIDTH);
			end
			if ((GROUP_WORDS <= 0) || ((INTERNAL_WORDS % GROUP_WORDS) != 0)) begin
				$fatal(1, "PT_AXIS_INGRESS_ADAPTER_V3 requires INTERNAL_WORDS %% GROUP_WORDS == 0, got internal=%0d group=%0d", INTERNAL_WORDS, GROUP_WORDS);
			end
			if (STREAM_ALIGN_FIFO_DEPTH <= 0) begin
				$fatal(1, "PT_AXIS_INGRESS_ADAPTER_V3 requires STREAM_ALIGN_FIFO_DEPTH > 0, got %0d", STREAM_ALIGN_FIFO_DEPTH);
			end
			if (STREAM_ALIGN_TIMEOUT_CYCLES <= 0) begin
				$fatal(1, "PT_AXIS_INGRESS_ADAPTER_V3 requires STREAM_ALIGN_TIMEOUT_CYCLES > 0, got %0d", STREAM_ALIGN_TIMEOUT_CYCLES);
			end
			if ((STREAM_CHANNELS > 1) && (STREAM_ALIGN_ERR_GAP <= STREAM_ALIGN_BP_GAP)) begin
				$fatal(1, "PT_AXIS_INGRESS_ADAPTER_V3 requires STREAM_ALIGN_ERR_GAP > STREAM_ALIGN_BP_GAP, got err=%0d bp=%0d", STREAM_ALIGN_ERR_GAP, STREAM_ALIGN_BP_GAP);
			end
		end
	`endif
// synthesis translate_on

endmodule
