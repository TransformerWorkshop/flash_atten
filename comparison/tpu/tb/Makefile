SIM ?= verilator
TESTCASE ?=
WAVES ?= 0
VERBOSE ?= 0
PYTHON ?= python
VANILLA_RTL_ROOT ?= $(abspath ../../../../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl)

RUNNER := $(PYTHON) run.py

ifeq ($(TESTCASE),)
TESTCASE_ARG :=
else
TESTCASE_ARG := --testcase $(TESTCASE)
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

all: smoke

build:
	$(RUNNER) build --sim $(SIM) $(WAVES_ARG) $(VERBOSE_ARG)

smoke:
	$(RUNNER) smoke --sim $(SIM) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

coverage:
	$(RUNNER) coverage --sim $(SIM) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

numeric:
	$(RUNNER) numeric --sim $(SIM) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

numeric-both:
	$(RUNNER) numeric --sim $(SIM) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)
	$(RUNNER) numeric --sim $(SIM) --variant vanilla_v2 --rtl-root $(VANILLA_RTL_ROOT) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

clean:
	rm -rf build results logs coverage __pycache__ tests/__pycache__

.PHONY: all build smoke coverage numeric numeric-both clean
