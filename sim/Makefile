GHDL      ?= ghdl
STD       ?= 08
WORKDIR   ?= build
STOP_TIME ?= 20ms

# Analysis order matters to GHDL. wildcard+sort is fine while rtl/ has no
# inter-file dependencies; pin the order explicitly here the moment it does,
# e.g.  RTL_SRCS := ../rtl/argus_pkg.vhd ../rtl/argus_rhd2132_model.vhd
RTL_SRCS ?= $(sort $(wildcard ../rtl/*.vhd))
SIM_SRCS ?= $(sort $(wildcard tb_*.vhd))

TBS := $(basename $(notdir $(SIM_SRCS)))

# Top-level unit(s) checked by `make synth`. Simulation-only testbenches must
# never appear here.
SYNTH_TOPS ?= argus_rhd2132_model

GHDL_FLAGS := --std=$(STD) --workdir=$(WORKDIR) -frelaxed -Wall

# --assert-level defaults to `error`, which would halt at the first mismatch
# and hide the rest. The testbenches count their own failures and end with a
# `severity failure` summary, so let them run to completion and drive the
# exit code themselves.
RUN_FLAGS := --assert-level=failure --stop-time=$(STOP_TIME)

.PHONY: all analyze run synth clean $(TBS)

all: run

$(WORKDIR):
	mkdir -p $(WORKDIR)

analyze: | $(WORKDIR)
	@test -n "$(strip $(RTL_SRCS))" || { echo "no sources in ../rtl"; exit 1; }
	@test -n "$(strip $(SIM_SRCS))" || { echo "no tb_*.vhd in sim/"; exit 1; }
	$(GHDL) -a $(GHDL_FLAGS) $(RTL_SRCS) $(SIM_SRCS)

run: analyze
	@set -e; for tb in $(TBS); do \
	  echo "::group::$$tb"; \
	  $(GHDL) -e $(GHDL_FLAGS) $$tb; \
	  $(GHDL) -r $(GHDL_FLAGS) $$tb $(RUN_FLAGS) --wave=$(WORKDIR)/$$tb.ghw; \
	  echo "::endgroup::"; \
	done

$(TBS): analyze
	$(GHDL) -e $(GHDL_FLAGS) $@
	$(GHDL) -r $(GHDL_FLAGS) $@ $(RUN_FLAGS) --wave=$(WORKDIR)/$@.ghw

synth: analyze
	@set -e; for top in $(SYNTH_TOPS); do \
	  echo "::group::synth $$top"; \
	  $(GHDL) --synth $(GHDL_FLAGS) $$top > $(WORKDIR)/$$top.synth.vhd; \
	  echo "::endgroup::"; \
	done

clean:
	rm -rf $(WORKDIR)