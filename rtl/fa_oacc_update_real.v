module FA_OACC_UPDATE_REAL #(
    parameter USE_PARTIAL_ROW_INPUT = 0
) (
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           req_valid,
    output wire           req_ready,
    input  wire [511:0]   rescale_vec_flat,
    input  wire [16383:0] partial_o_tile_flat,
    output reg            partial_row_rd_en,
    output reg  [3:0]     partial_row_rd_addr,
    input  wire           partial_row_rd_valid,
    input  wire [1023:0]  partial_row_rd_data,
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
    localparam [2:0] ST_ROW_WRITE = 3'd3;
    localparam [2:0] ST_DONE      = 3'd5;

    reg [2:0]   state_r;
    reg [2:0]   state_n;
    reg [3:0]   row_idx_r;
    reg [3:0]   row_idx_n;
    reg [1023:0] row_new_data_w;
    reg          oacc_row_rd_en_n;
    reg [3:0]    oacc_row_rd_addr_n;
    reg          oacc_row_wr_en_n;
    reg [3:0]    oacc_row_wr_addr_n;
    reg [1023:0] oacc_row_wr_data_n;
    reg          partial_row_rd_en_n;
    reg [3:0]    partial_row_rd_addr_n;
    reg          resp_valid_n;
    reg          done_pulse_n;
    reg signed [31:0] scale_raw_s;
    reg signed [15:0] partial_q88_s;
    integer elem_i;

    function automatic signed [31:0] q16_add_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [32:0] sum_ext;
        begin
            sum_ext = lhs + rhs;
            if (sum_ext > 33'sh0_7FFF_FFFF) begin
                q16_add_sat = 32'sh7FFF_FFFF;
            end else if (sum_ext < -33'sh0_8000_0000) begin
                q16_add_sat = -32'sh8000_0000;
            end else begin
                q16_add_sat = sum_ext[31:0];
            end
        end
    endfunction

    function automatic signed [31:0] q16_mul_rn_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [63:0] prod;
        reg signed [63:0] rounded;
        reg signed [63:0] shifted;
        begin
            prod = lhs * rhs;
            if (prod >= 0) begin
                rounded = prod + 64'sd32768;
            end else begin
                rounded = prod - 64'sd32768;
            end
            shifted = rounded >>> 16;
            if (shifted > 64'sh0000_0000_7FFF_FFFF) begin
                q16_mul_rn_sat = 32'sh7FFF_FFFF;
            end else if (shifted < -64'sh0000_0000_8000_0000) begin
                q16_mul_rn_sat = -32'sh8000_0000;
            end else begin
                q16_mul_rn_sat = shifted[31:0];
            end
        end
    endfunction

    function automatic signed [31:0] q88_to_q16;
        input signed [15:0] value;
        begin
            q88_to_q16 = {{8{value[15]}}, value, 8'd0};
        end
    endfunction

    function automatic signed [31:0] q412_to_q16;
        input signed [15:0] value;
        begin
            q412_to_q16 = {{12{value[15]}}, value, 4'd0};
        end
    endfunction

    function automatic signed [15:0] q16_to_q412_rn_sat;
        input signed [31:0] value;
        reg signed [31:0] rounded;
        reg signed [31:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 32'sd8;
            end else begin
                rounded = value - 32'sd8;
            end
            shifted = rounded >>> 4;
            if (shifted > 32'sd32767) begin
                q16_to_q412_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                q16_to_q412_rn_sat = -16'sh8000;
            end else begin
                q16_to_q412_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function automatic [15:0] update_oacc_elem;
        input signed [15:0] old_q412_word;
        input signed [31:0] scale_word;
        input signed [15:0] partial_q88_word;
        reg signed [31:0] old_q16_v;
        reg signed [31:0] scaled_old_q16_v;
        reg signed [31:0] partial_q16_v;
        reg signed [31:0] next_q16_v;
        begin
            old_q16_v = q412_to_q16(old_q412_word);
            scaled_old_q16_v = q16_mul_rn_sat(old_q16_v, scale_word);
            partial_q16_v = q88_to_q16(partial_q88_word);
            next_q16_v = q16_add_sat(scaled_old_q16_v, partial_q16_v);
            update_oacc_elem = q16_to_q412_rn_sat(next_q16_v);
        end
    endfunction

    function automatic [2:0] next_state_fn;
        input [2:0] state_cur;
        input req_valid_i;
        input req_ready_i;
        input oacc_row_rd_valid_i;
        input partial_row_rd_valid_i;
        input resp_valid_i;
        input resp_ready_i;
        input row_is_last_i;
        reg row_inputs_valid;
        begin
            row_inputs_valid = oacc_row_rd_valid_i &&
                               ((USE_PARTIAL_ROW_INPUT == 0) || partial_row_rd_valid_i);
            case (state_cur)
                ST_IDLE: begin
                    if (req_valid_i && req_ready_i) begin
                        next_state_fn = ST_ROW_REQ;
                    end else begin
                        next_state_fn = ST_IDLE;
                    end
                end
                ST_ROW_REQ: begin
                    next_state_fn = ST_ROW_WAIT;
                end
                ST_ROW_WAIT: begin
                    if (row_inputs_valid) begin
                        next_state_fn = ST_ROW_WRITE;
                    end else begin
                        next_state_fn = ST_ROW_WAIT;
                    end
                end
                ST_ROW_WRITE: begin
                    if (row_is_last_i) begin
                        next_state_fn = ST_DONE;
                    end else begin
                        next_state_fn = ST_ROW_REQ;
                    end
                end
                ST_DONE: begin
                    if (resp_valid_i && resp_ready_i) begin
                        next_state_fn = ST_IDLE;
                    end else begin
                        next_state_fn = ST_DONE;
                    end
                end
                default: begin
                    next_state_fn = ST_IDLE;
                end
            endcase
        end
    endfunction

    function automatic next_resp_valid_fn;
        input resp_valid_cur;
        input resp_ready_i;
        input [2:0] state_cur;
        input row_is_last_i;
        begin
            if (resp_valid_cur && resp_ready_i) begin
                next_resp_valid_fn = 1'b0;
            end else if ((state_cur == ST_ROW_WRITE) && row_is_last_i) begin
                next_resp_valid_fn = 1'b1;
            end else begin
                next_resp_valid_fn = resp_valid_cur;
            end
        end
    endfunction

    assign req_ready = (state_r == ST_IDLE) && !resp_valid;

    always @(*) begin
        state_n = next_state_fn(
            state_r,
            req_valid,
            req_ready,
            oacc_row_rd_valid,
            partial_row_rd_valid,
            resp_valid,
            resp_ready,
            row_idx_r == 4'd15
        );
        row_idx_n = row_idx_r;
        oacc_row_rd_en_n = 1'b0;
        oacc_row_rd_addr_n = oacc_row_rd_addr;
        oacc_row_wr_en_n = 1'b0;
        oacc_row_wr_addr_n = oacc_row_wr_addr;
        oacc_row_wr_data_n = oacc_row_wr_data;
        partial_row_rd_en_n = 1'b0;
        partial_row_rd_addr_n = partial_row_rd_addr;
        resp_valid_n = next_resp_valid_fn(
            resp_valid,
            resp_ready,
            state_r,
            row_idx_r == 4'd15
        );
        done_pulse_n = 1'b0;

        if (resp_valid && resp_ready) begin
            done_pulse_n = 1'b1;
        end

        case (state_r)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    row_idx_n = 4'd0;
                end
            end
            ST_ROW_REQ: begin
                oacc_row_rd_en_n = 1'b1;
                oacc_row_rd_addr_n = row_idx_r;
                partial_row_rd_en_n = (USE_PARTIAL_ROW_INPUT != 0);
                partial_row_rd_addr_n = row_idx_r;
            end
            ST_ROW_WAIT: begin
                if (oacc_row_rd_valid && ((USE_PARTIAL_ROW_INPUT == 0) || partial_row_rd_valid)) begin
                    oacc_row_wr_addr_n = row_idx_r;
                    oacc_row_wr_data_n = row_new_data_w;
                end
            end
            ST_ROW_WRITE: begin
                oacc_row_wr_en_n = 1'b1;
                if (row_idx_r != 4'd15) begin
                    row_idx_n = row_idx_r + 1'b1;
                end
            end
            ST_DONE: begin
            end
            default: begin
            end
        endcase
    end

    always @(*) begin
        row_new_data_w = 1024'd0;
        scale_raw_s = rescale_vec_flat[(row_idx_r * 32) +: 32];
        for (elem_i = 0; elem_i < 64; elem_i = elem_i + 1) begin
            if (USE_PARTIAL_ROW_INPUT != 0) begin
                partial_q88_s = partial_row_rd_data[(elem_i * 16) +: 16];
            end else begin
                partial_q88_s = partial_o_tile_flat[(((row_idx_r * 32) + (elem_i >> 1)) * 32) + ((elem_i & 1) * 16) +: 16];
            end
            row_new_data_w[(elem_i * 16) +: 16] = update_oacc_elem(
                oacc_row_rd_data[(elem_i * 16) +: 16],
                scale_raw_s,
                partial_q88_s
            );
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
            oacc_row_rd_en <= 1'b0;
            oacc_row_rd_addr <= 4'd0;
            oacc_row_wr_en <= 1'b0;
            oacc_row_wr_addr <= 4'd0;
`ifndef SYNTHESIS
            oacc_row_wr_data <= 1024'd0;
`endif
            partial_row_rd_en <= 1'b0;
            partial_row_rd_addr <= 4'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
            oacc_row_rd_en <= 1'b0;
            oacc_row_rd_addr <= 4'd0;
            oacc_row_wr_en <= 1'b0;
            oacc_row_wr_addr <= 4'd0;
`ifndef SYNTHESIS
            oacc_row_wr_data <= 1024'd0;
`endif
            partial_row_rd_en <= 1'b0;
            partial_row_rd_addr <= 4'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
        end else begin
            state_r <= state_n;
            row_idx_r <= row_idx_n;
            oacc_row_rd_en <= oacc_row_rd_en_n;
            oacc_row_rd_addr <= oacc_row_rd_addr_n;
            oacc_row_wr_en <= oacc_row_wr_en_n;
            oacc_row_wr_addr <= oacc_row_wr_addr_n;
            oacc_row_wr_data <= oacc_row_wr_data_n;
            partial_row_rd_en <= partial_row_rd_en_n;
            partial_row_rd_addr <= partial_row_rd_addr_n;
            resp_valid <= resp_valid_n;
            done_pulse <= done_pulse_n;
        end
    end

endmodule
