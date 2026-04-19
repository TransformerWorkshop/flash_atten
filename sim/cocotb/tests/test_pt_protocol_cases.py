from __future__ import annotations

from tests.pt_case_catalog import PROTOCOL_CASES
from tests.pt_case_runner import install_catalog_tests, run_protocol_case


install_catalog_tests(globals(), "protocol", PROTOCOL_CASES, run_protocol_case)
