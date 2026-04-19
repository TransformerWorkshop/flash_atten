from __future__ import annotations

from tests.pt_case_catalog import SMOKE_CASES
from tests.pt_case_runner import install_catalog_tests, run_smoke_case


install_catalog_tests(globals(), "smoke", SMOKE_CASES, run_smoke_case)
