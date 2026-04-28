from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_dma_top_env import (
	ADDR_A_ADDR_LO,
	ADDR_CMD_INST,
	ADDR_STATUS,
	AbInjection,
	ConstantPattern,
	STATUS_CMD_OVERFLOW,
	STATUS_DESC_MISS,
	STATUS_DESC_OVERFLOW,
	STATUS_IRQ_ACTIVE,
	STATUS_RESP_FIFO_NOT_EMPTY,
	STATUS_RESP_OVERFLOW,
	STATUS_STREAM_ALIGN_ERROR,
	create_env,
	setup_bases_and_passthrough_qcfg,
)
from tests.pt_model import (
	DMA_KIND_A,
	DMA_KIND_B,
	DMA_KIND_C,
	PT_SCALE_FULL,
	PT_TILES_1,
	PT_TILES_2,
	build_cfg_inst,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	identity_matrix,
	pack_resp,
)


def flatten_pattern_matrix(dim: int, row_gain: int, col_gain: int, bias: int) -> list[int]:
	values: list[int] = []
	for row in range(dim):
		for col in range(dim):
			values.append(((row + 1) * row_gain) + ((col + 1) * col_gain) + bias)
	return values


def repeating_matrix(dim: int, values: list[int]) -> list[int]:
	return [values[idx % len(values)] for idx in range(dim * dim)]


