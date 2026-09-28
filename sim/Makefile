GHDL      ?= ghdl
STD       ?= 08
WORKDIR   ?= build
STOP_TIME ?= 20ms

# Analysis order matters to GHDL: a unit must be analysed before anything
# that instantiates it. argus_acq_top instantiates the other five, so the
# order is pinned here rather than left to wildcard+sort, which would put
# argus_acq_top first alphabetically and fail with "unit not found".
RTL_SRCS ?= ../rtl/argus_rhd2132_model.vhd \
            ../rtl/argus_rhd_spi_master.vhd \
            ../rtl/argus_frame_assembler.vhd \
            ../rtl/argus_sample_fetch.vhd \
            ../rtl/argus_feature.vhd \
            ../rtl/argus_acq_axi.vhd \
            ../rtl/argus_acq_top.vhd
SIM_SRCS ?= $(sort $(wildcard tb_*.vhd))

TBS := $(basename $(notdir $(SIM_SRCS)))

# Top-level unit(s) checked by `make synth`. Simulation-only testbenches must
# never appear here. argus_acq_top pulls in the whole chain.
SYNTH_TOPS ?= argus_acq_top

GHDL_FLAGS := --std=$(STD) --workdir=$(WORKDIR) -frelaxed

# --assert-level defaults to `error`, which would halt at the first mismatch
# and hide the rest. The testbenches count their own failures and end with a
# `severity failure` summary, so let them run to completion and drive the
# exit code themselves.
#
# Recursive (=), not simply-expanded (:=), so the per-bench STOP_TIME and
# WAVE_FLAG settings below take effect when the recipe runs.
RUN_FLAGS = --assert-level=failure --stop-time=$(STOP_TIME)
WAVE_FLAG = --wave=$(WORKDIR)/$@.ghw

# ---------------------------------------------------------------------------
# Per-bench settings. Target-specific variables; a value on the make command
# line still overrides them.
# ---------------------------------------------------------------------------

# tb_argus_acq_top waits for the first feature bin: 1500 sweeps, 50 ms of
# simulated time. Its own watchdog is 200 ms.
tb_argus_acq_top: STOP_TIME := 120ms

# tb_argus_feature drives real cortex samples through argus_feature and
# checks every (bin, channel, count, power) against spike_features.py's
# golden, bit-exact. The pair under data/ is the CI-sized case -- the first
# 6000 rows of the Indy segment, run at a 2048-sweep warm-up and 100-sweep
# bins so every arithmetic path is exercised in about three minutes:
#
#   head -c $((6000*96*2)) ~/argus_data/indy_20161005_06_s120_10s.bin > data/feature_ci.dat
#   python3 <argus_ws>/src/argus_sim/tools/spike_features.py data/feature_ci.dat \
#       --mult 3.5 --ms-shift 11 --warmup 2048 --bin 100 \
#       --golden data/feature_ci_golden.txt
#
# Regenerate both after any change to the model's arithmetic. The samples
# are from O'Doherty et al., doi:10.5281/zenodo.1419774, CC-BY-4.0.
#
# The production-parameter run (48000 sweeps, ~15 min) is a local check:
#
#   make tb_argus_feature FEATURE_BIN=~/argus_data/indy_20161005_06_s120_10s.bin \
#       FEATURE_GOLDEN=~/argus_data/indy_20161005_06_s120_10s.golden.txt \
#       FEATURE_GENERICS= STOP_TIME=600ms
FEATURE_BIN      ?= data/feature_ci.dat
FEATURE_GOLDEN   ?= data/feature_ci_golden.txt
FEATURE_GENERICS ?= -gn_sweeps=6000 -gms_shift=11 -gwarmup=2048 -gbin_len=100
tb_argus_feature: STOP_TIME := 200ms
tb_argus_feature: RUN_EXTRA := -gstim_file=$(FEATURE_BIN) -ggolden_file=$(FEATURE_GOLDEN) $(FEATURE_GENERICS)
tb_argus_feature: WAVE_FLAG :=
# (no wave: 7.5M clocks of the feature block is hundreds of MB of .ghw)

.PHONY: all analyze run synth clean $(TBS)

all: run

$(WORKDIR):
	mkdir -p $(WORKDIR)

analyze: | $(WORKDIR)
	@test -n "$(strip $(RTL_SRCS))" || { echo "no sources in ../rtl"; exit 1; }
	@test -n "$(strip $(SIM_SRCS))" || { echo "no tb_*.vhd in sim/"; exit 1; }
	$(GHDL) -a $(GHDL_FLAGS) $(RTL_SRCS) $(SIM_SRCS)

# Every bench is its own target so the per-bench variables apply; `run` is
# all of them, in name order. Make stops at the first bench that fails.
run: $(TBS)

$(TBS): analyze
	@echo "::group::$@"
	$(GHDL) -e $(GHDL_FLAGS) $@
	$(GHDL) -r $(GHDL_FLAGS) $@ $(RUN_FLAGS) $(RUN_EXTRA) $(WAVE_FLAG)
	@echo "::endgroup::"

synth: analyze
	@set -e; for top in $(SYNTH_TOPS); do \
	  echo "::group::synth $$top"; \
	  $(GHDL) --synth $(GHDL_FLAGS) $$top > $(WORKDIR)/$$top.synth.vhd; \
	  echo "::endgroup::"; \
	done

clean:
	rm -rf $(WORKDIR)
