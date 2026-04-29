module FA_BANKED_TILE_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           beat_write_valid,
    input  wire [3:0]     beat_write_row_idx,
    input  wire [2:0]     beat_write_local_addr,
    input  wire [3:0]     beat_write_word_mask,
    input  wire [127:0]   beat_write_data,
    input  wire           rd_en,
    input  wire [4:0]     rd_addr,
    output reg            rd_valid,
    output reg  [511:0]   rd_data,
    //debug
    output wire [16383:0] tile_flat
);

    wire [511:0] bank_rd_data_w [0:3];
    reg [511:0] bank_wr_data_r [0:3];
    reg [511:0] bank_wr_mask_r [0:3];
    reg [1:0]   rd_bank_sel_r;
    integer bank_i;

`ifndef SYNTHESIS
    reg [31:0] shadow_words_r [0:511];
    integer wi;
    integer bi;

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate
`else
    wire unused_tile_flat_zero_w = (clk & 1'b0)
                                 | (rstn & 1'b0)
                                 | (clear & 1'b0)
                                 | (beat_write_valid & 1'b0)
                                 | ((|beat_write_row_idx) & 1'b0)
                                 | ((|beat_write_local_addr) & 1'b0)
                                 | ((|beat_write_word_mask) & 1'b0)
                                 | ((|beat_write_data) & 1'b0);
    assign tile_flat = {16384{unused_tile_flat_zero_w}};
`endif

    generate
        genvar gb;
        for (gb = 0; gb < 4; gb = gb + 1) begin : gen_bank
            FA_MASKED_ROWBUF_REAL #(
                .ROW_WIDTH(512),
                .DEPTH(8)
            ) u_bank (
                .clk(clk),
                .wr_en(beat_write_valid && beat_write_word_mask[gb]),
                .wr_addr(beat_write_local_addr),
                .wr_data(bank_wr_data_r[gb]),
                .wr_mask(bank_wr_mask_r[gb]),
                .rd_en(rd_en && (rd_addr[1:0] == gb[1:0])),
                .rd_addr(rd_addr[4:2]),
                .rd_data(bank_rd_data_w[gb])
            );
        end
    endgenerate

    always @(*) begin
        for (bank_i = 0; bank_i < 4; bank_i = bank_i + 1) begin
            bank_wr_data_r[bank_i] = 512'd0;
            bank_wr_mask_r[bank_i] = 512'd0;
            if (beat_write_valid && beat_write_word_mask[bank_i]) begin
                bank_wr_mask_r[bank_i][(beat_write_row_idx * 32) +: 32] = 32'hFFFF_FFFF;
                bank_wr_data_r[bank_i][(beat_write_row_idx * 32) +: 32] = beat_write_data[(bank_i * 32) +: 32];
            end
        end
        case (rd_bank_sel_r)
            2'd0: rd_data = bank_rd_data_w[0];
            2'd1: rd_data = bank_rd_data_w[1];
            2'd2: rd_data = bank_rd_data_w[2];
            default: rd_data = bank_rd_data_w[3];
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_valid <= 1'b0;
            rd_bank_sel_r <= 2'd0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
`endif
        end else if (clear) begin
            rd_valid <= 1'b0;
            rd_bank_sel_r <= 2'd0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
`endif
        end else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                rd_bank_sel_r <= rd_addr[1:0];
            end
`ifndef SYNTHESIS
            if (beat_write_valid) begin
                for (bi = 0; bi < 4; bi = bi + 1) begin
                    if (beat_write_word_mask[bi]) begin
                        shadow_words_r[(beat_write_row_idx * 32) + (beat_write_local_addr * 4) + bi] <= beat_write_data[(bi * 32) +: 32];
                    end
                end
            end
`endif
        end
    end

endmodule

module FA_REG_TILE_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           beat_write_valid,
    input  wire [3:0]     beat_write_row_idx,
    input  wire [2:0]     beat_write_local_addr,
    input  wire [3:0]     beat_write_word_mask,
    input  wire [127:0]   beat_write_data,
    input  wire           rd_en,
    input  wire [4:0]     rd_addr,
    output reg            rd_valid,
    output reg  [511:0]   rd_data,
    //debug
    output wire [16383:0] tile_flat
);

    reg [31:0] word_mem_r [0:511];
    integer bi;
    integer row_i;
`ifndef SYNTHESIS
    integer wi;

    initial begin
        for (wi = 0; wi < 512; wi = wi + 1) begin
            word_mem_r[wi] = 32'd0;
        end
    end

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = word_mem_r[gi];
        end
    endgenerate
`else
    wire unused_tile_flat_zero_w = (clk & 1'b0)
                                 | (rstn & 1'b0)
                                 | (clear & 1'b0)
                                 | (beat_write_valid & 1'b0)
                                 | ((|beat_write_row_idx) & 1'b0)
                                 | ((|beat_write_local_addr) & 1'b0)
                                 | ((|beat_write_word_mask) & 1'b0)
                                 | ((|beat_write_data) & 1'b0);
    assign tile_flat = {16384{unused_tile_flat_zero_w}};
`endif

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_valid <= 1'b0;
            rd_data <= 512'd0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 512; wi = wi + 1) begin
                word_mem_r[wi] <= 32'd0;
            end
`endif
        end else if (clear) begin
            rd_valid <= 1'b0;
            rd_data <= 512'd0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 512; wi = wi + 1) begin
                word_mem_r[wi] <= 32'd0;
            end
`endif
        end else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
                    rd_data[(row_i * 32) +: 32] <= word_mem_r[(row_i * 32) + rd_addr];
                end
            end
            if (beat_write_valid) begin
                for (bi = 0; bi < 4; bi = bi + 1) begin
                    if (beat_write_word_mask[bi]) begin
                        word_mem_r[(beat_write_row_idx * 32) + (beat_write_local_addr * 4) + bi] <=
                            beat_write_data[(bi * 32) +: 32];
                    end
                end
            end
        end
    end

endmodule

module FA_Q_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           beat_write_valid,
    input  wire [3:0]     beat_write_row_idx,
    input  wire [2:0]     beat_write_local_addr,
    input  wire [3:0]     beat_write_word_mask,
    input  wire [127:0]   beat_write_data,
    input  wire           qk_rd_en,
    input  wire [4:0]     qk_rd_addr,
    output wire           qk_rd_valid,
    output wire [511:0]   qk_rd_data,
    //debug
    output wire [16383:0] tile_flat
);

    FA_REG_TILE_BUF_REAL u_reg_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .beat_write_valid(beat_write_valid),
        .beat_write_row_idx(beat_write_row_idx),
        .beat_write_local_addr(beat_write_local_addr),
        .beat_write_word_mask(beat_write_word_mask),
        .beat_write_data(beat_write_data),
        .rd_en(qk_rd_en),
        .rd_addr(qk_rd_addr),
        .rd_valid(qk_rd_valid),
        .rd_data(qk_rd_data),
        //debug
        .tile_flat(tile_flat)
    );

endmodule

module FA_K_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           beat_write_valid,
    input  wire [3:0]     beat_write_row_idx,
    input  wire [2:0]     beat_write_local_addr,
    input  wire [3:0]     beat_write_word_mask,
    input  wire [127:0]   beat_write_data,
    input  wire           qk_rd_en,
    input  wire [4:0]     qk_rd_addr,
    output wire           qk_rd_valid,
    output wire [511:0]   qk_rd_data,
    //debug
    output wire [16383:0] tile_flat
);

    FA_REG_TILE_BUF_REAL u_reg_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .beat_write_valid(beat_write_valid),
        .beat_write_row_idx(beat_write_row_idx),
        .beat_write_local_addr(beat_write_local_addr),
        .beat_write_word_mask(beat_write_word_mask),
        .beat_write_data(beat_write_data),
        .rd_en(qk_rd_en),
        .rd_addr(qk_rd_addr),
        .rd_valid(qk_rd_valid),
        .rd_data(qk_rd_data),
        //debug
        .tile_flat(tile_flat)
    );

endmodule

module FA_V_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           beat_write_valid,
    input  wire [3:0]     beat_write_row_idx,
    input  wire [2:0]     beat_write_local_addr,
    input  wire [3:0]     beat_write_word_mask,
    input  wire [127:0]   beat_write_data,
    //debug
    output wire [16383:0] tile_flat
);

`ifndef SYNTHESIS
    // The real datapath consumes V through FA_V_BUF_PV_REAL. Keep only a
    // simulation-visible shadow here so directed tests can still inspect
    // write mapping without paying for a redundant synthesized SRAM.
    reg [31:0] shadow_words_r [0:511];
    integer wi;
    integer bi;

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else if (beat_write_valid) begin
            for (bi = 0; bi < 4; bi = bi + 1) begin
                if (beat_write_word_mask[bi]) begin
                    shadow_words_r[(beat_write_row_idx * 32) + (beat_write_local_addr * 4) + bi] <= beat_write_data[(bi * 32) +: 32];
                end
            end
        end
    end
`else
    wire unused_v_buf_zero_w = (clk & 1'b0)
                             | (rstn & 1'b0)
                             | (clear & 1'b0)
                             | (beat_write_valid & 1'b0)
                             | ((|beat_write_row_idx) & 1'b0)
                             | ((|beat_write_local_addr) & 1'b0)
                             | ((|beat_write_word_mask) & 1'b0)
                             | ((|beat_write_data) & 1'b0);
    assign tile_flat = {16384{unused_v_buf_zero_w}};
`endif

endmodule

module FA_V_BUF_PV_REAL (
    input  wire            clk,
    input  wire            rstn,
    input  wire            clear,
    input  wire            src_wr_valid,
    input  wire [8:0]      src_word_idx_base,
    input  wire [3:0]      src_word_mask,
    input  wire [127:0]    src_data,
    input  wire            rd_en,
    input  wire [4:0]      rd_addr,
    output reg             rd_valid,
    output wire [511:0]    rd_data,
    //debug
    output wire [16383:0]  layout_flat
);

    reg [511:0] bank_wr_data_r;
    reg [511:0] bank_wr_mask_r;
    wire [4:0]  src_wr_addr_w = {src_word_idx_base[4:3], src_word_idx_base[8:6]};
`ifndef SYNTHESIS
    reg [31:0] shadow_words_r [0:31][0:15];
    integer ai;
`endif
    integer li;
    integer src_i;
    reg [8:0] src_word_idx_r;
    reg [31:0] src_word_r;
    reg [3:0] lane_lo_idx_r;
    reg [3:0] lane_hi_idx_r;
    reg       hi_half_r;

`ifndef SYNTHESIS
    generate
        genvar ga;
        genvar gl;
        for (ga = 0; ga < 32; ga = ga + 1) begin : gen_addr
            for (gl = 0; gl < 16; gl = gl + 1) begin : gen_lane
                localparam integer FLAT_IDX = (ga * 16) + gl;
                assign layout_flat[(FLAT_IDX * 32) +: 32] = shadow_words_r[ga][gl];
            end
        end
    endgenerate
`else
    wire unused_layout_zero_w = (clk & 1'b0)
                              | (rstn & 1'b0)
                              | (clear & 1'b0)
                              | (src_wr_valid & 1'b0)
                              | ((|src_word_idx_base) & 1'b0)
                              | ((|src_word_mask) & 1'b0)
                              | ((|src_data) & 1'b0);
    assign layout_flat = {16384{unused_layout_zero_w}};
`endif

    FA_MASKED_ROWBUF_REG_REAL #(
        .ROW_WIDTH(512),
        .DEPTH(32),
        .WRITE_GRANULARITY(16)
    ) u_bank (
        .clk(clk),
        .wr_en(src_wr_valid),
        .wr_addr(src_wr_addr_w),
        .wr_data(bank_wr_data_r),
        .wr_mask(bank_wr_mask_r),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    always @(*) begin
        bank_wr_data_r = 512'd0;
        bank_wr_mask_r = 512'd0;
        src_word_idx_r = 9'd0;
        src_word_r = 32'd0;
        lane_lo_idx_r = 4'd0;
        lane_hi_idx_r = 4'd0;
        hi_half_r = 1'b0;
        for (src_i = 0; src_i < 4; src_i = src_i + 1) begin
            if (src_word_mask[src_i]) begin
                src_word_idx_r = src_word_idx_base + src_i;
                src_word_r = src_data[(src_i * 32) +: 32];
                lane_lo_idx_r = {src_word_idx_r[2:0], 1'b0};
                lane_hi_idx_r = {src_word_idx_r[2:0], 1'b1};
                hi_half_r = src_word_idx_r[5];
                if (hi_half_r) begin
                    bank_wr_data_r[(lane_lo_idx_r * 32) + 16 +: 16] = src_word_r[15:0];
                    bank_wr_data_r[(lane_hi_idx_r * 32) + 16 +: 16] = src_word_r[31:16];
                    bank_wr_mask_r[(lane_lo_idx_r * 32) + 16 +: 16] = 16'hFFFF;
                    bank_wr_mask_r[(lane_hi_idx_r * 32) + 16 +: 16] = 16'hFFFF;
                end else begin
                    bank_wr_data_r[(lane_lo_idx_r * 32) +: 16] = src_word_r[15:0];
                    bank_wr_data_r[(lane_hi_idx_r * 32) +: 16] = src_word_r[31:16];
                    bank_wr_mask_r[(lane_lo_idx_r * 32) +: 16] = 16'hFFFF;
                    bank_wr_mask_r[(lane_hi_idx_r * 32) +: 16] = 16'hFFFF;
                end
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (ai = 0; ai < 32; ai = ai + 1) begin
                for (li = 0; li < 16; li = li + 1) begin
                    shadow_words_r[ai][li] <= 32'd0;
                end
            end
`endif
        end else if (clear) begin
            rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (ai = 0; ai < 32; ai = ai + 1) begin
                for (li = 0; li < 16; li = li + 1) begin
                    shadow_words_r[ai][li] <= 32'd0;
                end
            end
`endif
        end else begin
            rd_valid <= rd_en;
`ifndef SYNTHESIS
            if (src_wr_valid) begin
                for (li = 0; li < 16; li = li + 1) begin
                    if (|bank_wr_mask_r[(li * 32) +: 32]) begin
                        shadow_words_r[src_wr_addr_w][li] <=
                            (shadow_words_r[src_wr_addr_w][li] & ~bank_wr_mask_r[(li * 32) +: 32])
                            | (bank_wr_data_r[(li * 32) +: 32] & bank_wr_mask_r[(li * 32) +: 32]);
                    end
                end
            end
`endif
        end
    end

endmodule

module FA_P_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           load_valid,
    output wire           load_ready,
    input  wire [4095:0]  tile_load_data,
    output reg            load_done_pulse,
    input  wire           pv_rd_en,
    input  wire [2:0]     pv_rd_addr,
    output reg            pv_rd_valid,
    output wire [511:0]   pv_rd_data,
    //debug
    output wire [4095:0]  tile_flat
);

    reg [1:0] state_r;
    reg [1:0] state_n;
    reg [2:0] load_addr_r;
    reg [2:0] load_addr_n;
    reg [4095:0] load_data_r;
    reg [511:0] bank_wr_data_r;
    reg [511:0] bank_wr_mask_r;
    integer ri;
`ifndef SYNTHESIS
    reg [31:0] shadow_words_r [0:127];
    integer wi;
`endif

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_LOAD = 2'd1;

    assign load_ready = (state_r == ST_IDLE);

    always @(*) begin
        state_n = state_r;
        load_addr_n = load_addr_r;
        case (state_r)
            ST_IDLE: begin
                if (load_valid) begin
                    state_n = ST_LOAD;
                    load_addr_n = 3'd0;
                end
            end
            ST_LOAD: begin
                if (load_addr_r == 3'd7) begin
                    state_n = ST_IDLE;
                end else begin
                    load_addr_n = load_addr_r + 1'b1;
                end
            end
            default: begin
                state_n = ST_IDLE;
                load_addr_n = 3'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            load_addr_r <= 3'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            load_addr_r <= 3'd0;
        end else begin
            state_r <= state_n;
            load_addr_r <= load_addr_n;
        end
    end

`ifndef SYNTHESIS
    generate
        genvar gi;
        for (gi = 0; gi < 128; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate
`else
    wire unused_p_tile_flat_zero_w = (clk & 1'b0)
                                   | (rstn & 1'b0)
                                   | (clear & 1'b0)
                                   | (load_valid & 1'b0)
                                   | ((|tile_load_data) & 1'b0)
                                   | (pv_rd_en & 1'b0)
                                   | ((|pv_rd_addr) & 1'b0);
    assign tile_flat = {4096{unused_p_tile_flat_zero_w}};
`endif

    FA_MASKED_ROWBUF_REAL #(
        .ROW_WIDTH(512),
        .DEPTH(8)
    ) u_bank (
        .clk(clk),
        .wr_en(state_r == ST_LOAD),
        .wr_addr(load_addr_r),
        .wr_data(bank_wr_data_r),
        .wr_mask(bank_wr_mask_r),
        .rd_en(pv_rd_en),
        .rd_addr(pv_rd_addr),
        .rd_data(pv_rd_data)
    );

    always @(*) begin
        bank_wr_data_r = 512'd0;
        bank_wr_mask_r = (state_r == ST_LOAD) ? {512{1'b1}} : 512'd0;
        for (ri = 0; ri < 16; ri = ri + 1) begin
            bank_wr_data_r[(ri * 32) +: 32] = load_data_r[((ri * 8) + load_addr_r) * 32 +: 32];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            load_data_r <= 4096'd0;
            load_done_pulse <= 1'b0;
            pv_rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 128; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
`endif
        end else if (clear) begin
            load_data_r <= 4096'd0;
            load_done_pulse <= 1'b0;
            pv_rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 128; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
`endif
        end else begin
                load_done_pulse <= 1'b0;
                pv_rd_valid <= pv_rd_en;
                if ((state_r == ST_IDLE) && load_valid) begin
                    load_data_r <= tile_load_data;
`ifndef SYNTHESIS
                    for (wi = 0; wi < 128; wi = wi + 1) begin
                        shadow_words_r[wi] <= tile_load_data[(wi * 32) +: 32];
                    end
`endif
                end else if (state_r == ST_LOAD) begin
                    if (load_addr_r == 3'd7) begin
                        load_done_pulse <= 1'b1;
                    end
                end
            end
        end

endmodule

module FA_OACC_BUF_REAL (
    input  wire            clk,
    input  wire            rstn,
    input  wire            clear,
    input  wire            clear_req_valid,
    output wire            clear_req_ready,
    output reg             clear_done_pulse,
    input  wire            load_valid,
    output wire            load_ready,
    input  wire [16383:0]  tile_load_data,
    output reg             load_done_pulse,
    input  wire            row_rd_en,
    input  wire [3:0]      row_rd_addr,
    output reg             row_rd_valid,
    output wire [1023:0]   row_rd_data,
    input  wire            row_wr_en,
    input  wire [3:0]      row_wr_addr,
    input  wire [1023:0]   row_wr_data,
    input  wire            exp_rd_en,
    input  wire [3:0]      exp_rd_addr,
    output reg             exp_rd_valid,
    output wire [1023:0]   exp_rd_data,
    //debug
    output wire [16383:0]  tile_flat
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_CLEAR = 2'd1;
    localparam [1:0] ST_LOAD = 2'd2;

    reg [1:0] state_r;
    reg [1:0] state_n;
    reg [3:0] row_idx_r;
    reg [3:0] row_idx_n;
    reg [16383:0] load_data_r;
    reg [1023:0] mem_wr_data_r;
    reg [3:0]    mem_wr_addr_r;
    reg [1023:0] mem_wr_mask_r;
    reg          mem_wr_en_r;
    wire         mem_rd_en_w;
    wire [3:0]   mem_rd_addr_w;
    wire [1023:0] mem_rd_data_w;
    wire [1023:0] exp_rd_data_w;
    wire         row_rd_sel_w = row_rd_en;
    wire         exp_rd_sel_w = !row_rd_en && exp_rd_en;
    integer li;
`ifndef SYNTHESIS
    reg [15:0] shadow_q412_words_r [0:1023];
    integer wi;
`endif

    function automatic signed [15:0] q412_to_q88_rn_sat;
        input signed [15:0] value;
        reg signed [31:0] value_ext;
        reg signed [31:0] rounded;
        reg signed [31:0] shifted;
        begin
            value_ext = {{16{value[15]}}, value};
            if (value_ext >= 0) begin
                rounded = value_ext + 32'sd8;
            end else begin
                rounded = value_ext - 32'sd8;
            end
            shifted = rounded >>> 4;
            if (shifted > 32'sd32767) begin
                q412_to_q88_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                q412_to_q88_rn_sat = -16'sh8000;
            end else begin
                q412_to_q88_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function automatic signed [15:0] q88_to_q412_sat;
        input signed [15:0] value;
        reg signed [31:0] shifted;
        begin
            shifted = {{16{value[15]}}, value} <<< 4;
            if (shifted > 32'sd32767) begin
                q88_to_q412_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                q88_to_q412_sat = -16'sh8000;
            end else begin
                q88_to_q412_sat = shifted[15:0];
            end
        end
    endfunction

    function automatic [31:0] pack_q412_pair_to_q88;
        input signed [15:0] lo_q412;
        input signed [15:0] hi_q412;
        reg signed [15:0] lo_q88;
        reg signed [15:0] hi_q88;
        begin
            lo_q88 = q412_to_q88_rn_sat(lo_q412);
            hi_q88 = q412_to_q88_rn_sat(hi_q412);
            pack_q412_pair_to_q88 = {hi_q88, lo_q88};
        end
    endfunction

    assign clear_req_ready = (state_r == ST_IDLE);
    assign load_ready = (state_r == ST_IDLE);

    always @(*) begin
        state_n = state_r;
        row_idx_n = row_idx_r;
        case (state_r)
            ST_IDLE: begin
                if (clear_req_valid) begin
                    state_n = ST_CLEAR;
                    row_idx_n = 4'd0;
                end else if (load_valid) begin
                    state_n = ST_LOAD;
                    row_idx_n = 4'd0;
                end
            end
            ST_CLEAR: begin
                if (row_idx_r == 4'd15) begin
                    state_n = ST_IDLE;
                end else begin
                    row_idx_n = row_idx_r + 1'b1;
                end
            end
            ST_LOAD: begin
                if (row_idx_r == 4'd15) begin
                    state_n = ST_IDLE;
                end else begin
                    row_idx_n = row_idx_r + 1'b1;
                end
            end
            default: begin
                state_n = ST_IDLE;
                row_idx_n = 4'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
        end else begin
            state_r <= state_n;
            row_idx_r <= row_idx_n;
        end
    end

`ifndef SYNTHESIS
    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = pack_q412_pair_to_q88(
                shadow_q412_words_r[gi * 2],
                shadow_q412_words_r[(gi * 2) + 1]
            );
        end
    endgenerate
`else
    wire unused_oacc_tile_flat_zero_w = (clk & 1'b0)
                                      | (rstn & 1'b0)
                                      | (clear & 1'b0)
                                      | (clear_req_valid & 1'b0)
                                      | (load_valid & 1'b0)
                                      | ((|tile_load_data) & 1'b0)
                                      | (row_rd_en & 1'b0)
                                      | ((|row_rd_addr) & 1'b0)
                                      | (row_wr_en & 1'b0)
                                      | ((|row_wr_addr) & 1'b0)
                                      | ((|row_wr_data) & 1'b0)
                                      | (exp_rd_en & 1'b0)
                                      | ((|exp_rd_addr) & 1'b0);
    assign tile_flat = {16384{unused_oacc_tile_flat_zero_w}};
`endif

    assign mem_rd_en_w = row_rd_en || exp_rd_en;
    assign mem_rd_addr_w = row_rd_en ? row_rd_addr : exp_rd_addr;
    assign row_rd_data = mem_rd_data_w;
    assign exp_rd_data = exp_rd_data_w;

    generate
        genvar go;
        for (go = 0; go < 32; go = go + 1) begin : gen_exp_pack
            assign exp_rd_data_w[(go * 32) +: 32] = pack_q412_pair_to_q88(
                mem_rd_data_w[((go * 2) * 16) +: 16],
                mem_rd_data_w[(((go * 2) + 1) * 16) +: 16]
            );
        end
    endgenerate

// synthesis translate_off
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (row_rd_en && exp_rd_en) begin
            $fatal(1, "FA_OACC_BUF_REAL does not support simultaneous row/export reads on the shared SRAM");
        end
    end
`endif
// synthesis translate_on

    FA_MASKED_ROWBUF_REG_REAL #(
        .ROW_WIDTH(1024),
        .DEPTH(16),
        .WRITE_GRANULARITY(16)
    ) u_mem (
        .clk(clk),
        .wr_en(mem_wr_en_r),
        .wr_addr(mem_wr_addr_r),
        .wr_data(mem_wr_data_r),
        .wr_mask(mem_wr_mask_r),
        .rd_en(mem_rd_en_w),
        .rd_addr(mem_rd_addr_w),
        .rd_data(mem_rd_data_w)
    );

    always @(*) begin
        mem_wr_en_r = 1'b0;
        mem_wr_addr_r = 4'd0;
        mem_wr_data_r = 1024'd0;
        mem_wr_mask_r = 1024'd0;
        if (state_r == ST_CLEAR) begin
            mem_wr_en_r = 1'b1;
            mem_wr_addr_r = row_idx_r;
            mem_wr_data_r = 1024'd0;
            mem_wr_mask_r = {1024{1'b1}};
        end else if (state_r == ST_LOAD) begin
            mem_wr_en_r = 1'b1;
            mem_wr_addr_r = row_idx_r;
            mem_wr_mask_r = {1024{1'b1}};
            mem_wr_data_r = 1024'd0;
            for (li = 0; li < 64; li = li + 1) begin
                mem_wr_data_r[(li * 16) +: 16] = q88_to_q412_sat(
                    load_data_r[(((row_idx_r * 32) + (li >> 1)) * 32) + ((li & 1) * 16) +: 16]
                );
            end
        end else if (row_wr_en) begin
            mem_wr_en_r = 1'b1;
            mem_wr_addr_r = row_wr_addr;
            mem_wr_data_r = row_wr_data;
            mem_wr_mask_r = {1024{1'b1}};
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            load_data_r <= 16384'd0;
            clear_done_pulse <= 1'b0;
            load_done_pulse <= 1'b0;
            row_rd_valid <= 1'b0;
            exp_rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 1024; wi = wi + 1) begin
                shadow_q412_words_r[wi] <= 16'd0;
            end
`endif
        end else if (clear) begin
            load_data_r <= 16384'd0;
            clear_done_pulse <= 1'b0;
            load_done_pulse <= 1'b0;
            row_rd_valid <= 1'b0;
            exp_rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 1024; wi = wi + 1) begin
                shadow_q412_words_r[wi] <= 16'd0;
            end
`endif
        end else begin
            clear_done_pulse <= 1'b0;
            load_done_pulse <= 1'b0;
            row_rd_valid <= row_rd_sel_w;
            exp_rd_valid <= exp_rd_sel_w;
`ifndef SYNTHESIS
                if (row_wr_en && (state_r == ST_IDLE)) begin
                    for (wi = 0; wi < 64; wi = wi + 1) begin
                        shadow_q412_words_r[(row_wr_addr * 64) + wi] <= row_wr_data[(wi * 16) +: 16];
                    end
                end
`endif
                case (state_r)
                    ST_IDLE: begin
                        if (clear_req_valid) begin
`ifndef SYNTHESIS
                            for (wi = 0; wi < 1024; wi = wi + 1) begin
                                shadow_q412_words_r[wi] <= 16'd0;
                            end
`endif
                        end else if (load_valid) begin
                            load_data_r <= tile_load_data;
`ifndef SYNTHESIS
                            for (wi = 0; wi < 1024; wi = wi + 1) begin
                                shadow_q412_words_r[wi] <= q88_to_q412_sat(
                                    tile_load_data[((wi >> 1) * 32) + ((wi & 1) * 16) +: 16]
                                );
                            end
`endif
                        end
                    end
                    ST_CLEAR: begin
                        if (row_idx_r == 4'd15) begin
                            clear_done_pulse <= 1'b1;
                        end
                    end
                    ST_LOAD: begin
                        if (row_idx_r == 4'd15) begin
                            load_done_pulse <= 1'b1;
                        end
                    end
                    default: begin
                    end
                endcase
            end
        end

endmodule
