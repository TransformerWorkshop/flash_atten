from __future__ import annotations

from tests.pt_case_catalog import QCFG_CASES
from tests.pt_case_runner import install_catalog_tests, run_qcfg_case


install_catalog_tests(globals(), "qcfg", QCFG_CASES, run_qcfg_case)
