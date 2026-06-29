/* verilator lint_off UNDRIVEN */
module TEM5N28HPCPLVTA64X32M4SWSO (
	input  wire        SLP,
	input  wire        SD,
	input  wire [5:0]  A,
	input  wire [31:0] D,
	input  wire [31:0] BWEB,
	output wire [31:0] Q,
	input  wire        WEB,
	input  wire        CEB,
	input  wire        CLK
);
endmodule

module TEM5N28HPCPLVTA64X64M4SWSO (
	input  wire        SLP,
	input  wire        SD,
	input  wire [5:0]  A,
	input  wire [63:0] D,
	input  wire [63:0] BWEB,
	output wire [63:0] Q,
	input  wire        WEB,
	input  wire        CEB,
	input  wire        CLK
);
endmodule

module TEM5N28HPCPLVTA256X32M4SWSO (
	input  wire        SLP,
	input  wire        SD,
	input  wire [7:0]  A,
	input  wire [31:0] D,
	input  wire [31:0] BWEB,
	output wire [31:0] Q,
	input  wire        WEB,
	input  wire        CEB,
	input  wire        CLK
);
endmodule

module TEM5N28HPCPLVTA256X64M4SWSO (
	input  wire        SLP,
	input  wire        SD,
	input  wire [7:0]  A,
	input  wire [63:0] D,
	input  wire [63:0] BWEB,
	output wire [63:0] Q,
	input  wire        WEB,
	input  wire        CEB,
	input  wire        CLK
);
endmodule
/* verilator lint_on UNDRIVEN */
