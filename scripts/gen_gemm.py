#!/usr/bin/env python3
"""Generate a parameterized GEMM wrapper module.

The generated module instantiates X_DIM * Y_DIM GEMU processing elements.
Each row shares one A input stream and each column shares one B input stream.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def build_gemm_verilog(width: int, x_dim: int, y_dim: int, module_name: str = "GEMM") -> str:
	lines: list[str] = []

	lines.append("module {} #( ".format(module_name))
	lines.append("    parameter WIDTH = {} ,".format(width))
	lines.append("    parameter X_DIM = {} ,".format(x_dim))
	lines.append("    parameter Y_DIM = {}".format(y_dim))
	lines.append(") (")
	lines.append("    input  wire                        clk     ,")
	lines.append("    input  wire                        rstn    ,")
	lines.append("    input  wire [X_DIM*WIDTH-1:0]      a       ,")
	lines.append("    input  wire [X_DIM-1:0]            a_valid ,")
	lines.append("    output wire [X_DIM-1:0]            a_ready ,")
	lines.append("    input  wire [Y_DIM*WIDTH-1:0]      b       ,")
	lines.append("    input  wire [Y_DIM-1:0]            b_valid ,")
	lines.append("    output wire [Y_DIM-1:0]            b_ready ,")
	lines.append("    output wire [X_DIM*Y_DIM*4*WIDTH-1:0] m       ,")
	lines.append("    output wire [X_DIM*Y_DIM-1:0]      m_valid ,")
	lines.append("    input  wire [X_DIM*Y_DIM-1:0]      m_ready ,")
	lines.append("    input  wire                        start   ,")
	lines.append("    input  wire                        clear   ,")
	lines.append("    input  wire [WIDTH-1:0]            num_acc")
	lines.append(");")
	lines.append("")
	for i in range(x_dim):
		for j in range(y_dim):
			pe_idx = i * y_dim + j
			lines.append("    GEMU #(")
			lines.append("        .WIDTH(WIDTH)")
			lines.append("    ) gemu_x{}_y{} (".format(i, j))
			lines.append("        .clk    (clk                         ),")
			lines.append("        .rstn   (rstn                        ),")
			lines.append("        .a      (a[{}:{}]                    ),".format((i + 1) * width - 1, i * width))
			lines.append("        .a_valid(a_valid[{}]                 ),".format(i))
			lines.append("        .a_ready(a_ready[{}]                 ),".format(i))
			lines.append("        .b      (b[{}:{}]                    ),".format((j + 1) * width - 1, j * width))
			lines.append("        .b_valid(b_valid[{}]                 ),".format(j))
			lines.append("        .b_ready(b_ready[{}]                 ),".format(j))
			lines.append("        .m      (m[{}:{}]                    ),".format((pe_idx + 1) * 4 * width - 1, pe_idx * 4 * width))
			lines.append("        .m_valid(m_valid[{}]                 ),".format(pe_idx))
			lines.append("        .m_ready(m_ready[{}]                 ),".format(pe_idx))
			lines.append("        .start  (start                       ),")
			lines.append("        .clear  (clear                       ),")
			lines.append("        .num_acc(num_acc                     )")
			lines.append("    );")
			lines.append("")
	lines.append("endmodule")

	return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="Generate parameterized GEMM Verilog")
	parser.add_argument("--width", type=int, default=32, help="Data width (default: 32)")
	parser.add_argument("--x-dim", type=int, default=4, help="X dimension (default: 4)")
	parser.add_argument("--y-dim", type=int, default=4, help="Y dimension (default: 4)")
	parser.add_argument("--module-name", default="GEMM", help="Output module name (default: GEMM)")
	parser.add_argument(
		"--out",
		type=Path,
		default=Path("rtl/gemm.v"),
		help="Output Verilog path (default: rtl/gemm.v)",
	)
	return parser.parse_args()


def validate_positive(name: str, value: int) -> None:
	if value <= 0:
		raise ValueError(f"{name} must be > 0, got {value}")


def main() -> None:
	args = parse_args()

	validate_positive("width", args.width)
	validate_positive("x_dim", args.x_dim)
	validate_positive("y_dim", args.y_dim)

	verilog = build_gemm_verilog(
		width=args.width,
		x_dim=args.x_dim,
		y_dim=args.y_dim,
		module_name=args.module_name,
	)

	args.out.parent.mkdir(parents=True, exist_ok=True)
	args.out.write_text(verilog, encoding="utf-8")
	print(f"Generated {args.module_name} to {args.out}")


if __name__ == "__main__":
	main()
