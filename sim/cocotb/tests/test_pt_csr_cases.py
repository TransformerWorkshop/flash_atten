from __future__ import annotations

import os

import cocotb

from tests.pt_blackbox_env import create_env
from tests.pt_model import PT_CFG_A_BASE_HI, PT_CFG_A_BASE_LO, PT_CFG_B_BASE_HI, PT_CFG_B_BASE_LO


CSR_PATTERNS = [
	0x0000,
	*[1 << bit for bit in range(16)],
	0x0003,
	0x0101,
	0x1111,
	0xAAAA,
	0x5555,
	0xFFFF,
]


@cocotb.test()
async def test_pt_csr_base_selector_pattern_sweep(dut) -> None:
	env = await create_env(dut)
	try:
		ctrl_id = 0xA00
		reuse_ctrl_id = os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP"
		for selector in (PT_CFG_A_BASE_LO, PT_CFG_A_BASE_HI, PT_CFG_B_BASE_LO, PT_CFG_B_BASE_HI):
			for value in CSR_PATTERNS:
				await env.cfg_selector16(selector, value, ctrl_id)
				if not reuse_ctrl_id:
					ctrl_id += 1
				actual_a, actual_b = env.read_csr_bases()
				assert actual_a == env.a_base_shadow, f"A base shadow mismatch exp=0x{env.a_base_shadow:08x} got=0x{actual_a:08x}"
				assert actual_b == env.b_base_shadow, f"B base shadow mismatch exp=0x{env.b_base_shadow:08x} got=0x{actual_b:08x}"
	finally:
		env.shutdown()
