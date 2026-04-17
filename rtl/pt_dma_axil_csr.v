module PT_DMA_AXIL_CSR #(
	parameter EXT_ADDR_W = 32,
	parameter AXIL_ADDR_W = 8,
	parameter AXIL_DATA_W = 32,
	parameter CMD_FIFO_DEPTH = 4,
	parameter RESP_FIFO_DEPTH = 4
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
	input  wire                       status_cmd_fifo_not_full,
	input  wire                       status_resp_fifo_not_empty,
	input  wire                       status_irq_active,
	input  wire                       status_pt_ctrl_ready,
	input  wire                       status_cmd_overflow,
	input  wire                       status_desc_overflow,
	input  wire                       status_resp_overflow,
	input  wire                       status_desc_miss,
	input  wire [31:0]                resp_head,
	output reg                        desc_push_pulse,
	output reg                        resp_pop_pulse,
	output reg                        soft_clear_pulse,
	output reg                        clear_flags_pulse,
	output reg  [31:0]                cmd_inst_reg,
	output reg  [31:0]                cmd_id_reg,
	output reg  [EXT_ADDR_W-1:0]      a_addr_reg,
	output reg  [EXT_ADDR_W-1:0]      b_addr_reg,
	output reg  [EXT_ADDR_W-1:0]      c_addr_reg,
	output reg  [EXT_ADDR_W-1:0]      m_addr_reg
);

	localparam [7:0] ADDR_CTRL      = 8'h00;
	localparam [7:0] ADDR_STATUS    = 8'h04;
	localparam [7:0] ADDR_CMD_INST  = 8'h08;
	localparam [7:0] ADDR_CMD_ID    = 8'h0C;
	localparam [7:0] ADDR_A_ADDR_LO = 8'h10;
	localparam [7:0] ADDR_A_ADDR_HI = 8'h14;
	localparam [7:0] ADDR_B_ADDR_LO = 8'h18;
	localparam [7:0] ADDR_B_ADDR_HI = 8'h1C;
	localparam [7:0] ADDR_C_ADDR_LO = 8'h20;
	localparam [7:0] ADDR_C_ADDR_HI = 8'h24;
	localparam [7:0] ADDR_M_ADDR_LO = 8'h28;
	localparam [7:0] ADDR_M_ADDR_HI = 8'h2C;
	localparam [7:0] ADDR_RESP_HEAD = 8'h30;
	localparam [7:0] ADDR_INFO      = 8'h34;

	localparam [1:0] RESP_OKAY = 2'b00;
	localparam [7:0] CMD_FIFO_DEPTH_U8 = CMD_FIFO_DEPTH;
	localparam [7:0] RESP_FIFO_DEPTH_U8 = RESP_FIFO_DEPTH;
	localparam [31:0] INFO_WORD = {8'd1, 8'd0, CMD_FIFO_DEPTH_U8, RESP_FIFO_DEPTH_U8};

	reg                      axi_awready_r;
	reg                      axi_wready_r;
	reg                      axi_bvalid_r;
	reg                      axi_arready_r;
	reg                      axi_rvalid_r;
	reg  [AXIL_ADDR_W-1:0]   rd_addr_r;

	wire write_fire = axi_awready_r && s_axil_awvalid && axi_wready_r && s_axil_wvalid;
	wire read_fire = axi_arready_r && s_axil_arvalid;

	assign s_axil_awready = axi_awready_r;
	assign s_axil_wready = axi_wready_r;
	assign s_axil_bresp = RESP_OKAY;
	assign s_axil_bvalid = axi_bvalid_r;
	assign s_axil_arready = axi_arready_r;
	assign s_axil_rresp = RESP_OKAY;
	assign s_axil_rvalid = axi_rvalid_r;

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
					24'd0,
					status_desc_miss,
					status_resp_overflow,
					status_desc_overflow,
					status_cmd_overflow,
					status_pt_ctrl_ready,
					status_irq_active,
					status_resp_fifo_not_empty,
					status_cmd_fifo_not_full
				};
			end
			ADDR_CMD_INST:  read_data_r = cmd_inst_reg;
			ADDR_CMD_ID:    read_data_r = cmd_id_reg;
			ADDR_A_ADDR_LO: read_data_r = addr_lo_word(a_addr_reg);
			ADDR_A_ADDR_HI: read_data_r = addr_hi_word(a_addr_reg);
			ADDR_B_ADDR_LO: read_data_r = addr_lo_word(b_addr_reg);
			ADDR_B_ADDR_HI: read_data_r = addr_hi_word(b_addr_reg);
			ADDR_C_ADDR_LO: read_data_r = addr_lo_word(c_addr_reg);
			ADDR_C_ADDR_HI: read_data_r = addr_hi_word(c_addr_reg);
			ADDR_M_ADDR_LO: read_data_r = addr_lo_word(m_addr_reg);
			ADDR_M_ADDR_HI: read_data_r = addr_hi_word(m_addr_reg);
			ADDR_RESP_HEAD: read_data_r = resp_head;
			ADDR_INFO:      read_data_r = INFO_WORD;
			default:        read_data_r = 32'd0;
		endcase
	end

	initial begin
		if (AXIL_DATA_W != 32) begin
			$fatal(1, "PT_DMA_AXIL_CSR requires AXIL_DATA_W=32, got %0d", AXIL_DATA_W);
		end
		if (EXT_ADDR_W > 64) begin
			$fatal(1, "PT_DMA_AXIL_CSR supports EXT_ADDR_W <= 64, got %0d", EXT_ADDR_W);
		end
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			axi_awready_r     <= 1'b0;
			axi_wready_r      <= 1'b0;
			axi_bvalid_r      <= 1'b0;
			axi_arready_r     <= 1'b0;
			axi_rvalid_r      <= 1'b0;
			rd_addr_r         <= {AXIL_ADDR_W{1'b0}};
			desc_push_pulse   <= 1'b0;
			resp_pop_pulse    <= 1'b0;
			soft_clear_pulse  <= 1'b0;
			clear_flags_pulse <= 1'b0;
			cmd_inst_reg      <= 32'd0;
			cmd_id_reg        <= 32'd0;
			a_addr_reg        <= {EXT_ADDR_W{1'b0}};
			b_addr_reg        <= {EXT_ADDR_W{1'b0}};
			c_addr_reg        <= {EXT_ADDR_W{1'b0}};
			m_addr_reg        <= {EXT_ADDR_W{1'b0}};
		end else if (clear) begin
			axi_awready_r     <= 1'b0;
			axi_wready_r      <= 1'b0;
			axi_bvalid_r      <= 1'b0;
			axi_arready_r     <= 1'b0;
			axi_rvalid_r      <= 1'b0;
			rd_addr_r         <= {AXIL_ADDR_W{1'b0}};
			desc_push_pulse   <= 1'b0;
			resp_pop_pulse    <= 1'b0;
			soft_clear_pulse  <= 1'b0;
			clear_flags_pulse <= 1'b0;
			cmd_inst_reg      <= 32'd0;
			cmd_id_reg        <= 32'd0;
			a_addr_reg        <= {EXT_ADDR_W{1'b0}};
			b_addr_reg        <= {EXT_ADDR_W{1'b0}};
			c_addr_reg        <= {EXT_ADDR_W{1'b0}};
			m_addr_reg        <= {EXT_ADDR_W{1'b0}};
		end else begin
			desc_push_pulse   <= 1'b0;
			resp_pop_pulse    <= 1'b0;
			soft_clear_pulse  <= 1'b0;
			clear_flags_pulse <= 1'b0;

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
					ADDR_CMD_INST: begin
						cmd_inst_reg <= apply_wstrb32(cmd_inst_reg, s_axil_wdata, s_axil_wstrb);
					end
					ADDR_CMD_ID: begin
						cmd_id_reg <= apply_wstrb32(cmd_id_reg, s_axil_wdata, s_axil_wstrb);
					end
					ADDR_A_ADDR_LO: begin
						a_addr_reg <= merge_addr_lo(a_addr_reg, apply_wstrb32(addr_lo_word(a_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_A_ADDR_HI: begin
						a_addr_reg <= merge_addr_hi(a_addr_reg, apply_wstrb32(addr_hi_word(a_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_B_ADDR_LO: begin
						b_addr_reg <= merge_addr_lo(b_addr_reg, apply_wstrb32(addr_lo_word(b_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_B_ADDR_HI: begin
						b_addr_reg <= merge_addr_hi(b_addr_reg, apply_wstrb32(addr_hi_word(b_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_C_ADDR_LO: begin
						c_addr_reg <= merge_addr_lo(c_addr_reg, apply_wstrb32(addr_lo_word(c_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_C_ADDR_HI: begin
						c_addr_reg <= merge_addr_hi(c_addr_reg, apply_wstrb32(addr_hi_word(c_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_M_ADDR_LO: begin
						m_addr_reg <= merge_addr_lo(m_addr_reg, apply_wstrb32(addr_lo_word(m_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					ADDR_M_ADDR_HI: begin
						m_addr_reg <= merge_addr_hi(m_addr_reg, apply_wstrb32(addr_hi_word(m_addr_reg), s_axil_wdata, s_axil_wstrb));
					end
					default: begin
					end
				endcase
				axi_bvalid_r <= 1'b1;
			end else if (axi_bvalid_r && s_axil_bready) begin
				axi_bvalid_r <= 1'b0;
			end

			if (!axi_rvalid_r) begin
				axi_arready_r <= 1'b1;
				if (read_fire) begin
					axi_arready_r <= 1'b0;
					axi_rvalid_r  <= 1'b1;
					rd_addr_r     <= s_axil_araddr;
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
