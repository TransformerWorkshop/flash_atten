SIM ?= icarus
TARGET ?= pt_dma_top
SEED ?=
WAVES ?= 0
VERBOSE ?= 0

PYTHON ?= python3
RUNNER := $(PYTHON) run.py
TARGET_ARG := --target $(TARGET)

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

all: smoke

smoke:
	$(RUNNER) smoke --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

full:
	$(RUNNER) full --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

ci:
	$(RUNNER) ci --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

stress:
	$(RUNNER) stress --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

randomized:
	$(RUNNER) randomized --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

extended:
	$(RUNNER) extended --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

soak:
	$(RUNNER) soak --sim $(SIM) $(TARGET_ARG) $(SEED_ARG) $(WAVES_ARG) $(VERBOSE_ARG)

coverage:
	$(RUNNER) coverage --sim verilator --target pt $(SEED_ARG) $(VERBOSE_ARG)

clean:
	rm -rf build results logs waves coverage

.PHONY: all smoke full ci stress randomized extended soak coverage clean
