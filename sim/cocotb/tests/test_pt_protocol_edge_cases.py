from __future__ import annotations

from tests.pt_case_catalog import PROTOCOL_EDGE_CASES
from tests.pt_case_runner import install_catalog_tests, run_protocol_edge_case


install_catalog_tests(globals(), "protocol_edge", PROTOCOL_EDGE_CASES, run_protocol_edge_case)
