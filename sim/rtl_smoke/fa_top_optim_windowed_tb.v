`timescale 1ns/1ps

module fa_top_optim_windowed_tb;
    localparam [63:0] Q_BASE = 64'h0000_1000;
    localparam [63:0] K_BASE = 64'h0001_0000;
    localparam [63:0] V_BASE = 64'h0002_0000;
    localparam [63:0] O_BASE = 64'h0003_0000;
    localparam integer Q_TILE_BYTES = 512;
    localparam integer KV_TILE_BYTES = 2048;
    localparam integer O_TOTAL_BYTES = 32768;
    localparam integer O_TOTAL_WORDS = 8192;

    reg         clk;
    reg         rstn;
    reg         clear;
    reg [6:0]   s_axil_awaddr;
    reg         s_axil_awvalid;
    wire        s_axil_awready;
    reg [31:0]  s_axil_wdata;
    reg [3:0]   s_axil_wstrb;
    reg         s_axil_wvalid;
    wire        s_axil_wready;
    wire [1:0]  s_axil_bresp;
    wire        s_axil_bvalid;
    reg         s_axil_bready;
    reg [6:0]   s_axil_araddr;
    reg         s_axil_arvalid;
    wire        s_axil_arready;
    wire [31:0] s_axil_rdata;
    wire [1:0]  s_axil_rresp;
    wire        s_axil_rvalid;
    reg         s_axil_rready;
    wire [63:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;
    reg [127:0] m_axi_rdata;
    reg [1:0]   m_axi_rresp;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;
    wire [63:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    reg         m_axi_awready;
    wire [127:0] m_axi_wdata;
    wire [15:0]  m_axi_wstrb;
    wire         m_axi_wlast;
    wire         m_axi_wvalid;
    reg          m_axi_wready;
    reg [1:0]    m_axi_bresp;
    reg          m_axi_bvalid;
    wire         m_axi_bready;
    wire         irq;

    integer error_count;
    integer wait_count;
    reg [31:0] read_data;
    reg [31:0] status_data;
    reg [31:0] cycles_data;
    reg [31:0] rd_bytes_data;
    reg [31:0] wr_bytes_data;
    integer ar_count;
    integer r_beat_count;
    integer aw_count;
    integer w_beat_count;
    integer b_count;
    integer current_burst_idx;
    integer current_burst_beats;
    integer current_write_burst_idx;
    integer current_write_burst_beats;
    reg [63:0] current_araddr;
    reg [63:0] current_awaddr;
    reg [31:0] o_mem [0:O_TOTAL_WORDS-1];
    reg [15:0] expected_o_cache [0:1023];
    integer init_i;
    integer row_i;
    integer col_i;
    integer qmod_i;

    FA_TOP_OPTIM_WINDOWED dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .irq(irq)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task axil_write;
        input [6:0] addr;
        input [31:0] data;
        begin
            s_axil_awaddr = addr;
            s_axil_wdata = data;
            s_axil_wstrb = 4'hf;
            s_axil_awvalid = 1'b1;
            s_axil_wvalid = 1'b1;
            s_axil_bready = 1'b1;
            while (!(s_axil_awready && s_axil_wready)) begin
                tick();
            end
            tick();
            s_axil_awvalid = 1'b0;
            s_axil_wvalid = 1'b0;
            while (!s_axil_bvalid) begin
                tick();
            end
            if (s_axil_bresp !== 2'b00) begin
                $display("FAIL: AXI-Lite write addr=0x%0h bresp=%0d", addr, s_axil_bresp);
                error_count = error_count + 1;
            end
            tick();
            s_axil_bready = 1'b0;
        end
    endtask

    task axil_read;
        input [6:0] addr;
        output [31:0] data;
        begin
            s_axil_araddr = addr;
            s_axil_arvalid = 1'b1;
            s_axil_rready = 1'b1;
            while (!s_axil_arready) begin
                tick();
            end
            tick();
            s_axil_arvalid = 1'b0;
            while (!s_axil_rvalid) begin
                tick();
            end
            data = s_axil_rdata;
            if (s_axil_rresp !== 2'b00) begin
                $display("FAIL: AXI-Lite read addr=0x%0h rresp=%0d", addr, s_axil_rresp);
                error_count = error_count + 1;
            end
            tick();
            s_axil_rready = 1'b0;
        end
    endtask

    task expect32;
        input [31:0] actual;
        input [31:0] expected;
        input [8*56-1:0] name;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %0d got %0d", name, expected, actual);
                error_count = error_count + 1;
            end
        end
    endtask

    function [15:0] make_q_word;
        input [5:0] q_tile_idx;
        input [1:0] row_idx;
        input [5:0] col_idx;
        begin
            make_q_word = 16'h0001
                        + {13'd0, (row_idx + q_tile_idx[1:0])}
                        + {13'd0, col_idx[1:0]};
        end
    endfunction

    function [15:0] make_k_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [5:0] col_idx;
        begin
            make_k_word = 16'h0001
                        + {13'd0, (row_idx[1:0] + kv_tile_idx[1:0])}
                        + {13'd0, col_idx[1:0]};
        end
    endfunction

    function [15:0] make_v_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [5:0] col_idx;
        begin
            make_v_word = 16'h0010 + ({12'd0, kv_tile_idx[3:0]} << 4)
                        + {12'd0, row_idx} + {10'd0, col_idx};
        end
    endfunction

    function [31:0] make_axi_read_word;
        input [63:0] addr;
        integer byte_offset;
        integer word_idx;
        integer tile_idx;
        integer word_in_tile;
        integer row_idx;
        integer col_pair_idx;
        integer col_idx;
        reg [15:0] lo_word;
        reg [15:0] hi_word;
        begin
            if ((addr >= Q_BASE) && (addr < K_BASE)) begin
                byte_offset = addr - Q_BASE;
                tile_idx = byte_offset / Q_TILE_BYTES;
                word_in_tile = (byte_offset % Q_TILE_BYTES) >> 2;
                row_idx = word_in_tile / 32;
                col_pair_idx = word_in_tile % 32;
                col_idx = col_pair_idx * 2;
                lo_word = make_q_word(tile_idx[5:0], row_idx[1:0], col_idx[5:0]);
                hi_word = make_q_word(tile_idx[5:0], row_idx[1:0], (col_idx + 1) & 6'h3f);
            end else if ((addr >= K_BASE) && (addr < V_BASE)) begin
                byte_offset = addr - K_BASE;
                tile_idx = byte_offset / KV_TILE_BYTES;
                word_in_tile = (byte_offset % KV_TILE_BYTES) >> 2;
                row_idx = word_in_tile / 32;
                col_pair_idx = word_in_tile % 32;
                col_idx = col_pair_idx * 2;
                lo_word = make_k_word(tile_idx[4:0], row_idx[3:0], col_idx[5:0]);
                hi_word = make_k_word(tile_idx[4:0], row_idx[3:0], (col_idx + 1) & 6'h3f);
            end else if ((addr >= V_BASE) && (addr < O_BASE)) begin
                byte_offset = addr - V_BASE;
                tile_idx = byte_offset / KV_TILE_BYTES;
                word_in_tile = (byte_offset % KV_TILE_BYTES) >> 2;
                row_idx = word_in_tile / 32;
                col_pair_idx = word_in_tile % 32;
                col_idx = col_pair_idx * 2;
                lo_word = make_v_word(tile_idx[4:0], row_idx[3:0], col_idx[5:0]);
                hi_word = make_v_word(tile_idx[4:0], row_idx[3:0], (col_idx + 1) & 6'h3f);
            end else begin
                lo_word = 16'hx;
                hi_word = 16'hx;
                $display("FAIL: AXI read addr outside Q/K/V regions addr=0x%016h", addr);
                error_count = error_count + 1;
            end
            make_axi_read_word = {hi_word, lo_word};
        end
    endfunction

    function [127:0] make_axi_read_beat;
        input [63:0] addr;
        begin
            make_axi_read_beat = {
                make_axi_read_word(addr + 64'd12),
                make_axi_read_word(addr + 64'd8),
                make_axi_read_word(addr + 64'd4),
                make_axi_read_word(addr)
            };
        end
    endfunction

    function signed [31:0] tb_q16_add_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [32:0] sum_ext;
        begin
            sum_ext = lhs + rhs;
            if (sum_ext > 33'sh0_7FFF_FFFF) begin
                tb_q16_add_sat = 32'sh7FFF_FFFF;
            end else if (sum_ext < -33'sh0_8000_0000) begin
                tb_q16_add_sat = -32'sh8000_0000;
            end else begin
                tb_q16_add_sat = sum_ext[31:0];
            end
        end
    endfunction

    function signed [31:0] tb_q16_mul_rn_sat;
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
                tb_q16_mul_rn_sat = 32'sh7FFF_FFFF;
            end else if (shifted < -64'sh0000_0000_8000_0000) begin
                tb_q16_mul_rn_sat = -32'sh8000_0000;
            end else begin
                tb_q16_mul_rn_sat = shifted[31:0];
            end
        end
    endfunction

    function signed [31:0] tb_q16_clamp_nonpos_neg8;
        input signed [31:0] value;
        begin
            if (value > 32'sd0) begin
                tb_q16_clamp_nonpos_neg8 = 32'sd0;
            end else if (value < -32'sd524288) begin
                tb_q16_clamp_nonpos_neg8 = -32'sd524288;
            end else begin
                tb_q16_clamp_nonpos_neg8 = value;
            end
        end
    endfunction

    function [8:0] tb_q16_delta_to_exp_idx;
        input signed [31:0] delta;
        reg signed [31:0] clamped;
        reg [31:0] abs_mag;
        reg [31:0] rounded;
        reg [31:0] shifted;
        begin
            clamped = tb_q16_clamp_nonpos_neg8(delta);
            abs_mag = -clamped;
            rounded = abs_mag + 32'd1024;
            shifted = rounded >> 11;
            if (shifted > 32'd256) begin
                tb_q16_delta_to_exp_idx = 9'd256;
            end else begin
                tb_q16_delta_to_exp_idx = shifted[8:0];
            end
        end
    endfunction

    function [31:0] fa_exp_lut_q16_16;
        input [8:0] idx;
        begin
            case (idx)
`include "fa_exp_lut_q16_16.vh"
                default: fa_exp_lut_q16_16 = 32'h00000016;
            endcase
        end
    endfunction

    function signed [15:0] tb_q16_to_q88_rn_sat;
        input signed [31:0] value;
        reg signed [31:0] rounded;
        reg signed [31:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 32'sd128;
            end else begin
                rounded = value - 32'sd128;
            end
            shifted = rounded >>> 8;
            if (shifted > 32'sd32767) begin
                tb_q16_to_q88_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                tb_q16_to_q88_rn_sat = -16'sh8000;
            end else begin
                tb_q16_to_q88_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function signed [15:0] tb_q16_to_q412_rn_sat;
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
                tb_q16_to_q412_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                tb_q16_to_q412_rn_sat = -16'sh8000;
            end else begin
                tb_q16_to_q412_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function signed [15:0] tb_q16_16_to_q88_sat128;
        input signed [127:0] value;
        reg signed [127:0] rounded;
        reg signed [127:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 128'sd128;
            end else begin
                rounded = value - 128'sd128;
            end
            shifted = rounded >>> 8;
            if (shifted > 128'sd32767) begin
                tb_q16_16_to_q88_sat128 = 16'sh7FFF;
            end else if (shifted < -128'sd32768) begin
                tb_q16_16_to_q88_sat128 = -16'sh8000;
            end else begin
                tb_q16_16_to_q88_sat128 = shifted[15:0];
            end
        end
    endfunction

    function signed [31:0] tb_q88_to_q16;
        input signed [15:0] value;
        begin
            tb_q88_to_q16 = {{8{value[15]}}, value, 8'd0};
        end
    endfunction

    function signed [31:0] tb_q412_to_q16;
        input signed [15:0] value;
        begin
            tb_q412_to_q16 = {{12{value[15]}}, value, 4'd0};
        end
    endfunction

    function [31:0] tb_recip_q16_16;
        input [31:0] in_value;
        reg [63:0] dividend;
        reg [63:0] divisor;
        reg [63:0] quotient;
        begin
            dividend = 64'h1_0000_0000;
            divisor = {32'd0, in_value};
            if ((in_value[31] == 1'b1) || (in_value == 32'd0)) begin
                quotient = 64'd0;
            end else begin
                quotient = dividend / divisor;
            end
            if (quotient > 64'h7FFF_FFFF) begin
                tb_recip_q16_16 = 32'h7FFF_FFFF;
            end else begin
                tb_recip_q16_16 = quotient[31:0];
            end
        end
    endfunction

    function [15:0] tb_update_oacc_elem;
        input signed [15:0] old_q412_word;
        input signed [31:0] scale_word;
        input signed [15:0] partial_q88_word;
        reg signed [31:0] old_q16_v;
        reg signed [31:0] scaled_old_q16_v;
        reg signed [31:0] partial_q16_v;
        reg signed [31:0] next_q16_v;
        begin
            old_q16_v = tb_q412_to_q16(old_q412_word);
            scaled_old_q16_v = tb_q16_mul_rn_sat(old_q16_v, scale_word);
            partial_q16_v = tb_q88_to_q16(partial_q88_word);
            next_q16_v = tb_q16_add_sat(scaled_old_q16_v, partial_q16_v);
            tb_update_oacc_elem = tb_q16_to_q412_rn_sat(next_q16_v);
        end
    endfunction

    function signed [31:0] expected_score_q16;
        input integer q_tile_idx;
        input integer q_row;
        input integer kv_tile_idx;
        input integer kv_col;
        integer dim_i;
        reg [5:0] dim_idx;
        reg signed [15:0] q_q88;
        reg signed [15:0] k_q88;
        reg signed [127:0] acc_q16;
        begin
            acc_q16 = 128'sd0;
            for (dim_i = 0; dim_i < 64; dim_i = dim_i + 1) begin
                dim_idx = dim_i;
                q_q88 = make_q_word(q_tile_idx[5:0], q_row[1:0], dim_idx);
                k_q88 = make_k_word(kv_tile_idx[4:0], kv_col[3:0], dim_idx);
                acc_q16 = acc_q16 + ($signed(q_q88) * $signed(k_q88));
            end
            if (acc_q16 > 128'sh0000000000000000000000007FFF_FFFF) begin
                expected_score_q16 = 32'sh7FFF_FFFF;
            end else if (acc_q16 < -128'sh0000000000000000000000008000_0000) begin
                expected_score_q16 = -32'sh8000_0000;
            end else begin
                expected_score_q16 = acc_q16[31:0];
            end
        end
    endfunction

    function [15:0] expected_o_word_dense_qk;
        input integer q_tile_idx;
        input integer row;
        input integer col;
        reg [5:0] q_tile_idx_narrow;
        reg [1:0] row_idx_narrow;
        reg [5:0] col_idx_narrow;
        integer kv_i;
        integer key_col_i;
        reg signed [31:0] old_m_q16;
        reg signed [31:0] old_l_q16;
        reg signed [31:0] new_m_q16;
        reg signed [31:0] old_score_q16;
        reg signed [31:0] score_q16;
        reg signed [31:0] alpha_q16;
        reg signed [31:0] alpha_l_old_q16;
        reg signed [31:0] beta_q16 [0:15];
        reg signed [31:0] beta_sum_q16;
        reg signed [31:0] new_l_q16;
        reg signed [31:0] recip_q16;
        reg signed [31:0] scale_q16;
        reg signed [31:0] p_q16;
        reg signed [15:0] p_q88;
        reg signed [15:0] v_q88;
        reg signed [15:0] partial_q88;
        reg signed [15:0] old_o_q412;
        reg signed [127:0] partial_acc_q16;
        begin
            q_tile_idx_narrow = q_tile_idx;
            row_idx_narrow = row;
            col_idx_narrow = col;
            old_m_q16 = 32'hffc0_0000;
            old_l_q16 = 32'sd0;
            old_o_q412 = 16'sd0;
            for (kv_i = 0; kv_i < 16; kv_i = kv_i + 1) begin
                new_m_q16 = expected_score_q16(q_tile_idx_narrow, row_idx_narrow, kv_i, 0);
                for (key_col_i = 1; key_col_i < 16; key_col_i = key_col_i + 1) begin
                    score_q16 = expected_score_q16(q_tile_idx_narrow, row_idx_narrow,
                                                   kv_i, key_col_i);
                    if (score_q16 > new_m_q16) begin
                        new_m_q16 = score_q16;
                    end
                end
                if (old_l_q16 != 32'sd0) begin
                    if (old_m_q16 > new_m_q16) begin
                        new_m_q16 = old_m_q16;
                    end
                    alpha_q16 = fa_exp_lut_q16_16(
                        tb_q16_delta_to_exp_idx(old_m_q16 - new_m_q16));
                    alpha_l_old_q16 = tb_q16_mul_rn_sat(alpha_q16, old_l_q16);
                end else begin
                    alpha_l_old_q16 = 32'sd0;
                end

                beta_sum_q16 = 32'sd0;
                for (key_col_i = 0; key_col_i < 16; key_col_i = key_col_i + 1) begin
                    old_score_q16 = expected_score_q16(q_tile_idx_narrow, row_idx_narrow,
                                                       kv_i, key_col_i);
                    beta_q16[key_col_i] = fa_exp_lut_q16_16(
                        tb_q16_delta_to_exp_idx(old_score_q16 - new_m_q16));
                    beta_sum_q16 = tb_q16_add_sat(beta_sum_q16, beta_q16[key_col_i]);
                end
                new_l_q16 = tb_q16_add_sat(alpha_l_old_q16, beta_sum_q16);
                recip_q16 = tb_recip_q16_16(new_l_q16);

                if (old_l_q16 == 32'sd0) begin
                    scale_q16 = 32'sd0;
                end else begin
                    scale_q16 = tb_q16_mul_rn_sat(alpha_l_old_q16, recip_q16);
                end
                partial_acc_q16 = 128'sd0;
                for (key_col_i = 0; key_col_i < 16; key_col_i = key_col_i + 1) begin
                    p_q16 = tb_q16_mul_rn_sat(beta_q16[key_col_i], recip_q16);
                    p_q88 = tb_q16_to_q88_rn_sat(p_q16);
                    v_q88 = make_v_word(kv_i[4:0], key_col_i[3:0], col_idx_narrow);
                    partial_acc_q16 = partial_acc_q16 + ($signed(p_q88) * $signed(v_q88));
                end
                partial_q88 = tb_q16_16_to_q88_sat128(partial_acc_q16);
                old_o_q412 = tb_update_oacc_elem(old_o_q412, scale_q16, partial_q88);
                old_m_q16 = new_m_q16;
                old_l_q16 = new_l_q16;
            end
            expected_o_word_dense_qk = old_o_q412;
        end
    endfunction

    task init_expected_o_cache;
        integer cache_qmod_i;
        integer cache_row_i;
        integer cache_col_i;
        integer cache_idx;
        begin
            for (cache_qmod_i = 0; cache_qmod_i < 4; cache_qmod_i = cache_qmod_i + 1) begin
                for (cache_row_i = 0; cache_row_i < 4; cache_row_i = cache_row_i + 1) begin
                    for (cache_col_i = 0; cache_col_i < 64; cache_col_i = cache_col_i + 1) begin
                        cache_idx = (cache_qmod_i * 256) + (cache_row_i * 64) + cache_col_i;
                        expected_o_cache[cache_idx] =
                            expected_o_word_dense_qk(cache_qmod_i, cache_row_i, cache_col_i);
                    end
                end
            end
        end
    endtask

    function [15:0] expected_cached_o_word;
        input integer q_tile_idx;
        input integer row;
        input integer col;
        integer cache_idx;
        begin
            cache_idx = ((q_tile_idx & 3) * 256) + ((row & 3) * 64) + (col & 63);
            expected_cached_o_word = expected_o_cache[cache_idx];
        end
    endfunction

    function [15:0] get_o_mem_word;
        input integer row;
        input integer col;
        integer word_idx;
        reg [31:0] packed_word;
        begin
            word_idx = ((row * 64) + col) >> 1;
            packed_word = o_mem[word_idx];
            if ((col & 1) == 0) begin
                get_o_mem_word = packed_word[15:0];
            end else begin
                get_o_mem_word = packed_word[31:16];
            end
        end
    endfunction

    task expect_o_memory_dense_qk;
        reg [15:0] actual;
        reg [15:0] expected;
        integer q_tile_idx;
        integer local_row_idx;
        begin
            for (row_i = 0; row_i < 256; row_i = row_i + 1) begin
                for (col_i = 0; col_i < 64; col_i = col_i + 1) begin
                    q_tile_idx = row_i >> 2;
                    local_row_idx = row_i & 3;
                    actual = get_o_mem_word(row_i, col_i);
                    expected = expected_cached_o_word(q_tile_idx, local_row_idx, col_i);
                    if (actual !== expected) begin
                        if (error_count < 16) begin
                            $display("FAIL: O[%0d,%0d] expected 0x%04h got 0x%04h",
                                     row_i, col_i, expected, actual);
                        end
                        error_count = error_count + 1;
                    end
                end
            end
        end
    endtask

    task drive_axi_read_channel;
        integer safety_count;
        integer next_burst_idx;
        reg read_active;
        reg ar_fire;
        reg r_fire;
        reg [63:0] araddr_sample;
        reg [7:0] arlen_sample;
        reg [63:0] next_araddr;
        begin
            m_axi_arready = 1'b0;
            m_axi_rvalid = 1'b0;
            m_axi_rlast = 1'b0;
            m_axi_rdata = 128'd0;
            m_axi_rresp = 2'b00;
            ar_count = 0;
            r_beat_count = 0;
            current_burst_idx = 0;
            current_burst_beats = 0;
            current_araddr = 64'd0;
            read_active = 1'b0;
            ar_fire = 1'b0;
            r_fire = 1'b0;
            araddr_sample = 64'd0;
            arlen_sample = 8'd0;
            next_araddr = 64'd0;
            safety_count = 0;
            wait (rstn === 1'b1);
            forever begin
                m_axi_arready = (!read_active && !m_axi_rvalid);
                ar_fire = m_axi_arvalid && m_axi_arready;
                r_fire = m_axi_rvalid && m_axi_rready;

                if (ar_fire) begin
                    araddr_sample = m_axi_araddr;
                    arlen_sample = m_axi_arlen;
                    if (m_axi_arsize !== 3'd4) begin
                        $display("FAIL: AXI arsize expected 4 got %0d", m_axi_arsize);
                        error_count = error_count + 1;
                    end
                    if (m_axi_arburst !== 2'b01) begin
                        $display("FAIL: AXI arburst expected INCR got %0d", m_axi_arburst);
                        error_count = error_count + 1;
                    end
                end

                tick();

                if (ar_fire) begin
                    current_araddr = araddr_sample;
                    current_burst_beats = arlen_sample + 1;
                    current_burst_idx = 0;
                    ar_count = ar_count + 1;
                    read_active = 1'b1;
                    m_axi_rvalid = 1'b1;
                    m_axi_rdata = make_axi_read_beat(araddr_sample);
                    m_axi_rlast = (arlen_sample == 8'd0);
                end else if (r_fire) begin
                    r_beat_count = r_beat_count + 1;
                    if (current_burst_idx == current_burst_beats - 1) begin
                        m_axi_rvalid = 1'b0;
                        m_axi_rlast = 1'b0;
                        m_axi_rdata = 128'd0;
                        read_active = 1'b0;
                    end else begin
                        next_burst_idx = current_burst_idx + 1;
                        next_araddr = current_araddr + 64'd16;
                        current_burst_idx = next_burst_idx;
                        current_araddr = next_araddr;
                        m_axi_rdata = make_axi_read_beat(next_araddr);
                        m_axi_rlast = (next_burst_idx == current_burst_beats - 1);
                    end
                end

                safety_count = safety_count + 1;
                if (safety_count > 2500000) begin
                    $display("FAIL: AXI read channel driver timeout ar_count=%0d r_beat_count=%0d",
                             ar_count, r_beat_count);
                    error_count = error_count + 1;
                    $fatal(1);
                end
            end
        end
    endtask

    task store_axi_write_beat;
        input [63:0] addr;
        input [127:0] data;
        input [15:0] strb;
        integer byte_offset;
        integer word_idx;
        begin
            if ((addr < O_BASE) || ((addr + 64'd16) > (O_BASE + O_TOTAL_BYTES))) begin
                $display("FAIL: AXI write addr outside O region addr=0x%016h", addr);
                error_count = error_count + 1;
            end else begin
                if (strb !== 16'hffff) begin
                    $display("FAIL: AXI write strobe expected ffff got 0x%04h", strb);
                    error_count = error_count + 1;
                end
                byte_offset = addr - O_BASE;
                if ((byte_offset & 15) != 0) begin
                    $display("FAIL: AXI write addr not 16B aligned addr=0x%016h", addr);
                    error_count = error_count + 1;
                end
                word_idx = byte_offset >> 2;
                o_mem[word_idx + 0] = data[31:0];
                o_mem[word_idx + 1] = data[63:32];
                o_mem[word_idx + 2] = data[95:64];
                o_mem[word_idx + 3] = data[127:96];
            end
        end
    endtask

    task drive_axi_write_channel;
        integer safety_count;
        reg write_active;
        reg aw_fire;
        reg w_fire;
        reg b_fire;
        reg [63:0] awaddr_sample;
        reg [7:0] awlen_sample;
        begin
            m_axi_awready = 1'b0;
            m_axi_wready = 1'b0;
            m_axi_bresp = 2'b00;
            m_axi_bvalid = 1'b0;
            aw_count = 0;
            w_beat_count = 0;
            b_count = 0;
            current_write_burst_idx = 0;
            current_write_burst_beats = 0;
            current_awaddr = 64'd0;
            write_active = 1'b0;
            aw_fire = 1'b0;
            w_fire = 1'b0;
            b_fire = 1'b0;
            awaddr_sample = 64'd0;
            awlen_sample = 8'd0;
            safety_count = 0;
            wait (rstn === 1'b1);
            forever begin
                m_axi_awready = (!write_active && !m_axi_bvalid);
                m_axi_wready = write_active;
                aw_fire = m_axi_awvalid && m_axi_awready;
                w_fire = m_axi_wvalid && m_axi_wready;
                b_fire = m_axi_bvalid && m_axi_bready;

                if (aw_fire) begin
                    awaddr_sample = m_axi_awaddr;
                    awlen_sample = m_axi_awlen;
                    if (m_axi_awsize !== 3'd4) begin
                        $display("FAIL: AXI awsize expected 4 got %0d", m_axi_awsize);
                        error_count = error_count + 1;
                    end
                    if (m_axi_awburst !== 2'b01) begin
                        $display("FAIL: AXI awburst expected INCR got %0d", m_axi_awburst);
                        error_count = error_count + 1;
                    end
                    if (m_axi_awlen > 8'd15) begin
                        $display("FAIL: AXI awlen expected <= 15 got %0d", m_axi_awlen);
                        error_count = error_count + 1;
                    end
                end

                if (w_fire) begin
                    if (!write_active) begin
                        $display("FAIL: AXI W beat without active AW");
                        error_count = error_count + 1;
                    end
                    if (m_axi_wlast !== (current_write_burst_idx == current_write_burst_beats - 1)) begin
                        $display("FAIL: AXI wlast mismatch beat=%0d beats=%0d wlast=%0d",
                                 current_write_burst_idx, current_write_burst_beats,
                                 m_axi_wlast);
                        error_count = error_count + 1;
                    end
                    store_axi_write_beat(current_awaddr, m_axi_wdata, m_axi_wstrb);
                end

                tick();

                if (aw_fire) begin
                    current_awaddr = awaddr_sample;
                    current_write_burst_beats = awlen_sample + 1;
                    current_write_burst_idx = 0;
                    aw_count = aw_count + 1;
                    write_active = 1'b1;
                end

                if (w_fire) begin
                    w_beat_count = w_beat_count + 1;
                    if (current_write_burst_idx == current_write_burst_beats - 1) begin
                        write_active = 1'b0;
                        m_axi_bvalid = 1'b1;
                        current_awaddr = 64'd0;
                    end else begin
                        current_write_burst_idx = current_write_burst_idx + 1;
                        current_awaddr = current_awaddr + 64'd16;
                    end
                end

                if (b_fire) begin
                    b_count = b_count + 1;
                    m_axi_bvalid = 1'b0;
                end

                safety_count = safety_count + 1;
                if (safety_count > 2500000) begin
                    $display("FAIL: AXI write channel driver timeout aw_count=%0d w_beat_count=%0d b_count=%0d",
                             aw_count, w_beat_count, b_count);
                    error_count = error_count + 1;
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin
        error_count = 0;
        wait_count = 0;
        for (init_i = 0; init_i < O_TOTAL_WORDS; init_i = init_i + 1) begin
            o_mem[init_i] = 32'hdead_beef;
        end
        init_expected_o_cache();
        rstn = 1'b0;
        clear = 1'b0;
        s_axil_awaddr = 7'd0;
        s_axil_awvalid = 1'b0;
        s_axil_wdata = 32'd0;
        s_axil_wstrb = 4'd0;
        s_axil_wvalid = 1'b0;
        s_axil_bready = 1'b0;
        s_axil_araddr = 7'd0;
        s_axil_arvalid = 1'b0;
        s_axil_rready = 1'b0;
        m_axi_arready = 1'b0;
        m_axi_rdata = 128'd0;
        m_axi_rresp = 2'b00;
        m_axi_rlast = 1'b0;
        m_axi_rvalid = 1'b0;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b0;

        tick();
        tick();
        rstn = 1'b1;
        tick();

        axil_write(7'h14, Q_BASE[31:0]);
        axil_write(7'h18, Q_BASE[63:32]);
        axil_write(7'h1c, K_BASE[31:0]);
        axil_write(7'h20, K_BASE[63:32]);
        axil_write(7'h24, V_BASE[31:0]);
        axil_write(7'h28, V_BASE[63:32]);
        axil_write(7'h2c, O_BASE[31:0]);
        axil_write(7'h30, O_BASE[63:32]);
        axil_write(7'h34, 32'd128);
        axil_write(7'h00, 32'h0000_0001);

        while (wait_count < 400000) begin
            axil_read(7'h04, status_data);
            if (status_data[1]) begin
                wait_count = 400000;
            end else begin
                if (status_data[2]) begin
                    $display("FAIL: STATUS error set before done, status=0x%08h", status_data);
                    error_count = error_count + 1;
                    wait_count = 400000;
                end else begin
                    wait_count = wait_count + 1;
                end
            end
        end

        axil_read(7'h04, status_data);
        if (!status_data[1]) begin
            $display("FAIL: timeout waiting for windowed top done, status=0x%08h", status_data);
            error_count = error_count + 1;
        end
        if (status_data[2]) begin
            $display("FAIL: windowed top status error set, status=0x%08h", status_data);
            error_count = error_count + 1;
        end

        axil_read(7'h40, read_data);
        cycles_data = read_data;
        if (read_data !== 32'd165509) begin
            $display("FAIL: CYCLES expected 165509 got %0d", read_data);
            error_count = error_count + 1;
        end

        axil_read(7'h44, read_data);
        rd_bytes_data = read_data;
        if (read_data !== 32'd393216) begin
            $display("FAIL: RD_BYTES expected 393216 got %0d", read_data);
            error_count = error_count + 1;
        end

        axil_read(7'h48, read_data);
        wr_bytes_data = read_data;
        if (read_data !== 32'd32768) begin
            $display("FAIL: WR_BYTES expected 32768 got %0d", read_data);
            error_count = error_count + 1;
        end

        expect32(ar_count, 32'd1536, "ar_count");
        expect32(r_beat_count, 32'd24576, "r_beat_count");
        expect32(aw_count, 32'd128, "aw_count");
        expect32(w_beat_count, 32'd2048, "w_beat_count");
        expect32(b_count, 32'd128, "b_count");
        expect_o_memory_dense_qk();

        if (error_count == 0) begin
            $display("PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference cycles=%0d rd_bytes=%0d wr_bytes=%0d ar_count=%0d r_beat_count=%0d aw_count=%0d w_beat_count=%0d",
                     cycles_data, rd_bytes_data, wr_bytes_data, ar_count, r_beat_count,
                     aw_count, w_beat_count);
            $finish;
        end

        $display("FAIL: fa_top_optim_windowed_tb errors=%0d", error_count);
        $fatal(1);
    end

    initial begin
        drive_axi_read_channel();
    end

    initial begin
        drive_axi_write_channel();
    end
endmodule
