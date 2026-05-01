module FA_AXI_RD_MASTER (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         rd_desc_valid,
    output wire         rd_desc_ready,
    input  wire [63:0]  rd_desc_addr,
    input  wire [15:0]  rd_desc_words,
    input  wire [3:0]   rd_desc_tag,
    output reg          rd_beat_valid,
    input  wire         rd_beat_ready,
    output reg  [127:0] rd_beat_data,
    output reg  [2:0]   rd_beat_word_count,
    output reg          rd_beat_last,
    output reg          axi_arvalid,
    input  wire         axi_arready,
    output reg  [63:0]  axi_araddr,
    output reg  [7:0]   axi_arlen,
    output wire [2:0]   axi_arsize,
    output wire [1:0]   axi_arburst,
    input  wire [127:0] axi_rdata,
    input  wire [1:0]   axi_rresp,
    input  wire         axi_rlast,
    input  wire         axi_rvalid,
    output wire         axi_rready,
    output reg          error_pulse
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_AR    = 3'd1;
    localparam [2:0] ST_R     = 3'd2;
    localparam [2:0] ST_ABORT = 3'd3;
    localparam [15:0] WORDS_PER_BEAT_W = 16'd4;
    localparam [2:0]  WORDS_PER_BEAT_COUNT_W = 3'd4;
    localparam [15:0] MAX_BURST_BEATS_W = 16'd16;
    localparam [7:0]  MAX_BURST_LEN_W = 8'd15;

    reg [2:0]  state_r;
    reg [2:0]  state_n;
    reg [63:0] desc_addr_r;
    reg [15:0] words_remaining_r;
    reg [15:0] burst_beats_r;
    reg [15:0] beats_seen_r;
    wire [15:0] words_in_beat_w = (words_remaining_r >= WORDS_PER_BEAT_W) ? WORDS_PER_BEAT_W : words_remaining_r;
    wire [2:0]  rd_beat_word_count_next_w = words_in_beat_w[2:0];
    wire [15:0] remaining_words_after_beat_w = (words_remaining_r > words_in_beat_w) ? (words_remaining_r - words_in_beat_w) : 16'd0;
    wire [15:0] next_total_beats_after_w = ceil_words_to_beats(remaining_words_after_beat_w);
    wire [15:0] rd_desc_total_beats_w = ceil_words_to_beats(rd_desc_words);
    wire [15:0] beats_seen_next_w = beats_seen_r + 16'd1;
    wire        rd_beat_fire_w = rd_beat_valid && rd_beat_ready;
    wire axi_r_fire_w = axi_rvalid && axi_rready;

    function automatic [15:0] ceil_words_to_beats;
        input [15:0] words;
        reg [17:0] rounded_words;
        begin
            rounded_words = {2'b00, words} + 18'd3;
            ceil_words_to_beats = rounded_words[17:2];
        end
    endfunction

    function automatic [7:0] burst_len_from_beats;
        input [15:0] beats;
        begin
            burst_len_from_beats = beats[7:0] - 8'd1;
        end
    endfunction

    function automatic [63:0] addr_after_burst;
        input [63:0] addr;
        input [15:0] beats;
        begin
            addr_after_burst = addr + ({48'd0, beats} << 4);
        end
    endfunction

    assign rd_desc_ready = (state_r == ST_IDLE) || ((|rd_desc_tag) & 1'b0);
    assign axi_arsize = 3'b100;
    assign axi_arburst = 2'b01;
    assign axi_rready = (state_r == ST_R) && !rd_beat_valid;

    always @(*) begin
        state_n = state_r;
        case (state_r)
            ST_IDLE: begin
                if (rd_desc_valid && rd_desc_ready) begin
                    state_n = ST_AR;
                end
            end
            ST_AR: begin
                if (axi_arvalid && axi_arready) begin
                    state_n = ST_R;
                end
            end
            ST_R: begin
                if (axi_r_fire_w) begin
                    if (axi_rresp != 2'b00) begin
                        state_n = ST_ABORT;
                    end else if ((beats_seen_next_w == burst_beats_r) && !axi_rlast) begin
                        state_n = ST_ABORT;
                    end else if ((beats_seen_next_w < burst_beats_r) && axi_rlast) begin
                        state_n = ST_ABORT;
                    end else if (beats_seen_next_w == burst_beats_r) begin
                        if (remaining_words_after_beat_w != 16'd0) begin
                            state_n = ST_AR;
                        end else begin
                            state_n = ST_R;
                        end
                    end
                end
                if ((words_remaining_r == 16'd0) && !rd_beat_valid && !axi_arvalid) begin
                    state_n = ST_IDLE;
                end
            end
            ST_ABORT: begin
                if (!rd_beat_valid && (words_remaining_r == 16'd0)) begin
                    state_n = ST_IDLE;
                end
            end
            default: begin
                state_n = ST_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
        end else if (clear) begin
            state_r <= ST_IDLE;
        end else begin
            state_r <= state_n;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            desc_addr_r <= 64'd0;
            words_remaining_r <= 16'd0;
            burst_beats_r <= 16'd0;
            beats_seen_r <= 16'd0;
            rd_beat_valid <= 1'b0;
            rd_beat_data <= 128'd0;
            rd_beat_word_count <= 3'd0;
            rd_beat_last <= 1'b0;
            axi_arvalid <= 1'b0;
            axi_araddr <= 64'd0;
            axi_arlen <= 8'd0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            desc_addr_r <= 64'd0;
            words_remaining_r <= 16'd0;
            burst_beats_r <= 16'd0;
            beats_seen_r <= 16'd0;
            rd_beat_valid <= 1'b0;
            rd_beat_data <= 128'd0;
            rd_beat_word_count <= 3'd0;
            rd_beat_last <= 1'b0;
            axi_arvalid <= 1'b0;
            axi_araddr <= 64'd0;
            axi_arlen <= 8'd0;
            error_pulse <= 1'b0;
        end else begin
            error_pulse <= 1'b0;

            if (rd_beat_fire_w) begin
                rd_beat_valid <= 1'b0;
                rd_beat_data <= 128'd0;
                rd_beat_word_count <= 3'd0;
                rd_beat_last <= 1'b0;
                words_remaining_r <= words_remaining_r - {13'd0, rd_beat_word_count};
            end

            case (state_r)
                ST_IDLE: begin
                    if (rd_desc_valid && rd_desc_ready) begin
                        desc_addr_r <= rd_desc_addr;
                        words_remaining_r <= rd_desc_words;
                        axi_araddr <= rd_desc_addr;
                        burst_beats_r <= rd_desc_total_beats_w;
                        if (rd_desc_total_beats_w > MAX_BURST_BEATS_W) begin
                            burst_beats_r <= MAX_BURST_BEATS_W;
                            axi_arlen <= MAX_BURST_LEN_W;
                        end else begin
                            axi_arlen <= burst_len_from_beats(rd_desc_total_beats_w);
                        end
                        beats_seen_r <= 16'd0;
                        axi_arvalid <= 1'b1;
                    end
                end
                ST_AR: begin
                    if (axi_arvalid && axi_arready) begin
                        axi_arvalid <= 1'b0;
                    end
                end
                ST_R: begin
                    if (axi_r_fire_w) begin
                        if (axi_rresp != 2'b00) begin
                            error_pulse <= 1'b1;
                            rd_beat_valid <= 1'b1;
                            rd_beat_data <= 128'd0;
                            rd_beat_word_count <= 3'd1;
                            rd_beat_last <= 1'b1;
                            words_remaining_r <= 16'd1;
                        end else begin
                            rd_beat_valid <= 1'b1;
                            rd_beat_data <= axi_rdata;
                            rd_beat_word_count <= rd_beat_word_count_next_w;
                            rd_beat_last <= (remaining_words_after_beat_w == 16'd0);
                            beats_seen_r <= beats_seen_next_w;
                            if ((beats_seen_next_w == burst_beats_r) && !axi_rlast) begin
                                error_pulse <= 1'b1;
                            end else if ((beats_seen_next_w < burst_beats_r) && axi_rlast) begin
                                error_pulse <= 1'b1;
                            end else if (beats_seen_next_w == burst_beats_r) begin
                                if (remaining_words_after_beat_w != 16'd0) begin
                                    desc_addr_r <= addr_after_burst(desc_addr_r, burst_beats_r);
                                    axi_araddr <= addr_after_burst(desc_addr_r, burst_beats_r);
                                    if (next_total_beats_after_w > MAX_BURST_BEATS_W) begin
                                        burst_beats_r <= MAX_BURST_BEATS_W;
                                        axi_arlen <= MAX_BURST_LEN_W;
                                    end else begin
                                        burst_beats_r <= next_total_beats_after_w;
                                        axi_arlen <= burst_len_from_beats(next_total_beats_after_w);
                                    end
                                    beats_seen_r <= 16'd0;
                                    axi_arvalid <= 1'b1;
                                end
                            end
                        end
                    end
                end
                ST_ABORT: begin
                end
                default: begin
                end
            endcase
        end
    end

endmodule

module FA_AXI_WR_MASTER (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         wr_desc_valid,
    output wire         wr_desc_ready,
    input  wire [63:0]  wr_desc_addr,
    input  wire [15:0]  wr_desc_words,
    input  wire         wr_data_valid,
    output wire         wr_data_ready,
    input  wire [31:0]  wr_data,
    input  wire         wr_data_last,
    output reg          axi_awvalid,
    input  wire         axi_awready,
    output reg  [63:0]  axi_awaddr,
    output reg  [7:0]   axi_awlen,
    output wire [2:0]   axi_awsize,
    output wire [1:0]   axi_awburst,
    output reg          axi_wvalid,
    input  wire         axi_wready,
    output reg  [127:0] axi_wdata,
    output reg  [15:0]  axi_wstrb,
    output reg          axi_wlast,
    input  wire [1:0]   axi_bresp,
    input  wire         axi_bvalid,
    output reg          axi_bready,
    output reg          error_pulse
);

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_AW     = 3'd1;
    localparam [2:0] ST_GATHER = 3'd2;
    localparam [2:0] ST_W      = 3'd3;
    localparam [2:0] ST_B      = 3'd4;
    localparam [15:0] WORDS_PER_BEAT_W = 16'd4;
    localparam [2:0]  WORDS_PER_BEAT_COUNT_W = 3'd4;
    localparam [15:0] MAX_BURST_BEATS_W = 16'd16;
    localparam [15:0] MAX_BURST_WORDS_W = 16'd64;
    localparam [7:0]  MAX_BURST_LEN_W = 8'd15;

    reg [2:0]  state_r;
    reg [2:0]  state_n;
    reg [63:0] desc_addr_r;
    reg [15:0] words_remaining_r;
    reg [15:0] burst_beats_r;
    reg [15:0] beats_sent_r;
    reg [2:0]  beat_word_count_r;
    reg [127:0] beat_buf_r;
    reg [15:0] beat_strb_r;
    reg [15:0] words_in_burst_r;

    wire [15:0] total_beats_w = ceil_words_to_beats(words_remaining_r);
    wire [15:0] wr_desc_total_beats_w = ceil_words_to_beats(wr_desc_words);
    assign wr_desc_ready = (state_r == ST_IDLE);
    assign wr_data_ready = ((state_r == ST_GATHER) && (beat_word_count_r < WORDS_PER_BEAT_COUNT_W)) || (wr_data_last & 1'b0);
    assign axi_awsize = 3'b100;
    assign axi_awburst = 2'b01;

    function automatic [15:0] ceil_words_to_beats;
        input [15:0] words;
        reg [17:0] rounded_words;
        begin
            rounded_words = {2'b00, words} + 18'd3;
            ceil_words_to_beats = rounded_words[17:2];
        end
    endfunction

    function automatic [7:0] burst_len_from_beats;
        input [15:0] beats;
        begin
            burst_len_from_beats = beats[7:0] - 8'd1;
        end
    endfunction

    function automatic [63:0] addr_after_burst;
        input [63:0] addr;
        input [15:0] beats;
        begin
            addr_after_burst = addr + ({48'd0, beats} << 4);
        end
    endfunction

    always @(*) begin
        state_n = state_r;
        case (state_r)
            ST_IDLE: begin
                if (wr_desc_valid && wr_desc_ready) begin
                    state_n = ST_AW;
                end
            end
            ST_AW: begin
                if (axi_awvalid && axi_awready) begin
                    state_n = ST_GATHER;
                end
            end
            ST_GATHER: begin
                if (wr_data_valid && wr_data_ready) begin
                    if ((beat_word_count_r == 3'd3) || (words_in_burst_r == 16'd1)) begin
                        state_n = ST_W;
                    end
                end
            end
            ST_W: begin
                if (axi_wvalid && axi_wready) begin
                    if (axi_wlast) begin
                        state_n = ST_B;
                    end else begin
                        state_n = ST_GATHER;
                    end
                end
            end
            ST_B: begin
                if (axi_bvalid && axi_bready) begin
                    if (words_remaining_r != 16'd0) begin
                        state_n = ST_AW;
                    end else begin
                        state_n = ST_IDLE;
                    end
                end
            end
            default: begin
                state_n = ST_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
        end else if (clear) begin
            state_r <= ST_IDLE;
        end else begin
            state_r <= state_n;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            desc_addr_r <= 64'd0;
            words_remaining_r <= 16'd0;
            burst_beats_r <= 16'd0;
            beats_sent_r <= 16'd0;
            beat_word_count_r <= 3'd0;
            beat_buf_r <= 128'd0;
            beat_strb_r <= 16'd0;
            words_in_burst_r <= 16'd0;
            axi_awvalid <= 1'b0;
            axi_awaddr <= 64'd0;
            axi_awlen <= 8'd0;
            axi_wvalid <= 1'b0;
            axi_wdata <= 128'd0;
            axi_wstrb <= 16'd0;
            axi_wlast <= 1'b0;
            axi_bready <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            desc_addr_r <= 64'd0;
            words_remaining_r <= 16'd0;
            burst_beats_r <= 16'd0;
            beats_sent_r <= 16'd0;
            beat_word_count_r <= 3'd0;
            beat_buf_r <= 128'd0;
            beat_strb_r <= 16'd0;
            words_in_burst_r <= 16'd0;
            axi_awvalid <= 1'b0;
            axi_awaddr <= 64'd0;
            axi_awlen <= 8'd0;
            axi_wvalid <= 1'b0;
            axi_wdata <= 128'd0;
            axi_wstrb <= 16'd0;
            axi_wlast <= 1'b0;
            axi_bready <= 1'b0;
            error_pulse <= 1'b0;
        end else begin
            error_pulse <= 1'b0;

            case (state_r)
                ST_IDLE: begin
                    if (wr_desc_valid && wr_desc_ready) begin
                        desc_addr_r <= wr_desc_addr;
                        words_remaining_r <= wr_desc_words;
                        axi_awaddr <= wr_desc_addr;
                        if (wr_desc_total_beats_w > MAX_BURST_BEATS_W) begin
                            burst_beats_r <= MAX_BURST_BEATS_W;
                            axi_awlen <= MAX_BURST_LEN_W;
                            words_in_burst_r <= MAX_BURST_WORDS_W;
                        end else begin
                            burst_beats_r <= wr_desc_total_beats_w;
                            axi_awlen <= burst_len_from_beats(wr_desc_total_beats_w);
                            words_in_burst_r <= wr_desc_words;
                        end
                        beats_sent_r <= 16'd0;
                        axi_awvalid <= 1'b1;
                    end
                end
                ST_AW: begin
                    if (axi_awvalid && axi_awready) begin
                        axi_awvalid <= 1'b0;
                        beat_word_count_r <= 3'd0;
                        beat_buf_r <= 128'd0;
                        beat_strb_r <= 16'd0;
                    end
                end
                ST_GATHER: begin
                    if (wr_data_valid && wr_data_ready) begin
                        beat_buf_r[(beat_word_count_r * 32) +: 32] <= wr_data;
                        beat_strb_r[(beat_word_count_r * 4) +: 4] <= 4'hF;
                        if ((beat_word_count_r == 3'd3) || (words_in_burst_r == 16'd1)) begin
                            axi_wvalid <= 1'b1;
                            axi_wdata <= beat_buf_r_next(beat_buf_r, wr_data, beat_word_count_r);
                            axi_wstrb <= beat_strb_next(beat_strb_r, beat_word_count_r);
                            axi_wlast <= (beats_sent_r == (burst_beats_r - 16'd1));
                            words_in_burst_r <= words_in_burst_r - 16'd1;
                            words_remaining_r <= words_remaining_r - 16'd1;
                        end else begin
                            beat_word_count_r <= beat_word_count_r + 1'b1;
                            words_in_burst_r <= words_in_burst_r - 16'd1;
                            words_remaining_r <= words_remaining_r - 16'd1;
                        end
                    end
                end
                ST_W: begin
                    if (axi_wvalid && axi_wready) begin
                        axi_wvalid <= 1'b0;
                        beat_word_count_r <= 3'd0;
                        beat_buf_r <= 128'd0;
                        beat_strb_r <= 16'd0;
                        if (axi_wlast) begin
                            axi_bready <= 1'b1;
                        end else begin
                            beats_sent_r <= beats_sent_r + 16'd1;
                        end
                    end
                end
                ST_B: begin
                    if (axi_bvalid && axi_bready) begin
                        axi_bready <= 1'b0;
                        if (axi_bresp != 2'b00) begin
                            error_pulse <= 1'b1;
                        end
                        if (words_remaining_r != 16'd0) begin
                            desc_addr_r <= addr_after_burst(desc_addr_r, burst_beats_r);
                            axi_awaddr <= addr_after_burst(desc_addr_r, burst_beats_r);
                            if (total_beats_w > MAX_BURST_BEATS_W) begin
                                burst_beats_r <= MAX_BURST_BEATS_W;
                                axi_awlen <= MAX_BURST_LEN_W;
                                words_in_burst_r <= MAX_BURST_WORDS_W;
                            end else begin
                                burst_beats_r <= total_beats_w;
                                axi_awlen <= burst_len_from_beats(total_beats_w);
                                words_in_burst_r <= words_remaining_r;
                            end
                            beats_sent_r <= 16'd0;
                            axi_awvalid <= 1'b1;
                        end
                    end
                end
                default: begin
                end
            endcase
        end
    end

    function [127:0] beat_buf_r_next;
        input [127:0] curr;
        input [31:0]  word;
        input [2:0]   idx;
        begin
            beat_buf_r_next = curr;
            beat_buf_r_next[(idx * 32) +: 32] = word;
        end
    endfunction

    function [15:0] beat_strb_next;
        input [15:0] curr;
        input [2:0]  idx;
        begin
            beat_strb_next = curr;
            beat_strb_next[(idx * 4) +: 4] = 4'hF;
        end
    endfunction

endmodule
