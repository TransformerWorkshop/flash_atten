from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def reset_dut(dut) -> None:
    dut.rstn.value = 0
    dut.clear.value = 0
    dut.qk_req_valid.value = 0
    dut.pv_req_valid.value = 0
    dut.q_rd_valid.value = 0
    dut.k_rd_valid.value = 0
    dut.p_rd_valid.value = 0
    dut.v_rd_valid.value = 0
    dut.q_rd_data.value = 0
    dut.k_rd_data.value = 0
    dut.p_rd_data.value = 0
    dut.v_rd_data.value = 0
    dut.qk_resp_ready.value = 1
    dut.pv_resp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


@cocotb.test()
async def test_fa_shared_gemm_qk_priority_on_simultaneous_request(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    assert int(dut.qk_req_ready.value) == 1
    assert int(dut.pv_req_ready.value) == 1

    dut.qk_req_valid.value = 1
    dut.pv_req_valid.value = 1
    await Timer(1, unit="ps")
    assert int(dut.qk_req_ready.value) == 1
    assert int(dut.pv_req_ready.value) == 0

    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.q_rd_en.value) == 1
    assert int(dut.k_rd_en.value) == 1
    assert int(dut.p_rd_en.value) == 0
    assert int(dut.v_rd_en.value) == 0

    dut.clear.value = 1
    dut.qk_req_valid.value = 0
    dut.pv_req_valid.value = 0
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")

    dut.pv_req_valid.value = 1
    await Timer(1, unit="ps")
    assert int(dut.pv_req_ready.value) == 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.p_rd_en.value) == 1
    assert int(dut.v_rd_en.value) == 1
    assert int(dut.q_rd_en.value) == 0
    assert int(dut.k_rd_en.value) == 0
