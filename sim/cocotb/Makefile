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

coverage:
	$(RUNNER) coverage --sim verilator --target pt $(SEED_ARG) $(VERBOSE_ARG)

clean:
	rm -rf build results logs waves coverage

.PHONY: all smoke full ci stress randomized extended soak fa_baseline fa_full fa_baseline_axi fa_full_axi coverage clean
