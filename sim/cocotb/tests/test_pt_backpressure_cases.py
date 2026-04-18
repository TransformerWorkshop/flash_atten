from __future__ import annotations

import os

import cocotb
from cocotb.triggers import RisingEdge

from tests.pt_blackbox_env import SequencePattern, create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_SCALE_FULL, build_matadd_inst, build_matmul_inst, build_mwin_off


def _is_dma_top() -> bool:
	return os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP"


async def _wait_ctrl_resp_allow_any_success_buffer(env, ctrl_id: int, timeout_cycles: int = 4000) -> int:
	for _ in range(timeout_cycles):
		if env.ctrl_resp_queue:
			actual = env.ctrl_resp_queue.popleft()
			assert (actual & 0xBFFF_FFFF) == ctrl_id, f"ctrl_resp mismatch exp_id=0x{ctrl_id:08x} got=0x{actual:08x}"
			await env.pop_resp()
			return actual
		await RisingEdge(env.dut.clk)
	raise AssertionError(f"ctrl_resp timeout waiting for ctrl_id=0x{ctrl_id:08x}")


@cocotb.test()
async def test_pt_backpressure_matmul_and_matadd_chain(dut) -> None:
	if _is_dma_top():
		return
	env = await create_env(dut)
	try:
		env.configure_patterns(
			dma_req_ready=SequencePattern([0, 1, 1, 0, 1, 1, 1]),
			m_dma_req_ready=SequencePattern([1, 0, 1, 1, 0, 1, 1]),
			m_axis_ready=SequencePattern([1, 1, 0, 1, 0, 1, 1]),
			s_axis_valid=SequencePattern([0, 1, 1, 0, 1, 1, 1]),
		)
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x401
		env.register_external_matrix("A", ctrl_id, flatten_pattern_matrix(env.x_dim, 4, 1, 0))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 3, 1))
		env.register_external_matrix("C", ctrl_id, flatten_pattern_matrix(env.y_dim, 1, 2, 3))

		matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		resp = await env.wait_ctrl_resp(matmul.response_word)
		env.model.commit_success(matmul)

		m_off = build_mwin_off((resp >> 30) & 0x1, 0)
		matadd = env.plan_matadd(ctrl_id, m_off)
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
		if _is_dma_top():
			await _wait_ctrl_resp_allow_any_success_buffer(env, ctrl_id)
		else:
			await env.wait_ctrl_resp(matadd.response_word)
		env.model.commit_success(matadd)

		await env.wait_export_done(2, 12000)
		assert env.export_req_count == 2
		assert env.irq_count == 2
	finally:
		env.shutdown()
