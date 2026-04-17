from __future__ import annotations

from tests.pt_case_catalog import STATE_CASES
from tests.pt_case_runner import install_catalog_tests, run_state_case


install_catalog_tests(globals(), "state", STATE_CASES, run_state_case)