def make_multitile_a_matrix(x_dim: int, m_tiles: int, k_tiles: int) -> list[int]:
	m_dim = x_dim * m_tiles
	k_dim = x_dim * k_tiles
	return [
		((row * 3) + (col % x_dim) + (row // x_dim) * 5 + (col // x_dim) * 7 + 1)
		for row in range(m_dim)
		for col in range(k_dim)
	]


def make_multitile_b_matrix(y_dim: int, k_tiles: int, n_tiles: int) -> list[int]:
	k_dim = y_dim * k_tiles
	n_dim = y_dim * n_tiles
	return [
		((col * 2) + (row % y_dim) + (col // y_dim) * 4 + (row // y_dim) * 6 + 1)
		for row in range(k_dim)
		for col in range(n_dim)
	]


def _is_v3_wrapper(env) -> bool:
	return env._pt_root_prefix().endswith("u_pt_v3")


@cocotb.test()
async def test_pt_dma_top_axil_staggered_write_and_resp_pop(dut) -> None:
	env = await create_env(dut)
	try:
		await env.axil_write(ADDR_CMD_INST, 0x1234_5678, write_delay_cycles=2)
		assert await env.axil_read(ADDR_CMD_INST) == 0x1234_5678
		await env.axil_write(ADDR_A_ADDR_LO, 0x89AB_CDEF, write_delay_cycles=1)
		assert await env.axil_read(ADDR_A_ADDR_LO) == 0x89AB_CDEF

		ctrl_id = 0x41
		await env.send_desc_command(build_cfg_inst(0, 0x3344), ctrl_id, ctrl_write_delay_cycles=2)
		await env.wait_status(STATUS_RESP_FIFO_NOT_EMPTY, True)
		await env.wait_irq(True)
		await env.wait_and_pop_resp(pack_resp(False, 0, ctrl_id))
		await env.wait_status(STATUS_RESP_FIFO_NOT_EMPTY, False)
		await env.wait_irq(False)
		assert (await env.axil_read(ADDR_STATUS)) & STATUS_IRQ_ACTIVE == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_load_matmul_matadd_descriptors(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		is_v3 = _is_v3_wrapper(env)

		load_a_id = 0x101
		load_b_id = 0x102
		matmul_id = 0x103

		env.register_external_matrix("A", load_a_id, identity_matrix(env.x_dim, env.data_width))
		await env.send_desc_command(
			build_load_inst(env.x_dim * env.x_dim, 0, need_a=True, need_b=False),
			load_a_id,
			a_addr=0x1000_0100,
		)
		load_a = env.plan_load(load_a_id, env.x_dim * env.x_dim, 0, need_a=True, need_b=False)
		await env.wait_and_pop_resp(load_a.response_word)
		if not is_v3:
			await env.wait_rd_desc_count(1)
			assert env.rd_desc_log[0].kind == DMA_KIND_A
			assert env.rd_desc_log[0].addr == 0x1000_0100
			assert env.rd_desc_log[0].elems == load_a.a_size

		env.register_external_matrix("B", load_b_id, flatten_pattern_matrix(env.y_dim, 3, 1, 0))
		await env.send_desc_command(
			build_load_inst(0, env.y_dim * env.y_dim, need_a=False, need_b=True),
			load_b_id,
			b_addr=0x2000_0200,
		)
		load_b = env.plan_load(load_b_id, 0, env.y_dim * env.y_dim, need_a=False, need_b=True)
		await env.wait_and_pop_resp(load_b.response_word)
		if not is_v3:
			await env.wait_rd_desc_count(2)
			assert env.rd_desc_log[1].kind == DMA_KIND_B
			assert env.rd_desc_log[1].addr == 0x2000_0200
			assert env.rd_desc_log[1].elems == load_b.b_size

		env.register_external_matrix("A", matmul_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", matmul_id, repeating_matrix(env.x_dim, [2, 4, 6, 8][: env.y_dim]))
		rd_before = env.rd_desc_count
		wr_before = env.wr_desc_count
		export_before = env.export_done_count
		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			matmul_id,
			a_addr=0x3000_0300,
			b_addr=0x3000_0400,
			c_addr=0x3000_0500,
			m_addr=0x3000_0600,
		)
		matmul = env.plan_matmul(matmul_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		resp = await env.wait_and_pop_resp(matmul.response_word)
		await env.wait_rd_desc_count(rd_before + 2)
		await env.wait_wr_desc_count(wr_before + 1)
		await env.wait_export_done(export_before + 1)
		assert env.rd_desc_log[rd_before].kind == DMA_KIND_A
		assert env.rd_desc_log[rd_before].addr == 0x3000_0300
		assert env.rd_desc_log[rd_before].elems == matmul.a_len
		assert env.rd_desc_log[rd_before + 1].kind == DMA_KIND_B
		assert env.rd_desc_log[rd_before + 1].addr == 0x3000_0400
		assert env.rd_desc_log[rd_before + 1].elems == matmul.b_len
		assert env.wr_desc_log[wr_before].ctrl_id == matmul_id
		assert env.wr_desc_log[wr_before].addr == 0x3000_0600

		env.register_external_matrix("C", matmul_id, flatten_pattern_matrix(env.y_dim, 1, 2, 3))
		m_off = build_mwin_off((resp >> 30) & 0x1, 0)
		rd_before = env.rd_desc_count
		wr_before = env.wr_desc_count
		export_before = env.export_done_count
		await env.send_desc_command(
			build_matadd_inst(m_off),
			matmul_id,
			a_addr=0x3000_0300,
			b_addr=0x3000_0400,
			c_addr=0x3000_0700,
			m_addr=0x3000_0600,
		)
		matadd = env.plan_matadd(matmul_id, m_off)
		await env.wait_and_pop_resp(matadd.response_word)
		await env.wait_rd_desc_count(rd_before + 1)
		await env.wait_wr_desc_count(wr_before + 1)
		await env.wait_export_done(export_before + 1)
		assert env.rd_desc_log[rd_before].kind == DMA_KIND_C
		assert env.rd_desc_log[rd_before].addr == 0x3000_0700
		assert env.rd_desc_log[rd_before].elems == matadd.b_len
		assert env.wr_desc_log[wr_before].ctrl_id == matmul_id
		assert env.wr_desc_log[wr_before].addr == 0x3000_0600
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_desc_and_resp_overflow_flags(dut) -> None:
	env = await create_env(dut)
	try:
		for idx in range(5):
			ctrl_id = 0x200 + idx
			await env.send_desc_command(build_cfg_inst(0, idx), ctrl_id)
		await env.wait_status(STATUS_RESP_OVERFLOW, True)

		await env.soft_clear()
		await env.wait_status(STATUS_RESP_FIFO_NOT_EMPTY, False)
		await env.wait_irq(False)

		for idx in range(9):
			ctrl_id = 0x300 + idx
			await env.send_desc_command(build_cfg_inst(0, idx), ctrl_id)
		await env.wait_status(STATUS_DESC_OVERFLOW, True)
		assert (await env.axil_read(ADDR_STATUS)) & STATUS_DESC_OVERFLOW
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_desc_miss_and_soft_clear_recovery(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0xC000_0041
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7][: env.y_dim]))
		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x4100,
			b_addr=0x4200,
			m_addr=0x4300,
		)
		matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.wait_and_pop_resp(matmul.response_word)
		await env.wait_status(STATUS_DESC_MISS, True)
		await env.wait_irq(True)
		await env.clear_flags()
		assert (await env.axil_read(ADDR_STATUS)) & STATUS_DESC_MISS

		await env.soft_clear()
		await env.wait_status(STATUS_DESC_MISS, False)
		await env.wait_irq(False)

		recover_id = 0x55
		await env.send_desc_command(build_cfg_inst(0, 0x5566), recover_id)
		await env.wait_and_pop_resp(pack_resp(False, 0, recover_id))
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_same_id_descriptor_update_for_b_reload(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0x611
		orig_b_addr = 0x5100
		new_b_addr = 0x5200
		m_addr = 0x5300

		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [2, 4, 6, 8][: env.y_dim]))
		env.register_external_matrix("C", ctrl_id, flatten_pattern_matrix(env.y_dim, 1, 3, 5))

		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x5000,
			b_addr=orig_b_addr,
			m_addr=m_addr,
		)
		first = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		first_resp = await env.wait_and_pop_resp(first.response_word)
		await env.wait_export_done(1)

		await env.send_desc_command(
			build_matadd_inst(build_mwin_off((first_resp >> 30) & 0x1, 0)),
			ctrl_id,
			a_addr=0x5000,
			b_addr=orig_b_addr,
			c_addr=0x5400,
			m_addr=m_addr,
		)
		add_plan = env.plan_matadd(ctrl_id, build_mwin_off((first_resp >> 30) & 0x1, 0))
		await env.wait_and_pop_resp(add_plan.response_word)
		await env.wait_export_done(2)

		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x5000,
			b_addr=new_b_addr,
			m_addr=m_addr,
		)
		second = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.wait_and_pop_resp(second.response_word)
		await env.wait_export_done(3)
		assert env.rd_desc_log[-1].kind == DMA_KIND_B
		assert env.rd_desc_log[-1].addr == new_b_addr
		assert env.rd_desc_log[-1].elems == second.b_len
		assert env.wr_desc_log[-1].addr == m_addr
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_multitile_descriptor_sizes_and_export_beats(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0x6A1
		m_tiles = PT_TILES_2
		n_tiles = PT_TILES_2
		k_tiles = PT_TILES_2
		a_matrix = make_multitile_a_matrix(env.x_dim, m_tiles, k_tiles)
		b_matrix = make_multitile_b_matrix(env.y_dim, k_tiles, n_tiles)
		env.register_external_matrix("A", ctrl_id, a_matrix)
		env.register_external_matrix("B", ctrl_id, b_matrix)

		await env.send_desc_command(
			build_matmul_inst(m_tiles, n_tiles, k_tiles),
			ctrl_id,
			a_addr=0x6100,
			b_addr=0x6200,
			m_addr=0x6300,
		)
		plan = env.plan_matmul(ctrl_id, m_scale=m_tiles, n_scale=n_tiles, k_scale=k_tiles)
		assert not plan.err
		await env.wait_and_pop_resp(plan.response_word)
		await env.wait_rd_desc_count(2)
		await env.wait_wr_desc_count(1)
		await env.wait_export_done(1)
		assert env.rd_desc_log[0].elems == plan.a_len
		assert env.rd_desc_log[1].elems == plan.b_len
		assert env.wr_desc_log[0].beats == len(env._pack_export_beats(plan.result_matrix or []))
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_multitile_matadd_is_rejected(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0x6C1
		env.register_external_matrix("A", ctrl_id, make_multitile_a_matrix(env.x_dim, PT_TILES_2, PT_TILES_1))
		env.register_external_matrix("B", ctrl_id, make_multitile_b_matrix(env.y_dim, PT_TILES_1, PT_TILES_1))
		await env.send_desc_command(
			build_matmul_inst(PT_TILES_2, PT_TILES_1, PT_TILES_1),
			ctrl_id,
			a_addr=0x7100,
			b_addr=0x7200,
			m_addr=0x7300,
		)
		matmul = env.plan_matmul(ctrl_id, m_scale=PT_TILES_2, n_scale=PT_TILES_1, k_scale=PT_TILES_1)
		resp = await env.wait_and_pop_resp(matmul.response_word)
		await env.wait_export_done(1)

		rd_before = env.rd_desc_count
		wr_before = env.wr_desc_count
		m_off = build_mwin_off((resp >> 30) & 0x1, 0)
		matadd = env.plan_matadd(ctrl_id + 1, m_off)
		assert matadd.err
		await env.send_desc_command(build_matadd_inst(m_off), ctrl_id + 1, c_addr=0x7400, m_addr=0x7300)
		await env.wait_and_pop_resp(matadd.response_word)
		await ClockCycles(dut.clk, 8)
		assert env.rd_desc_count == rd_before
		assert env.wr_desc_count == wr_before
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_cmd_fifo_overflow_under_dma_backpressure(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0x722
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 2, 3, 4][: env.y_dim]))

		env.configure_patterns(dma_req_ready=ConstantPattern(0))
		for _ in range(12):
			await env.send_desc_command(
				build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
				ctrl_id,
				a_addr=0x6100,
				b_addr=0x6200,
				m_addr=0x6300,
			)

		await env.wait_status(STATUS_CMD_OVERFLOW, True)
		await env.clear_flags()
		assert ((await env.axil_read(ADDR_STATUS)) & STATUS_CMD_OVERFLOW) == 0

		await env.soft_clear()
		env.configure_patterns(dma_req_ready=ConstantPattern(1))
		recover_id = 0x723
		await env.send_desc_command(build_cfg_inst(0, 0x7788), recover_id)
		await env.wait_and_pop_resp(pack_resp(False, 0, recover_id))
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_clear_flags_clears_nonfatal_sticky_only(dut) -> None:
	env = await create_env(dut)
	try:
		for idx in range(5):
			await env.send_desc_command(build_cfg_inst(0, idx), 0x810 + idx)
		await env.wait_status(STATUS_RESP_OVERFLOW, True)
		await env.clear_flags()
		status = await env.axil_read(ADDR_STATUS)
		assert (status & STATUS_RESP_OVERFLOW) == 0
		assert (status & STATUS_DESC_OVERFLOW) == 0
		assert status & STATUS_RESP_FIFO_NOT_EMPTY
		assert status & STATUS_IRQ_ACTIVE
		for _ in range(4):
			await env.pop_resp()
		await env.wait_status(STATUS_RESP_FIFO_NOT_EMPTY, False)
		await env.wait_irq(False)
		await env.soft_clear()

		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0xC000_0081
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7][: env.y_dim]))
		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x7100,
			b_addr=0x7200,
			m_addr=0x7300,
		)
		miss_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.wait_and_pop_resp(miss_plan.response_word)
		await env.wait_status(STATUS_DESC_MISS, True)
		await env.clear_flags()
		status = await env.axil_read(ADDR_STATUS)
		assert status & STATUS_DESC_MISS
		assert status & STATUS_IRQ_ACTIVE

		await env.soft_clear()
		await env.wait_status(STATUS_DESC_MISS, False)
		await env.wait_irq(False)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_ch4_skew_aligns_without_error(dut) -> None:
	env = await create_env(dut)
	try:
		if (not _is_v3_wrapper(env)) or (env.stream_channels != 4):
			return

		for delay_cycles in (1, 2, 3):
			await env.soft_clear()
			await setup_bases_and_passthrough_qcfg(env)
			ctrl_id = 0xA100 + delay_cycles
			env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7][: env.y_dim]))
			env.queue_ab_injection(AbInjection(channel_group_delay_cycles=(delay_cycles, 0, 0, 0)))
			await env.send_desc_command(
				build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
				ctrl_id,
				a_addr=0x8100 + (delay_cycles * 0x100),
				b_addr=0x8200 + (delay_cycles * 0x100),
				m_addr=0x8300 + (delay_cycles * 0x100),
			)
			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not plan.err
			await env.wait_and_pop_resp(plan.response_word)
			await env.wait_export_done(1)
			assert ((await env.axil_read(ADDR_STATUS)) & STATUS_STREAM_ALIGN_ERROR) == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_ch4_align_timeout_sets_fatal_sticky(dut) -> None:
	env = await create_env(dut)
	try:
		if (not _is_v3_wrapper(env)) or (env.stream_channels != 4):
			return

		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0xA200
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [2, 4, 6, 8][: env.y_dim]))
		env.queue_ab_injection(AbInjection(suppress_channel_mask=1 << 0))
		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x9100,
			b_addr=0x9200,
			m_addr=0x9300,
		)
		_ = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.wait_status(STATUS_STREAM_ALIGN_ERROR, True, timeout_cycles=400)
		await env.wait_irq(True, timeout_cycles=400)
		await env.clear_flags()
		assert (await env.axil_read(ADDR_STATUS)) & STATUS_STREAM_ALIGN_ERROR
		await env.soft_clear()
		await env.wait_status(STATUS_STREAM_ALIGN_ERROR, False)
		await env.wait_irq(False)
		recover_id = 0xA201
		await env.send_desc_command(build_cfg_inst(0, 0x1357), recover_id)
		await env.wait_and_pop_resp(pack_resp(False, 0, recover_id))
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_ch4_sideband_mismatch_sets_fatal_sticky(dut) -> None:
	env = await create_env(dut)
	try:
		if (not _is_v3_wrapper(env)) or (env.stream_channels != 4):
			return

		mismatch_specs = (
			{"tuser_mismatch_channel": 1},
			{"tlast_mismatch_channel": 2},
			{"tkeep_mismatch_channel": 3},
			{"tid_mismatch_channel": 1},
			{"tdest_mismatch_channel": 2},
		)
		for idx, spec in enumerate(mismatch_specs):
			await env.soft_clear()
			await setup_bases_and_passthrough_qcfg(env)
			ctrl_id = 0xA300 + idx
			env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 2, 3, 4][: env.y_dim]))
			env.queue_ab_injection(AbInjection(**spec))
			await env.send_desc_command(
				build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
				ctrl_id,
				a_addr=0xA100 + (idx * 0x100),
				b_addr=0xA200 + (idx * 0x100),
				m_addr=0xA300 + (idx * 0x100),
			)
			_ = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			await env.wait_status(STATUS_STREAM_ALIGN_ERROR, True, timeout_cycles=200)
			await env.wait_irq(True, timeout_cycles=200)
			await env.clear_flags()
			assert (await env.axil_read(ADDR_STATUS)) & STATUS_STREAM_ALIGN_ERROR
			await env.soft_clear()
			await env.wait_status(STATUS_STREAM_ALIGN_ERROR, False)
			await env.wait_irq(False)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_ch4_single_active_channel_mask_works(dut) -> None:
	env = await create_env(dut)
	try:
		if (not _is_v3_wrapper(env)) or (env.stream_channels != 4):
			return

		for active_mask in (0x1, 0x4):
			await env.soft_clear()
			await setup_bases_and_passthrough_qcfg(env)
			await env.set_active_channel_mask(active_mask)
			ctrl_id = 0xA400 + active_mask
			env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [2, 4, 6, 8][: env.y_dim]))
			suppress_mask = ((1 << env.stream_channels) - 1) & ~active_mask
			env.queue_ab_injection(AbInjection(suppress_channel_mask=suppress_mask))
			env.queue_ab_injection(AbInjection(suppress_channel_mask=suppress_mask))
			export_before = env.export_done_count
			await env.send_desc_command(
				build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
				ctrl_id,
				a_addr=0xB100 + (active_mask * 0x100),
				b_addr=0xB200 + (active_mask * 0x100),
				m_addr=0xB300 + (active_mask * 0x100),
			)
			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not plan.err
			await env.wait_and_pop_resp(plan.response_word)
			await env.wait_export_done(export_before + 1)
			assert ((await env.axil_read(ADDR_STATUS)) & STATUS_STREAM_ALIGN_ERROR) == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_ch2_single_active_channel_mask_works(dut) -> None:
	env = await create_env(dut)
	try:
		if (not _is_v3_wrapper(env)) or (env.stream_channels != 2):
			return

		for active_mask in (0x1, 0x2):
			await env.soft_clear()
			await setup_bases_and_passthrough_qcfg(env)
			await env.set_active_channel_mask(active_mask)
			ctrl_id = 0xA500 + active_mask
			env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7][: env.y_dim]))
			suppress_mask = ((1 << env.stream_channels) - 1) & ~active_mask
			env.queue_ab_injection(AbInjection(suppress_channel_mask=suppress_mask))
			env.queue_ab_injection(AbInjection(suppress_channel_mask=suppress_mask))
			export_before = env.export_done_count
			await env.send_desc_command(
				build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
				ctrl_id,
				a_addr=0xC100 + (active_mask * 0x100),
				b_addr=0xC200 + (active_mask * 0x100),
				m_addr=0xC300 + (active_mask * 0x100),
			)
			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not plan.err
			await env.wait_and_pop_resp(plan.response_word)
			await env.wait_export_done(export_before + 1)
			assert ((await env.axil_read(ADDR_STATUS)) & STATUS_STREAM_ALIGN_ERROR) == 0
	finally:
		env.shutdown()
