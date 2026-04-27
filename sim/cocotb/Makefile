SIM ?=
TARGET ?= pt_dma_top
SEED ?=
WAVES ?= 0
VERBOSE ?= 0
TEST_FILTER ?=
TESTCASE ?=
KEEP_BUILD ?= 0
REBUILD ?= 0

PYTHON ?= python3
RUNNER := $(PYTHON) run.py
TARGET_ARG := --target $(TARGET)

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

all: smoke

smoke:
	$(RUNNER) smoke $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

full:
	$(RUNNER) full $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

ci:
	$(RUNNER) ci $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

stress:
	$(RUNNER) stress $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

randomized:
	$(RUNNER) randomized $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

extended:
	$(RUNNER) extended $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

soak:
	$(RUNNER) soak $(SIM_ARG) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_baseline:
	$(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_full:
	$(RUNNER) fa_full $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_baseline_axi:
	$(RUNNER) fa_baseline_axi $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_full_axi:
	$(RUNNER) fa_full_axi $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(TEST_FILTER_ARG) $(TESTCASE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)

fa_ci:
	$(PYTHON) -m py_compile run.py tests/test_fa_baseline.py tests/test_fa_baseline_numeric_cases.py tests/test_fa_baseline_backpressure_cases.py tests/test_fa_baseline_axi.py tests/test_fa_baseline_axi_full_cases.py tests/test_fa_p_bypass.py tests/test_fa_shared_gemm.py tests/test_fa_oacc_update.py tests/fa_baseline_axi_env.py ../../scripts/fa_precision_analysis.py ../../scripts/fa_baseline_profile.py
	$(RUNNER) fa_p_bypass $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_shared_gemm $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_oacc_update $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_numeric_single_q_full_kv_causal,test_fa_backpressure_combined_single_q_full_kv_causal $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_full $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	$(RUNNER) fa_full_axi $(SIM_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG) --testcase test_fa_baseline_axi_full_noncausal_end_to_end,test_fa_baseline_axi_full_backpressure_numeric $(KEEP_BUILD_ARG) $(REBUILD_ARG)
	FA_FAST_WAIT=0 $(RUNNER) fa_baseline $(SIM_ARG) $(SEED_ARG) $(VERBOSE_ARG) --testcase test_fa_smoke_basic_run_and_counters $(KEEP_BUILD_ARG)

coverage:
	$(RUNNER) coverage --sim verilator --target pt $(SEED_ARG) $(VERBOSE_ARG)

clean:
	rm -rf build results logs waves coverage

.PHONY: all smoke full ci stress randomized extended soak fa_baseline fa_full fa_baseline_axi fa_full_axi fa_ci coverage clean
