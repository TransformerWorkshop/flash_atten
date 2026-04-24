module PT_SHELL_AXIL_CSR_SIM #(
	parameter AXIL_ADDR_W = 8,
	parameter AXIL_DATA_W = 32,
	parameter EXT_ADDR_W = 32
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire [AXIL_ADDR_W-1:0]     s_axil_awaddr,
	input  wire                       s_axil_awvalid,
	output wire                       s_axil_awready,
	input  wire [AXIL_DATA_W-1:0]     s_axil_wdata,
	input  wire [AXIL_DATA_W/8-1:0]   s_axil_wstrb,
	input  wire                       s_axil_wvalid,
	output wire                       s_axil_wready,
	output wire [1:0]                 s_axil_bresp,
	output wire                       s_axil_bvalid,
	input  wire                       s_axil_bready,
	input  wire [AXIL_ADDR_W-1:0]     s_axil_araddr,
	input  wire                       s_axil_arvalid,
	output wire                       s_axil_arready,
	output wire [AXIL_DATA_W-1:0]     s_axil_rdata,
	output wire [1:0]                 s_axil_rresp,
	output wire                       s_axil_rvalid,
	input  wire                       s_axil_rready,
	input  wire [31:0]                resp_head,
	input  wire [31:0]                out_meta_head0,
	input  wire [31:0]                out_meta_head1,
	input  wire [31:0]                out_meta_head2,
	input  wire [31:0]                shell_status_word,
	input  wire                       status_cmd_slot_ready,
	input  wire                       status_resp_not_empty,
	input  wire                       status_irq_active,
	input  wire                       status_cmd_busy,
	output reg                        desc_push_pulse,
	output reg                        resp_pop_pulse,
	output reg                        soft_clear_pulse,
	output reg                        clear_flags_pulse,
	output reg                        ingress_push_pulse,
	output reg                        out_meta_pop_pulse,
	output reg  [31:0]                cmd_inst_reg,
	output reg  [31:0]                cmd_id_reg,
	output reg  [EXT_ADDR_W-1:0]      a_addr_reg,
	output reg  [EXT_ADDR_W-1:0]      b_addr_reg,
	output reg  [EXT_ADDR_W-1:0]      c_addr_reg,
	output reg  [EXT_ADDR_W-1:0]      m_addr_reg,
	output reg  [31:0]                shell_mode_reg,
	output reg  [31:0]                ingress_kind_reg,
	output reg  [31:0]                ingress_ctrl_id_reg,
	output reg  [31:0]                ingress_tile_info0_reg,
	output reg  [31:0]                ingress_tile_info1_reg,
	output reg  [31:0]                ingress_word_count_reg
);

	localparam [7:0] ADDR_CTRL        = 8'h00;
	localparam [7:0] ADDR_STATUS      = 8'h04;
	localparam [7:0] ADDR_CMD_INST    = 8'h08;
	localparam [7:0] ADDR_CMD_ID      = 8'h0C;
	localparam [7:0] ADDR_A_ADDR_LO   = 8'h10;
	localparam [7:0] ADDR_A_ADDR_HI   = 8'h14;
	localparam [7:0] ADDR_B_ADDR_LO   = 8'h18;
	localparam [7:0] ADDR_B_ADDR_HI   = 8'h1C;
	localparam [7:0] ADDR_C_ADDR_LO   = 8'h20;
	localparam [7:0] ADDR_C_ADDR_HI   = 8'h24;
	localparam [7:0] ADDR_M_ADDR_LO   = 8'h28;
	localparam [7:0] ADDR_M_ADDR_HI   = 8'h2C;
	localparam [7:0] ADDR_RESP_HEAD   = 8'h30;
	localparam [7:0] ADDR_DESC_STREAM = 8'h38;
	localparam [7:0] ADDR_SHELL_MODE  = 8'h80;
	localparam [7:0] ADDR_INGRESS_KIND = 8'h84;
	localparam [7:0] ADDR_INGRESS_CTRL_ID = 8'h88;
	localparam [7:0] ADDR_INGRESS_TILE_INFO0 = 8'h8C;
	localparam [7:0] ADDR_INGRESS_TILE_INFO1 = 8'h90;
	localparam [7:0] ADDR_INGRESS_WORD_COUNT = 8'h94;
	localparam [7:0] ADDR_INGRESS_PUSH = 8'h98;
	localparam [7:0] ADDR_SHELL_STATUS = 8'h9C;
	localparam [7:0] ADDR_OUT_META_HEAD0 = 8'hA0;
	localparam [7:0] ADDR_OUT_META_HEAD1 = 8'hA4;
	localparam [7:0] ADDR_OUT_META_HEAD2 = 8'hA8;
	localparam [7:0] ADDR_OUT_META_POP  = 8'hAC;

	localparam [1:0] RESP_OKAY = 2'b00;
	localparam [2:0] DESC_STREAM_WORDS = 3'd6;

	reg                      axi_awready_r;
	reg                      axi_wready_r;
	reg                      axi_bvalid_r;
	reg                      axi_arready_r;
	reg                      axi_rvalid_r;
	reg  [AXIL_ADDR_W-1:0]   rd_addr_r;
	reg  [2:0]               desc_stream_idx_r;

	wire write_fire = axi_awready_r && s_axil_awvalid && axi_wready_r && s_axil_wvalid;

	assign s_axil_awready = axi_awready_r;
	assign s_axil_wready  = axi_wready_r;
	assign s_axil_bresp   = RESP_OKAY;
	assign s_axil_bvalid  = axi_bvalid_r;
	assign s_axil_arready = axi_arready_r;
	assign s_axil_rresp   = RESP_OKAY;
	assign s_axil_rvalid  = axi_rvalid_r;

	function [31:0] apply_wstrb32;
		input [31:0] curr;
		input [31:0] wdata;
		input [3:0]  wstrb;
		integer bi;
		begin
			apply_wstrb32 = curr;
			for (bi = 0; bi < 4; bi = bi + 1) begin
				if (wstrb[bi]) begin
					apply_wstrb32[(bi * 8) +: 8] = wdata[(bi * 8) +: 8];
				end
			end
		end
	endfunction

	function [31:0] addr_lo_word;
		input [EXT_ADDR_W-1:0] addr;
		integer bit_idx;
		begin
			addr_lo_word = 32'd0;
			for (bit_idx = 0; (bit_idx < EXT_ADDR_W) && (bit_idx < 32); bit_idx = bit_idx + 1) begin
				addr_lo_word[bit_idx] = addr[bit_idx];
			end
		end
	endfunction

	function [31:0] addr_hi_word;
		input [EXT_ADDR_W-1:0] addr;
		integer bit_idx;
		begin
			addr_hi_word = 32'd0;
			for (bit_idx = 32; (bit_idx < EXT_ADDR_W) && (bit_idx < 64); bit_idx = bit_idx + 1) begin
				addr_hi_word[bit_idx - 32] = addr[bit_idx];
			end
		end
	endfunction

	function [EXT_ADDR_W-1:0] merge_addr_lo;
		input [EXT_ADDR_W-1:0] curr;
		input [31:0]          low_word;
		integer bit_idx;
		begin
			merge_addr_lo = curr;
			for (bit_idx = 0; (bit_idx < EXT_ADDR_W) && (bit_idx < 32); bit_idx = bit_idx + 1) begin
				merge_addr_lo[bit_idx] = low_word[bit_idx];
			end
		end
	endfunction

	function [EXT_ADDR_W-1:0] merge_addr_hi;
		input [EXT_ADDR_W-1:0] curr;
		input [31:0]          hi_word;
		integer bit_idx;
		begin
			merge_addr_hi = curr;
			for (bit_idx = 32; (bit_idx < EXT_ADDR_W) && (bit_idx < 64); bit_idx = bit_idx + 1) begin
				merge_addr_hi[bit_idx] = hi_word[bit_idx - 32];
			end
		end
	endfunction

	reg [31:0] read_data_r;
	assign s_axil_rdata = read_data_r;

	always @(*) begin
		case (rd_addr_r[7:0])
			ADDR_STATUS: begin
				read_data_r = {
					28'd0,
					status_cmd_busy,
					status_irq_active,
					status_resp_not_empty,
					status_cmd_slot_ready
				};
			end
			ADDR_CMD_INST: read_data_r = cmd_inst_reg;
			ADDR_CMD_ID: read_data_r = cmd_id_reg;
			ADDR_A_ADDR_LO: read_data_r = addr_lo_word(a_addr_reg);
			ADDR_A_ADDR_HI: read_data_r = addr_hi_word(a_addr_reg);
			ADDR_B_ADDR_LO: read_data_r = addr_lo_word(b_addr_reg);
			ADDR_B_ADDR_HI: read_data_r = addr_hi_word(b_addr_reg);
			ADDR_C_ADDR_LO: read_data_r = addr_lo_word(c_addr_reg);
			ADDR_C_ADDR_HI: read_data_r = addr_hi_word(c_addr_reg);
			ADDR_M_ADDR_LO: read_data_r = addr_lo_word(m_addr_reg);
			ADDR_M_ADDR_HI: read_data_r = addr_hi_word(m_addr_reg);
			ADDR_RESP_HEAD: read_data_r = resp_head;
			ADDR_SHELL_MODE: read_data_r = shell_mode_reg;
			ADDR_INGRESS_KIND: read_data_r = ingress_kind_reg;
			ADDR_INGRESS_CTRL_ID: read_data_r = ingress_ctrl_id_reg;
			ADDR_INGRESS_TILE_INFO0: read_data_r = ingress_tile_info0_reg;
			ADDR_INGRESS_TILE_INFO1: read_data_r = ingress_tile_info1_reg;
			ADDR_INGRESS_WORD_COUNT: read_data_r = ingress_word_count_reg;
			ADDR_SHELL_STATUS: read_data_r = shell_status_word;
			ADDR_OUT_META_HEAD0: read_data_r = out_meta_head0;
			ADDR_OUT_META_HEAD1: read_data_r = out_meta_head1;
			ADDR_OUT_META_HEAD2: read_data_r = out_meta_head2;
			default: read_data_r = 32'd0;
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			axi_awready_r <= 1'b0;
			axi_wready_r <= 1'b0;
			axi_bvalid_r <= 1'b0;
			axi_arready_r <= 1'b0;
			axi_rvalid_r <= 1'b0;
			rd_addr_r <= {AXIL_ADDR_W{1'b0}};
			desc_stream_idx_r <= 3'd0;
			desc_push_pulse <= 1'b0;
			resp_pop_pulse <= 1'b0;
			soft_clear_pulse <= 1'b0;
			clear_flags_pulse <= 1'b0;
			ingress_push_pulse <= 1'b0;
			out_meta_pop_pulse <= 1'b0;
			cmd_inst_reg <= 32'd0;
			cmd_id_reg <= 32'd0;
			a_addr_reg <= {EXT_ADDR_W{1'b0}};
			b_addr_reg <= {EXT_ADDR_W{1'b0}};
			c_addr_reg <= {EXT_ADDR_W{1'b0}};
			m_addr_reg <= {EXT_ADDR_W{1'b0}};
			shell_mode_reg <= 32'd0;
			ingress_kind_reg <= 32'd0;
			ingress_ctrl_id_reg <= 32'd0;
			ingress_tile_info0_reg <= 32'd0;
			ingress_tile_info1_reg <= 32'd0;
			ingress_word_count_reg <= 32'd0;
		end else if (clear) begin
			axi_awready_r <= 1'b0;
			axi_wready_r <= 1'b0;
			axi_bvalid_r <= 1'b0;
			axi_arready_r <= 1'b0;
			axi_rvalid_r <= 1'b0;
			rd_addr_r <= {AXIL_ADDR_W{1'b0}};
			desc_stream_idx_r <= 3'd0;
			desc_push_pulse <= 1'b0;
			resp_pop_pulse <= 1'b0;
			soft_clear_pulse <= 1'b0;
			clear_flags_pulse <= 1'b0;
			ingress_push_pulse <= 1'b0;
			out_meta_pop_pulse <= 1'b0;
			cmd_inst_reg <= 32'd0;
			cmd_id_reg <= 32'd0;
			a_addr_reg <= {EXT_ADDR_W{1'b0}};
			b_addr_reg <= {EXT_ADDR_W{1'b0}};
			c_addr_reg <= {EXT_ADDR_W{1'b0}};
			m_addr_reg <= {EXT_ADDR_W{1'b0}};
			shell_mode_reg <= 32'd0;
			ingress_kind_reg <= 32'd0;
			ingress_ctrl_id_reg <= 32'd0;
			ingress_tile_info0_reg <= 32'd0;
			ingress_tile_info1_reg <= 32'd0;
			ingress_word_count_reg <= 32'd0;
		end else begin
			desc_push_pulse <= 1'b0;
			resp_pop_pulse <= 1'b0;
			soft_clear_pulse <= 1'b0;
			clear_flags_pulse <= 1'b0;
			ingress_push_pulse <= 1'b0;
			out_meta_pop_pulse <= 1'b0;

			if (s_axil_awvalid && s_axil_wvalid && !axi_bvalid_r) begin
				axi_awready_r <= 1'b1;
				axi_wready_r  <= 1'b1;
			end else begin
				axi_awready_r <= 1'b0;
				axi_wready_r  <= 1'b0;
			end

			if (write_fire) begin
				case (s_axil_awaddr[7:0])
					ADDR_CTRL: begin
						desc_push_pulse   <= s_axil_wstrb[0] && s_axil_wdata[0];
						resp_pop_pulse    <= s_axil_wstrb[0] && s_axil_wdata[1];
						soft_clear_pulse  <= s_axil_wstrb[0] && s_axil_wdata[2];
						clear_flags_pulse <= s_axil_wstrb[0] && s_axil_wdata[3];
					end
					ADDR_CMD_INST: cmd_inst_reg <= apply_wstrb32(cmd_inst_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_CMD_ID: cmd_id_reg <= apply_wstrb32(cmd_id_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_A_ADDR_LO: a_addr_reg <= merge_addr_lo(a_addr_reg, apply_wstrb32(addr_lo_word(a_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_A_ADDR_HI: a_addr_reg <= merge_addr_hi(a_addr_reg, apply_wstrb32(addr_hi_word(a_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_B_ADDR_LO: b_addr_reg <= merge_addr_lo(b_addr_reg, apply_wstrb32(addr_lo_word(b_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_B_ADDR_HI: b_addr_reg <= merge_addr_hi(b_addr_reg, apply_wstrb32(addr_hi_word(b_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_C_ADDR_LO: c_addr_reg <= merge_addr_lo(c_addr_reg, apply_wstrb32(addr_lo_word(c_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_C_ADDR_HI: c_addr_reg <= merge_addr_hi(c_addr_reg, apply_wstrb32(addr_hi_word(c_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_M_ADDR_LO: m_addr_reg <= merge_addr_lo(m_addr_reg, apply_wstrb32(addr_lo_word(m_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_M_ADDR_HI: m_addr_reg <= merge_addr_hi(m_addr_reg, apply_wstrb32(addr_hi_word(m_addr_reg), s_axil_wdata, s_axil_wstrb));
					ADDR_DESC_STREAM: begin
						case (desc_stream_idx_r)
							3'd0: cmd_inst_reg <= apply_wstrb32(cmd_inst_reg, s_axil_wdata, s_axil_wstrb);
							3'd1: cmd_id_reg <= apply_wstrb32(cmd_id_reg, s_axil_wdata, s_axil_wstrb);
							3'd2: a_addr_reg <= merge_addr_lo({EXT_ADDR_W{1'b0}}, apply_wstrb32(32'd0, s_axil_wdata, s_axil_wstrb));
							3'd3: b_addr_reg <= merge_addr_lo({EXT_ADDR_W{1'b0}}, apply_wstrb32(32'd0, s_axil_wdata, s_axil_wstrb));
							3'd4: c_addr_reg <= merge_addr_lo({EXT_ADDR_W{1'b0}}, apply_wstrb32(32'd0, s_axil_wdata, s_axil_wstrb));
							3'd5: begin
								m_addr_reg <= merge_addr_lo({EXT_ADDR_W{1'b0}}, apply_wstrb32(32'd0, s_axil_wdata, s_axil_wstrb));
								desc_push_pulse <= 1'b1;
							end
						endcase
						if (desc_stream_idx_r == (DESC_STREAM_WORDS - 1'b1)) begin
							desc_stream_idx_r <= 3'd0;
						end else begin
							desc_stream_idx_r <= desc_stream_idx_r + 1'b1;
						end
					end
					ADDR_SHELL_MODE: shell_mode_reg <= apply_wstrb32(shell_mode_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_INGRESS_KIND: ingress_kind_reg <= apply_wstrb32(ingress_kind_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_INGRESS_CTRL_ID: ingress_ctrl_id_reg <= apply_wstrb32(ingress_ctrl_id_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_INGRESS_TILE_INFO0: ingress_tile_info0_reg <= apply_wstrb32(ingress_tile_info0_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_INGRESS_TILE_INFO1: ingress_tile_info1_reg <= apply_wstrb32(ingress_tile_info1_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_INGRESS_WORD_COUNT: ingress_word_count_reg <= apply_wstrb32(ingress_word_count_reg, s_axil_wdata, s_axil_wstrb);
					ADDR_INGRESS_PUSH: ingress_push_pulse <= s_axil_wstrb[0] && s_axil_wdata[0];
					ADDR_OUT_META_POP: out_meta_pop_pulse <= s_axil_wstrb[0] && s_axil_wdata[0];
				endcase
				axi_bvalid_r <= 1'b1;
			end else if (axi_bvalid_r && s_axil_bready) begin
				axi_bvalid_r <= 1'b0;
			end

			if (!axi_rvalid_r) begin
				axi_arready_r <= 1'b1;
				if (s_axil_arvalid) begin
					axi_arready_r <= 1'b0;
					axi_rvalid_r <= 1'b1;
					rd_addr_r <= s_axil_araddr;
				end
			end else begin
				axi_arready_r <= 1'b0;
				if (s_axil_rready) begin
					axi_rvalid_r <= 1'b0;
				end
			end
		end
	end

endmodule
