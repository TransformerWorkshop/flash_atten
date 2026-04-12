from __future__ import annotations

import os

import cocotb
from cocotb.triggers import Timer

from tests.pt_case_catalog import GUARD_PROFILE_BY_NAME


PROFILE_NAME = os.getenv("PT_GUARD_PROFILE", "odd_x_only_x3_y2")
PROFILE = GUARD_PROFILE_BY_NAME[PROFILE_NAME]


@cocotb.test(name=PROFILE.case_name)
async def test_pt_guard_profile(dut) -> None:
	await Timer(1, unit="ns")
