# Argus Neural Codec

The Argus Neural Codec contains the gateware configuration for neural coding and
decoding within the Argus Cybernetics stack. Access to that gateware is mediated
by the Argus Safety Controller, which exposes it to the rest of the ROS graph.

The long term plan is to:

- [ ] 1. Migrate the current neural decoding logic from the Argus Safety
  Controller to the gateware in this repo while providing safe access to the
  gateware for the rest of the Argus Cybernetics stack's ROS graph. This targets
  the Arty Z7's PL.

- [ ] 2. TODO — item missing from the original list; fill in or renumber.

- [ ] 3. Modify the Argus Cybernetics stack implementation to be a closed-loop
  interface (shape still undecided).

## Simulation

Testbenches in `sim/` run under [GHDL](https://github.com/ghdl/ghdl) rather than
XSim as Vivado can't run on a hosted CI runner, and the RHD2132 model and its
testbench are plain VHDL with no Xilinx primitives, so they don't need it. GHDL
covers `rtl/` and `sim/` only; the `neural_codec` block design and the PS7
instance are still validated on the workstation.

```bash
sudo apt-get install -y ghdl
cd sim && make
```

Make targets, all run from `sim/`:

| Target | Effect |
| --- | --- |
| `make` / `make run` | Analyze `rtl/` + `sim/`, then run every `tb_*.vhd` |
| `make analyze` | Analysis only |
| `make tb_<name>` | Run one testbench by name |
| `make synth` | Advisory `ghdl --synth` elaboration check |
| `make clean` | Remove `sim/build/` |

Waveforms land in `sim/build/<testbench>.ghw` and are uploaded as CI artifacts on
every run.

## Linting

VHDL style is enforced by [VSG](https://github.com/jeremiah-c-leary/vhdl-style-guide)
(VHDL Style Guide), a Python linter and auto-formatter. 

Install it isolated from the ROS 2 system Python:

```bash
pipx install vsg
```

Check and fix:

```bash
vsg -f rtl/*.vhd sim/*.vhd
vsg -f rtl/*.vhd sim/*.vhd --fix
```

## CI

`.github/workflows/ci.yml` runs four jobs on push and PR to `main`:

| Job | Gate | What it does |
| --- | --- | --- |
| `simulate` | blocking | GHDL analyze/elaborate/run over every testbench; uploads waveforms |
| `hygiene` | blocking | Rejects CRLF endings and tracked Vivado transient output |
| `lint` | advisory | VSG over all tracked `.vhd` outside the Vivado project tree |
| `synth-check` | advisory | `ghdl --synth` elaboration of `argus_rhd2132_model` |