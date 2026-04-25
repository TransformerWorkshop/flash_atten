module FA_OACC_UPDATE_REAL (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           req_valid,
    output wire           req_ready,
    input  wire [511:0]   rescale_vec_flat,
    input  wire [16383:0] partial_o_tile_flat,
    output reg            oacc_row_rd_en,
    output reg  [3:0]     oacc_row_rd_addr,
    input  wire           oacc_row_rd_valid,
    input  wire [1023:0]  oacc_row_rd_data,
    output reg            oacc_row_wr_en,
    output reg  [3:0]     oacc_row_wr_addr,
    output reg  [1023:0]  oacc_row_wr_data,
    output reg            resp_valid,
    input  wire           resp_ready,
    output reg            done_pulse
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_ROW_REQ   = 3'd1;
    localparam [2:0] ST_ROW_WAIT  = 3'd2;
    localparam [2:0] ST_ROW_CALC  = 3'd3;
    localparam [2:0] ST_ROW_WRITE = 3'd4;
    localparam [2:0] ST_DONE      = 3'd5;

    reg [2:0]   state_r;
    reg [3:0]   row_idx_r;
    reg [1023:0] row_old_data_r;
    reg [1023:0] row_new_data_w;
    reg signed [31:0] scale_raw_s;
    integer word_i;
    reg signed [15:0] old_lo_s;
    reg signed [15:0] old_hi_s;
    reg signed [15:0] part_lo_s;
    reg signed [15:0] part_hi_s;
    reg signed [63:0] scaled_lo_q24_24_s;
    reg signed [63:0] scaled_hi_q24_24_s;
    reg signed [31:0] scaled_lo_q8_8_s;
    reg signed [31:0] scaled_hi_q8_8_s;
    reg signed [31:0] new_lo_s;
    reg signed [31:0] new_hi_s;
    reg signed [15:0] clamped_lo_s;
    reg signed [15:0] clamped_hi_s;
    reg [31:0] partial_word_s;

    function automatic signed [15:0] clamp_q88_from_int;
        input signed [31:0] value;
        begin
            if (value > 32'sd32767) begin
                clamp_q88_from_int = 16'sh7FFF;
            end else if (value < -32'sd32768) begin
                clamp_q88_from_int = -16'sh8000;
            end else begin
                clamp_q88_from_int = value[15:0];
            end
        end
    endfunction

    assign req_ready = (state_r == ST_IDLE) && !resp_valid;

    always @(*) begin
        row_new_data_w = 1024'd0;
        scale_raw_s = rescale_vec_flat[(row_idx_r * 32) +: 32];
        for (word_i = 0; word_i < 32; word_i = word_i + 1) begin
            old_lo_s = row_old_data_r[(word_i * 32) +: 16];
            old_hi_s = row_old_data_r[(word_i * 32) + 16 +: 16];
            partial_word_s = partial_o_tile_flat[(((row_idx_r * 32) + word_i) * 32) +: 32];
            part_lo_s = partial_word_s[15:0];
            part_hi_s = partial_word_s[31:16];

            scaled_lo_q24_24_s = $signed(old_lo_s) * $signed(scale_raw_s);
            scaled_hi_q24_24_s = $signed(old_hi_s) * $signed(scale_raw_s);

            if (scaled_lo_q24_24_s >= 0) begin
                scaled_lo_q8_8_s = (scaled_lo_q24_24_s + 64'sd32768) >>> 16;
            end else begin
                scaled_lo_q8_8_s = (scaled_lo_q24_24_s - 64'sd32768) >>> 16;
            end
            if (scaled_hi_q24_24_s >= 0) begin
                scaled_hi_q8_8_s = (scaled_hi_q24_24_s + 64'sd32768) >>> 16;
            end else begin
                scaled_hi_q8_8_s = (scaled_hi_q24_24_s - 64'sd32768) >>> 16;
            end

            new_lo_s = scaled_lo_q8_8_s + $signed(part_lo_s);
            new_hi_s = scaled_hi_q8_8_s + $signed(part_hi_s);
            clamped_lo_s = clamp_q88_from_int(new_lo_s);
            clamped_hi_s = clamp_q88_from_int(new_hi_s);

            row_new_data_w[(word_i * 32) +: 16] = clamped_lo_s;
            row_new_data_w[(word_i * 32) + 16 +: 16] = clamped_hi_s;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
            row_old_data_r <= 1024'd0;
            oacc_row_rd_en <= 1'b0;
            oacc_row_rd_addr <= 4'd0;
            oacc_row_wr_en <= 1'b0;
            oacc_row_wr_addr <= 4'd0;
            oacc_row_wr_data <= 1024'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
            row_old_data_r <= 1024'd0;
            oacc_row_rd_en <= 1'b0;
            oacc_row_rd_addr <= 4'd0;
            oacc_row_wr_en <= 1'b0;
            oacc_row_wr_addr <= 4'd0;
            oacc_row_wr_data <= 1024'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
        end else begin
            oacc_row_rd_en <= 1'b0;
            oacc_row_wr_en <= 1'b0;
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
                if (state_r == ST_DONE) begin
                    state_r <= ST_IDLE;
                end
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        row_idx_r <= 4'd0;
                        state_r <= ST_ROW_REQ;
                    end
                end
                ST_ROW_REQ: begin
                    oacc_row_rd_en <= 1'b1;
                    oacc_row_rd_addr <= row_idx_r;
                    state_r <= ST_ROW_WAIT;
                end
                ST_ROW_WAIT: begin
                    if (oacc_row_rd_valid) begin
                        row_old_data_r <= oacc_row_rd_data;
                        state_r <= ST_ROW_CALC;
                    end
                end
                ST_ROW_CALC: begin
                    oacc_row_wr_addr <= row_idx_r;
                    oacc_row_wr_data <= row_new_data_w;
                    state_r <= ST_ROW_WRITE;
                end
                ST_ROW_WRITE: begin
                    oacc_row_wr_en <= 1'b1;
                    oacc_row_wr_addr <= row_idx_r;
                    oacc_row_wr_data <= row_new_data_w;
                    if (row_idx_r == 4'd15) begin
                        resp_valid <= 1'b1;
                        state_r <= ST_DONE;
                    end else begin
                        row_idx_r <= row_idx_r + 1'b1;
                        state_r <= ST_ROW_REQ;
                    end
                end
                ST_DONE: begin
                end
                default: begin
                    state_r <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
