module sync_fifo #(
	parameter WIDTH = 32,
	parameter DEPTH = 4
) (
	input  wire             clk      ,
	input  wire             resetn   ,
	input  wire             clear    , // Optional soft reset for FIFO contents
	input  wire [WIDTH-1:0] data_in  ,
	input  wire             valid_in ,
	output wire             ready_in ,
	output wire [WIDTH-1:0] data_out ,
	output wire             valid_out,
	input  wire             ready_out
);

	localparam integer PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
	localparam integer CNT_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH+1);

	localparam [PTR_W-1:0] LAST_PTR = DEPTH - 1;

	reg [          WIDTH-1:0] fifo [0:DEPTH-1];
	reg [          PTR_W-1:0] head            ;
	reg [          PTR_W-1:0] tail            ;
	reg [          CNT_W-1:0] count           ;

	wire                     do_write ;
	wire                     do_read  ;
	wire [PTR_W-1:0]         head_next;
	wire [PTR_W-1:0]         tail_next;

	assign ready_in  = (count < DEPTH);
	assign valid_out = (count > 0);
	assign data_out  = valid_out ? fifo[head] : {WIDTH{1'b0}};

	assign do_write  = valid_in && ready_in;
	assign do_read   = valid_out && ready_out;
	assign head_next = (head == LAST_PTR) ? {PTR_W{1'b0}} : (head + 1'b1);
	assign tail_next = (tail == LAST_PTR) ? {PTR_W{1'b0}} : (tail + 1'b1);

	// Keep async reset semantics only on the FIFO control state. The data
	// storage itself is not reset; flushing the FIFO is fully handled by the
	// control pointers/count.
	always @(posedge clk or negedge resetn) begin
		if (!resetn) begin
			head  <= {PTR_W{1'b0}};
			tail  <= {PTR_W{1'b0}};
			count <= {CNT_W{1'b0}};
		end else if (clear) begin
			head  <= {PTR_W{1'b0}};
			tail  <= {PTR_W{1'b0}};
			count <= {CNT_W{1'b0}};
		end else begin
			if (do_read) begin
				head <= head_next;
			end
			if (do_write) begin
				tail <= tail_next;
			end

			case ({do_write, do_read})
				2'b10   : count <= count + 1'b1;
				2'b01   : count <= count - 1'b1;
				default : count <= count;
			endcase
		end
	end

	always @(posedge clk) begin
		if (!clear && do_write) begin
			fifo[tail] <= data_in;
		end
	end

endmodule
