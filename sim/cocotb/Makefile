SIM ?=
SEED ?=
WAVES ?= 0
VERBOSE ?= 0
TEST_FILTER ?=
TESTCASE ?=
KEEP_BUILD ?= 0
REBUILD ?= 0
COVERAGE_MODE ?= full
CODE_COVERAGE_SUITES ?= fa_full fa_full_axi fa_p_bypass fa_shared_gemm fa_oacc_update fa_rowstate_profile
FUNCTIONAL_COVERAGE_SUITES ?= fa_full fa_full_axi fa_p_bypass fa_shared_gemm fa_oacc_update fa_rowstate_profile
FUNC_COV_DIR ?= $(abspath coverage/functional/raw)

PYTHON ?= python3
RUNNER := $(PYTHON) run.py

ifeq ($(SIM),)
SIM_ARG :=
else
SIM_ARG := --sim $(SIM)
endif

ifeq ($(SEED),)
SEED_ARG :=
else
SEED_ARG := --seed $(SEED)
endif

ifeq ($(WAVES),1)
WAVES_ARG := --waves
else
WAVES_ARG :=
endif

ifeq ($(VERBOSE),1)
VERBOSE_ARG := --verbose
else
VERBOSE_ARG :=
endif

ifeq ($(TEST_FILTER),)
TEST_FILTER_ARG :=
else
TEST_FILTER_ARG := --test-filter $(TEST_FILTER)
endif

ifeq ($(TESTCASE),)
TESTCASE_ARG :=
else
TESTCASE_ARG := --testcase $(TESTCASE)
endif

ifeq ($(KEEP_BUILD),1)
KEEP_BUILD_ARG := --keep-build
else
KEEP_BUILD_ARG :=
endif

ifeq ($(REBUILD),1)
REBUILD_ARG := --rebuild
else
REBUILD_ARG :=
endif

all: fa_baseline

fa_baseline:
	$(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_full:
	$(RUNNER) fa_full $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_baseline_axi:
	$(RUNNER) fa_baseline_axi $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_full_axi:
	$(RUNNER) fa_full_axi $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_p_bypass:
	$(RUNNER) fa_p_bypass $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_shared_gemm:
	$(RUNNER) fa_shared_gemm $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_oacc_update:
	$(RUNNER) fa_oacc_update $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_rowstate_profile:
	$(RUNNER) fa_rowstate_profile $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_ci:
	$(PYTHON) -m py_compile run.py tests/*.py ../../scripts/fa_precision_analysis.py ../../scripts/fa_baseline_profile.py ../../scripts/fa_functional_coverage_report.py
	$(RUNNER) fa_p_bypass $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_shared_gemm $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_oacc_update $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_rowstate_profile $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_baseline_v_buf_banked_write_mapping,test_fa_baseline_vbuf_pv_source_beat_layout_mapping,test_fa_baseline_row_state_real_init $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_numeric_single_q_full_kv_causal,test_fa_backpressure_combined_single_q_full_kv_causal $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_full $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_full_axi $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_baseline_axi_full_noncausal_end_to_end,test_fa_baseline_axi_full_backpressure_numeric $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	FA_FAST_WAIT=0 $(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(VERBOSE_ARG) --testcase test_fa_smoke_basic_run_and_counters $(KEEP_BUILD_ARG)

fa_code_coverage:
	@for suite in $(CODE_COVERAGE_SUITES); do \
		echo "==> code coverage: $$suite"; \
		$(RUNNER) $$suite $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG) --coverage --coverage-mode $(COVERAGE_MODE) || exit $$?; \
	done

fa_functional_coverage:
	rm -rf $(FUNC_COV_DIR)
	mkdir -p $(FUNC_COV_DIR)
	@for suite in $(FUNCTIONAL_COVERAGE_SUITES); do \
		echo "==> functional coverage: $$suite"; \
		FA_FUNC_COV=1 FA_FUNC_COV_DIR=$(FUNC_COV_DIR) $(RUNNER) $$suite $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG) || exit $$?; \
	done
	$(PYTHON) ../../scripts/fa_functional_coverage_report.py --raw-dir $(FUNC_COV_DIR) --out-dir coverage/functional

fa_coverage: fa_functional_coverage fa_code_coverage

clean:
	rm -rf build results logs waves coverage

.PHONY: all fa_baseline fa_full fa_baseline_axi fa_full_axi fa_p_bypass fa_shared_gemm fa_oacc_update fa_rowstate_profile fa_ci fa_code_coverage fa_functional_coverage fa_coverage clean
