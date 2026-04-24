module PT_AXIS_EGRESS_ADAPTER_V3 #(
	parameter DATA_WIDTH = 32,
	parameter INTERNAL_WORDS = 16,
	parameter STREAM_CHANNELS = 1,
	parameter CHANNEL_WIDTH = INTERNAL_WORDS * DATA_WIDTH
) (
	input  wire                                           clk,
	input  wire                                           rstn,
	input  wire                                           clear,
	input  wire                                           s_axis_tvalid,
	output wire                                           s_axis_tready,
	input  wire [INTERNAL_WORDS*DATA_WIDTH-1:0]           s_axis_tdata,
	input  wire [INTERNAL_WORDS*DATA_WIDTH/8-1:0]         s_axis_tstrb,
	input  wire                                           s_axis_tlast,
	input  wire                                           s_axis_tkeep,
	input  wire                                           s_axis_tid,
	input  wire                                           s_axis_tdest,
	input  wire [1:0]                                     s_axis_tuser,
	output wire [STREAM_CHANNELS-1:0]                     m_axis_tvalid,
	input  wire [STREAM_CHANNELS-1:0]                     m_axis_tready,
	output wire [STREAM_CHANNELS*CHANNEL_WIDTH-1:0]       m_axis_tdata,
	output wire [STREAM_CHANNELS*CHANNEL_WIDTH/8-1:0]     m_axis_tstrb,
	output wire [STREAM_CHANNELS-1:0]                     m_axis_tlast,
	output wire [STREAM_CHANNELS-1:0]                     m_axis_tkeep,
	output wire [STREAM_CHANNELS-1:0]                     m_axis_tid,
	output wire [STREAM_CHANNELS-1:0]                     m_axis_tdest,
	output wire [STREAM_CHANNELS*2-1:0]                   m_axis_tuser
) ;

	localparam integer CHANNEL_WORDS = CHANNEL_WIDTH / DATA_WIDTH;
	localparam integer GROUP_WORDS = STREAM_CHANNELS * CHANNEL_WORDS;
	localparam integer INTERNAL_WIDTH = INTERNAL_WORDS * DATA_WIDTH;
	localparam integer INTERNAL_STRB_W = INTERNAL_WORDS * DATA_WIDTH / 8;
	localparam integer GROUPS_PER_BEAT = INTERNAL_WORDS / GROUP_WORDS;
	localparam integer GROUP_COUNT_W = (GROUPS_PER_BEAT <= 1) ? 1 : $clog2(GROUPS_PER_BEAT + 1);

	reg                        active_r;
	reg [GROUP_COUNT_W-1:0]    group_idx_r;
	reg [INTERNAL_WIDTH-1:0]   hold_data_r;
	reg [INTERNAL_STRB_W-1:0]  hold_strb_r;
	reg                        hold_last_r;
	reg                        hold_keep_r;
	reg                        hold_tid_r;
	reg                        hold_tdest_r;
	reg [1:0]                  hold_user_r;

	wire all_ready = &m_axis_tready;
	assign s_axis_tready = !active_r;
	assign m_axis_tvalid = active_r ? {STREAM_CHANNELS{1'b1}} : {STREAM_CHANNELS{1'b0}};

	integer ch_idx;
	integer lane_idx;
	integer word_idx;
	reg [STREAM_CHANNELS*CHANNEL_WIDTH-1:0]   out_data_r;
	reg [STREAM_CHANNELS*CHANNEL_WIDTH/8-1:0] out_strb_r;
	reg [STREAM_CHANNELS*2-1:0]               out_user_r;
	always @(*) begin
		out_data_r = {STREAM_CHANNELS*CHANNEL_WIDTH{1'b0}};
		out_strb_r = {STREAM_CHANNELS*CHANNEL_WIDTH/8{1'b0}};
		out_user_r = {STREAM_CHANNELS*2{1'b0}};
		for (ch_idx = 0; ch_idx < STREAM_CHANNELS; ch_idx = ch_idx + 1) begin
			out_user_r[(ch_idx * 2) +: 2] = hold_user_r;
			for (lane_idx = 0; lane_idx < CHANNEL_WORDS; lane_idx = lane_idx + 1) begin
				word_idx = (group_idx_r * GROUP_WORDS) + (ch_idx * CHANNEL_WORDS) + lane_idx;
				out_data_r[((ch_idx * CHANNEL_WIDTH) + (lane_idx * DATA_WIDTH)) +: DATA_WIDTH] =
					hold_data_r[(word_idx * DATA_WIDTH) +: DATA_WIDTH];
				out_strb_r[((ch_idx * CHANNEL_WIDTH/8) + (lane_idx * DATA_WIDTH/8)) +: (DATA_WIDTH/8)] =
					hold_strb_r[(word_idx * DATA_WIDTH/8) +: (DATA_WIDTH/8)];
			end
		end
	end

	assign m_axis_tdata = out_data_r;
	assign m_axis_tstrb = out_strb_r;
	assign m_axis_tuser = out_user_r;
	assign m_axis_tlast = (active_r && hold_last_r && ((GROUPS_PER_BEAT == 1) || ((group_idx_r + 1'b1) >= GROUPS_PER_BEAT))) ? {STREAM_CHANNELS{1'b1}} : {STREAM_CHANNELS{1'b0}};
	assign m_axis_tkeep = active_r ? {STREAM_CHANNELS{hold_keep_r}} : {STREAM_CHANNELS{1'b0}};
	assign m_axis_tid   = active_r ? {STREAM_CHANNELS{hold_tid_r}} : {STREAM_CHANNELS{1'b0}};
	assign m_axis_tdest = active_r ? {STREAM_CHANNELS{hold_tdest_r}} : {STREAM_CHANNELS{1'b0}};

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			active_r    <= 1'b0;
			group_idx_r <= {GROUP_COUNT_W{1'b0}};
			hold_data_r <= {INTERNAL_WIDTH{1'b0}};
			hold_strb_r <= {INTERNAL_STRB_W{1'b0}};
			hold_last_r <= 1'b0;
			hold_keep_r <= 1'b0;
			hold_tid_r <= 1'b0;
			hold_tdest_r <= 1'b0;
			hold_user_r <= 2'b00;
		end else if (clear) begin
			active_r    <= 1'b0;
			group_idx_r <= {GROUP_COUNT_W{1'b0}};
			hold_data_r <= {INTERNAL_WIDTH{1'b0}};
			hold_strb_r <= {INTERNAL_STRB_W{1'b0}};
			hold_last_r <= 1'b0;
			hold_keep_r <= 1'b0;
			hold_tid_r <= 1'b0;
			hold_tdest_r <= 1'b0;
			hold_user_r <= 2'b00;
		end else begin
			if (!active_r && s_axis_tvalid) begin
				active_r    <= 1'b1;
				group_idx_r <= {GROUP_COUNT_W{1'b0}};
				hold_data_r <= s_axis_tdata;
				hold_strb_r <= s_axis_tstrb;
				hold_last_r <= s_axis_tlast;
				hold_keep_r <= s_axis_tkeep;
				hold_tid_r <= s_axis_tid;
				hold_tdest_r <= s_axis_tdest;
				hold_user_r <= s_axis_tuser;
			end else if (active_r && all_ready) begin
				if ((GROUPS_PER_BEAT == 1) || ((group_idx_r + 1'b1) >= GROUPS_PER_BEAT)) begin
					active_r    <= 1'b0;
					group_idx_r <= {GROUP_COUNT_W{1'b0}};
				end else begin
					group_idx_r <= group_idx_r + 1'b1;
				end
			end
		end
	end

// synthesis translate_off
	`ifndef SYNTHESIS
		initial begin
			if ((STREAM_CHANNELS != 1) && (STREAM_CHANNELS != 2) && (STREAM_CHANNELS != 4)) begin
				$fatal(1, "PT_AXIS_EGRESS_ADAPTER_V3 requires STREAM_CHANNELS in {1,2,4}, got %0d", STREAM_CHANNELS);
			end
			if ((CHANNEL_WIDTH <= 0) || ((CHANNEL_WIDTH % DATA_WIDTH) != 0)) begin
				$fatal(1, "PT_AXIS_EGRESS_ADAPTER_V3 requires CHANNEL_WIDTH %% DATA_WIDTH == 0, got width=%0d data=%0d", CHANNEL_WIDTH, DATA_WIDTH);
			end
			if ((GROUP_WORDS <= 0) || ((INTERNAL_WORDS % GROUP_WORDS) != 0)) begin
				$fatal(1, "PT_AXIS_EGRESS_ADAPTER_V3 requires INTERNAL_WORDS %% GROUP_WORDS == 0, got internal=%0d group=%0d", INTERNAL_WORDS, GROUP_WORDS);
			end
		end
	`endif
// synthesis translate_on

endmodule
