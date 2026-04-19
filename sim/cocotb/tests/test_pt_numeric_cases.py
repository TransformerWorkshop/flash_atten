from __future__ import annotations

from tests.pt_case_catalog import NUMERIC_CASES
from tests.pt_case_runner import install_catalog_tests, run_numeric_case


install_catalog_tests(globals(), "numeric", NUMERIC_CASES, run_numeric_case)
