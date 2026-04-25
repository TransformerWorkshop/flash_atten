module FA_Q_BUF_REAL (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          word_write_valid,
    input  wire [3:0]    word_write_row,
    input  wire [4:0]    word_write_lane,
    input  wire [31:0]   word_write_data,
    input  wire          qk_rd_en,
    input  wire [4:0]    qk_rd_addr,
    output reg           qk_rd_valid,
    output wire [511:0]  qk_rd_data,
    output wire [16383:0] tile_flat
);

    reg [31:0] shadow_words_r [0:511];
    wire [511:0] bank_rd_data_w;
    reg [511:0] bank_wr_data_r;
    reg [15:0]  bank_wr_mask_r;
    integer wi;
    integer bi;

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate

    PT_MEM_BANK #(
        .DATA_WIDTH(32),
        .LANES(16),
        .DEPTH(32)
    ) u_qk_bank (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(word_write_valid),
        .wr_buf(1'b0),
        .wr_mask(bank_wr_mask_r),
        .wr_addr(word_write_lane),
        .wr_data(bank_wr_data_r),
        .rd_en(qk_rd_en),
        .rd_buf(1'b0),
        .rd_addr(qk_rd_addr),
        .rd_data(bank_rd_data_w)
    );

    always @(*) begin
        bank_wr_data_r = 512'd0;
        bank_wr_mask_r = 16'd0;
        if (word_write_valid) begin
            bank_wr_mask_r[word_write_row] = 1'b1;
            bank_wr_data_r[(word_write_row * 32) +: 32] = word_write_data;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            qk_rd_valid <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            qk_rd_valid <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else begin
            qk_rd_valid <= qk_rd_en;
            if (word_write_valid) begin
                shadow_words_r[(word_write_row * 32) + word_write_lane] <= word_write_data;
            end
        end
    end

endmodule

module FA_K_BUF_REAL (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          word_write_valid,
    input  wire [3:0]    word_write_row,
    input  wire [4:0]    word_write_lane,
    input  wire [31:0]   word_write_data,
    input  wire          qk_rd_en,
    input  wire [4:0]    qk_rd_addr,
    output reg           qk_rd_valid,
    output wire [511:0]  qk_rd_data,
    output wire [16383:0] tile_flat
);

    reg [31:0] shadow_words_r [0:511];
    wire [511:0] bank_rd_data_w;
    reg [511:0] bank_wr_data_r;
    reg [15:0]  bank_wr_mask_r;
    integer wi;

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate

    PT_MEM_BANK #(
        .DATA_WIDTH(32),
        .LANES(16),
        .DEPTH(32)
    ) u_qk_bank (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(word_write_valid),
        .wr_buf(1'b0),
        .wr_mask(bank_wr_mask_r),
        .wr_addr(word_write_lane),
        .wr_data(bank_wr_data_r),
        .rd_en(qk_rd_en),
        .rd_buf(1'b0),
        .rd_addr(qk_rd_addr),
        .rd_data(bank_rd_data_w)
    );

    always @(*) begin
        bank_wr_data_r = 512'd0;
        bank_wr_mask_r = 16'd0;
        if (word_write_valid) begin
            bank_wr_mask_r[word_write_row] = 1'b1;
            bank_wr_data_r[(word_write_row * 32) +: 32] = word_write_data;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            qk_rd_valid <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            qk_rd_valid <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else begin
            qk_rd_valid <= qk_rd_en;
            if (word_write_valid) begin
                shadow_words_r[(word_write_row * 32) + word_write_lane] <= word_write_data;
            end
        end
    end

endmodule

module FA_V_BUF_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           word_write_valid,
    input  wire [3:0]     word_write_row,
    input  wire [4:0]     word_write_lane,
    input  wire [31:0]    word_write_data,
    output wire [16383:0] tile_flat
);

    reg [31:0] shadow_words_r [0:511];
    integer wi;

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
        end else if (word_write_valid) begin
            shadow_words_r[(word_write_row * 32) + word_write_lane] <= word_write_data;
        end
    end

endmodule

module FA_V_BUF_PV_REAL (
    input  wire            clk,
    input  wire            rstn,
    input  wire            clear,
    input  wire            wr_valid,
    input  wire [4:0]      wr_addr,
    input  wire            wr_lane0_valid,
    input  wire [3:0]      wr_lane0_idx,
    input  wire            wr_lane0_hi,
    input  wire [15:0]     wr_lane0_data,
    input  wire            wr_lane1_valid,
    input  wire [3:0]      wr_lane1_idx,
    input  wire            wr_lane1_hi,
    input  wire [15:0]     wr_lane1_data,
    input  wire            rd_en,
    input  wire [4:0]      rd_addr,
    output reg             rd_valid,
    output wire [511:0]    rd_data,
    output wire [16383:0]  layout_flat
);

    reg [31:0] shadow_words_r [0:31][0:15];
    reg [511:0] bank_wr_data_r;
    reg [15:0]  bank_wr_mask_r;
    integer ai;
    integer li;
    reg [31:0] lane_word0_r;
    reg [31:0] lane_word1_r;

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

    PT_MEM_BANK #(
        .DATA_WIDTH(32),
        .LANES(16),
        .DEPTH(32)
    ) u_bank (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(wr_valid),
        .wr_buf(1'b0),
        .wr_mask(bank_wr_mask_r),
        .wr_addr(wr_addr),
        .wr_data(bank_wr_data_r),
        .rd_en(rd_en),
        .rd_buf(1'b0),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    always @(*) begin
        bank_wr_data_r = 512'd0;
        bank_wr_mask_r = 16'd0;
        lane_word0_r = 32'd0;
        lane_word1_r = 32'd0;
        if (wr_lane0_valid) begin
            lane_word0_r = shadow_words_r[wr_addr][wr_lane0_idx];
            if (wr_lane0_hi) begin
                lane_word0_r[31:16] = wr_lane0_data;
            end else begin
                lane_word0_r[15:0] = wr_lane0_data;
            end
            bank_wr_mask_r[wr_lane0_idx] = 1'b1;
            bank_wr_data_r[(wr_lane0_idx * 32) +: 32] = lane_word0_r;
        end
        if (wr_lane1_valid) begin
            lane_word1_r = shadow_words_r[wr_addr][wr_lane1_idx];
            if (wr_lane1_valid && wr_lane0_valid && (wr_lane1_idx == wr_lane0_idx)) begin
                lane_word1_r = lane_word0_r;
            end
            if (wr_lane1_hi) begin
                lane_word1_r[31:16] = wr_lane1_data;
            end else begin
                lane_word1_r[15:0] = wr_lane1_data;
            end
            bank_wr_mask_r[wr_lane1_idx] = 1'b1;
            bank_wr_data_r[(wr_lane1_idx * 32) +: 32] = lane_word1_r;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_valid <= 1'b0;
            for (ai = 0; ai < 32; ai = ai + 1) begin
                for (li = 0; li < 16; li = li + 1) begin
                    shadow_words_r[ai][li] <= 32'd0;
                end
            end
        end else if (clear) begin
            rd_valid <= 1'b0;
            for (ai = 0; ai < 32; ai = ai + 1) begin
                for (li = 0; li < 16; li = li + 1) begin
                    shadow_words_r[ai][li] <= 32'd0;
                end
            end
        end else begin
            rd_valid <= rd_en;
            if (wr_valid) begin
                if (wr_lane0_valid) begin
                    shadow_words_r[wr_addr][wr_lane0_idx] <= lane_word0_r;
                end
                if (wr_lane1_valid) begin
                    shadow_words_r[wr_addr][wr_lane1_idx] <= lane_word1_r;
                end
            end
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
    output wire [4095:0]  tile_flat
);

    reg [1:0] state_r;
    reg [2:0] load_addr_r;
    reg [4095:0] load_data_r;
    reg [31:0] shadow_words_r [0:127];
    reg [511:0] bank_wr_data_r;
    integer wi;
    integer ri;

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_LOAD = 2'd1;

    assign load_ready = (state_r == ST_IDLE);

    generate
        genvar gi;
        for (gi = 0; gi < 128; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate

    PT_MEM_BANK #(
        .DATA_WIDTH(32),
        .LANES(16),
        .DEPTH(8)
    ) u_bank (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(state_r == ST_LOAD),
        .wr_buf(1'b0),
        .wr_mask(16'hFFFF),
        .wr_addr(load_addr_r),
        .wr_data(bank_wr_data_r),
        .rd_en(pv_rd_en),
        .rd_buf(1'b0),
        .rd_addr(pv_rd_addr),
        .rd_data(pv_rd_data)
    );

    always @(*) begin
        bank_wr_data_r = 512'd0;
        for (ri = 0; ri < 16; ri = ri + 1) begin
            bank_wr_data_r[(ri * 32) +: 32] = load_data_r[((ri * 8) + load_addr_r) * 32 +: 32];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            load_addr_r <= 3'd0;
            load_data_r <= 4096'd0;
            load_done_pulse <= 1'b0;
            pv_rd_valid <= 1'b0;
            for (wi = 0; wi < 128; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            state_r <= ST_IDLE;
            load_addr_r <= 3'd0;
            load_data_r <= 4096'd0;
            load_done_pulse <= 1'b0;
            pv_rd_valid <= 1'b0;
            for (wi = 0; wi < 128; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else begin
            load_done_pulse <= 1'b0;
            pv_rd_valid <= pv_rd_en;
            if ((state_r == ST_IDLE) && load_valid) begin
                load_data_r <= tile_load_data;
                for (wi = 0; wi < 128; wi = wi + 1) begin
                    shadow_words_r[wi] <= tile_load_data[(wi * 32) +: 32];
                end
                load_addr_r <= 3'd0;
                state_r <= ST_LOAD;
            end else if (state_r == ST_LOAD) begin
                if (load_addr_r == 3'd7) begin
                    state_r <= ST_IDLE;
                    load_done_pulse <= 1'b1;
                end else begin
                    load_addr_r <= load_addr_r + 1'b1;
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
    output wire [16383:0]  tile_flat
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_CLEAR = 2'd1;
    localparam [1:0] ST_LOAD = 2'd2;

    reg [1:0] state_r;
    reg [3:0] row_idx_r;
    reg [16383:0] load_data_r;
    reg [31:0] shadow_words_r [0:511];
    reg [1023:0] mem_wr_data_r;
    reg [3:0]    mem_wr_addr_r;
    reg [31:0]   mem_wr_mask_r;
    reg          mem_wr_en_r;
    integer wi;
    integer li;

    assign clear_req_ready = (state_r == ST_IDLE);
    assign load_ready = (state_r == ST_IDLE);

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_words_r[gi];
        end
    endgenerate

    PT_M_MEM #(
        .DATA_WIDTH(32),
        .B_LANES(32),
        .DEPTH(16),
        .M_PHYSICAL_COPIES(2)
    ) u_mem (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(mem_wr_en_r),
        .wr_buf(1'b0),
        .wr_mask(mem_wr_mask_r),
        .wr_addr(mem_wr_addr_r),
        .wr_data(mem_wr_data_r),
        .rd_b_en(row_rd_en),
        .rd_b_buf(1'b0),
        .rd_b_addr(row_rd_addr),
        .rd_b_data(row_rd_data),
        .rd_exp_en(exp_rd_en),
        .rd_exp_buf(1'b0),
        .rd_exp_addr(exp_rd_addr),
        .rd_exp_data(exp_rd_data)
    );

    always @(*) begin
        mem_wr_en_r = 1'b0;
        mem_wr_addr_r = 4'd0;
        mem_wr_data_r = 1024'd0;
        mem_wr_mask_r = 32'd0;
        if (state_r == ST_CLEAR) begin
            mem_wr_en_r = 1'b1;
            mem_wr_addr_r = row_idx_r;
            mem_wr_data_r = 1024'd0;
            mem_wr_mask_r = 32'hFFFF_FFFF;
        end else if (state_r == ST_LOAD) begin
            mem_wr_en_r = 1'b1;
            mem_wr_addr_r = row_idx_r;
            mem_wr_mask_r = 32'hFFFF_FFFF;
            mem_wr_data_r = 1024'd0;
            for (li = 0; li < 32; li = li + 1) begin
                mem_wr_data_r[(li * 32) +: 32] = load_data_r[((row_idx_r * 32) + li) * 32 +: 32];
            end
        end else if (row_wr_en) begin
            mem_wr_en_r = 1'b1;
            mem_wr_addr_r = row_wr_addr;
            mem_wr_data_r = row_wr_data;
            mem_wr_mask_r = 32'hFFFF_FFFF;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
            load_data_r <= 16384'd0;
            clear_done_pulse <= 1'b0;
            load_done_pulse <= 1'b0;
            row_rd_valid <= 1'b0;
            exp_rd_valid <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
            load_data_r <= 16384'd0;
            clear_done_pulse <= 1'b0;
            load_done_pulse <= 1'b0;
            row_rd_valid <= 1'b0;
            exp_rd_valid <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                shadow_words_r[wi] <= 32'd0;
            end
        end else begin
            clear_done_pulse <= 1'b0;
            load_done_pulse <= 1'b0;
            row_rd_valid <= row_rd_en;
            exp_rd_valid <= exp_rd_en;
            if (row_wr_en && (state_r == ST_IDLE)) begin
                for (wi = 0; wi < 32; wi = wi + 1) begin
                    shadow_words_r[(row_wr_addr * 32) + wi] <= row_wr_data[(wi * 32) +: 32];
                end
            end
            case (state_r)
                ST_IDLE: begin
                    if (clear_req_valid) begin
                        row_idx_r <= 4'd0;
                        for (wi = 0; wi < 512; wi = wi + 1) begin
                            shadow_words_r[wi] <= 32'd0;
                        end
                        state_r <= ST_CLEAR;
                    end else if (load_valid) begin
                        load_data_r <= tile_load_data;
                        row_idx_r <= 4'd0;
                        for (wi = 0; wi < 512; wi = wi + 1) begin
                            shadow_words_r[wi] <= tile_load_data[(wi * 32) +: 32];
                        end
                        state_r <= ST_LOAD;
                    end
                end
                ST_CLEAR: begin
                    if (row_idx_r == 4'd15) begin
                        state_r <= ST_IDLE;
                        clear_done_pulse <= 1'b1;
                    end else begin
                        row_idx_r <= row_idx_r + 1'b1;
                    end
                end
                ST_LOAD: begin
                    if (row_idx_r == 4'd15) begin
                        state_r <= ST_IDLE;
                        load_done_pulse <= 1'b1;
                    end else begin
                        row_idx_r <= row_idx_r + 1'b1;
                    end
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
