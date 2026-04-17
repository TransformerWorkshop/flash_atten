SIM ?= verilator
TESTCASE ?=
WAVES ?= 0
VERBOSE ?= 0
PYTHON ?= python
AXI_DATA_WIDTH ?= 128
RAM_DATA_WIDTH ?= 64
PE_SIZE ?= 16
VANILLA_RTL_ROOT ?= $(abspath ../../../../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl)

RUNNER := $(PYTHON) run.py
WIDTH_ARGS := --pe-size $(PE_SIZE) --axi-data-width $(AXI_DATA_WIDTH) --ram-data-width $(RAM_DATA_WIDTH)
VANILLA_WIDTH_ARGS := --pe-size 8 --axi-data-width 64 --ram-data-width 64

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
	$(RUNNER) build --sim $(SIM) $(WIDTH_ARGS) $(WAVES_ARG) $(VERBOSE_ARG)

smoke:
	$(RUNNER) smoke --sim $(SIM) $(WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

smoke-both:
	$(RUNNER) smoke --sim $(SIM) $(WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)
	$(RUNNER) smoke --sim $(SIM) --variant vanilla_v2 --rtl-root $(VANILLA_RTL_ROOT) $(VANILLA_WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

coverage:
	$(RUNNER) coverage --sim $(SIM) $(WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

numeric:
	$(RUNNER) numeric --sim $(SIM) $(WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

numeric-both:
	$(RUNNER) numeric --sim $(SIM) $(WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)
	$(RUNNER) numeric --sim $(SIM) --variant vanilla_v2 --rtl-root $(VANILLA_RTL_ROOT) $(VANILLA_WIDTH_ARGS) $(TESTCASE_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

clean:
	rm -rf build results logs coverage __pycache__ tests/__pycache__

.PHONY: all build smoke smoke-both coverage numeric numeric-both clean
