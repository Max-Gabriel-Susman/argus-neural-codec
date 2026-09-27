# Argus Neural Codec

The Argus Neural Codec contains the gateware configuration for neural coding and
decoding within the Argus Cybernetics stack. Access to that gateware is mediated
by the Argus Safety Controller, which exposes it to the rest of the ROS graph.

The long term plan is to:

- [ ] 1. Migrate the current neural decoding logic from the Argus Safety
  Controller to the gateware in this repo while providing safe access to the
  gateware for the rest of the Argus Cybernetics stack's ROS graph. This targets
  the Arty Z7's PL.

- [ ] 2. Modify the Argus Cybernetics stack implementation to be a closed-loop
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

## Building the bitstream

The Vivado project is driven from Tcl. The GUI is for reviewing the diagram
and reading reports; every change to what gets built goes through a script
in `tools/`, so the build is reproducible and the address map survives
regeneration.

Scripts are sourced from the Vivado Tcl console with the project open. Use
absolute paths — Vivado's working directory is rarely the repo root, and a
`source` that finds nothing prints nothing:

```tcl
source /home/prometheus/Documents/argus-neural-codec/tools/build_bitstream.tcl
```

Expect a wall of echoed commands. Silence means a wrong path or an empty file.

### The scripts

| Script | Does | Run when |
| --- | --- | --- |
| `tools/build_bitstream.tcl` | Synthesis → implementation → bitstream → XSA export, gated on timing and a non-empty PL | Every time the fabric changes |
| `tools/bd_add_acq.tcl` | Adds `argus_acq_top` to the block design as a module reference on `M_AXI_GP0`, pinned at `0x43C00000` / 4 KB | Once, on a block design without it. Idempotent |
| `tools/bd_add_bram.tcl` | Adds the replay BRAM: AXI BRAM Controller at `0x40000000` / 64 KB, true-dual-port BMG, port B wired to `argus_acq_top`. Force-re-elaborates the module first | Once, after `bd_add_acq.tcl`. Also the template for any port-list change |
| `tools/ooc_synth_check.tcl` | Out-of-context synthesis of one module against 125 MHz; no project needed | Before a new module goes into the block design |

`neural_codec_bd.tcl` at the repo root is written by the `bd_add_*` scripts
(`write_bd_tcl -force`) and is the source of truth for the block design. It
contains the module reference, so `rtl/` must be in the project before it
can be sourced. Recreating the project from it on a fresh clone: TODO.

### What changed → what to run

| Change | Run |
| --- | --- |
| RTL internals — logic, a new register bit — with `argus_acq_top`'s port list unchanged | `build_bitstream.tcl` only. Synthesis reads `rtl/` directly and `reset_run` prevents a stale netlist being reused |
| `argus_acq_top`'s entity — ports added, removed, renamed, retyped | The re-elaboration steps from `bd_add_bram.tcl` (delete the cell, remove and re-add the source, recreate the cell, restore `S_AXI` and the address), then `build_bitstream.tcl`. `update_module_reference` does not work: it compares against a cached elaboration and returns silently |
| Block design — new IP, an address, a clock | Edit or extend the relevant `bd_add_*.tcl`, source it, then `build_bitstream.tcl` |
| Firmware only | Nothing here. Rebuild in Vitis |

If a first-row change builds clean but the feature still does nothing on
hardware, fall through to the second row.

**The failure that bites:** firmware depending on a new register bit, built
and run without a new bitstream. The old fabric ignores the bit silently.
`acq id` and `frames/s` still pass because they predate the change, so the
symptom reads like an RTL bug. Check the bitstream against the commit before
suspecting the RTL:

```bash
cd ~/Documents/argus-neural-codec
git log -1 --format='%cd  %s' -- rtl/argus_acq_axi.vhd
ls -l --time-style=long-iso $(find . -name 'neural_codec_wrapper.bit' | head -1)
```

A fabric version register checked at boot would turn this into a first-line
failure; the `ID` register is the place for it.

### What `build_bitstream.tcl` gates

1. `argus_acq_top_0` is in the block design. Without it the build is
   PS7-only: implements clean, does nothing.
2. `impl_1` reached 100 %.
3. The implemented design has timed paths. None means an empty PL.
4. Post-route WNS and WHS are both ≥ 0. Negative slack means no export.

Reports: `/tmp/argus_build/timing.rpt` and `utilization.rpt`. Export:
`argus_neural_codec.xsa` at the repo root with the bitstream embedded, at a
fixed name so Vitis finds it without re-browsing.

About two minutes on this design: ~30 s synthesis, ~75 s implementation.

### Handoff to Vitis

The script prints these on success; they're here so they survive a closed
console.

1. `arty_z7_platform` → Settings → `vitis-comp.json` → **Switch / re-read XSA**
2. Build the platform, then `safety_controller`
3. `safety_controller` → `_ide` → `launch.json`: confirm **Program Device**
   is ticked and the bitstream field points at the new
   `neural_codec_wrapper.bit`. The PL must be configured before the first
   AXI access or the A9 hangs with no timeout
4. Relay up, serial console open, then Run — in that order

### Checking a module before it goes in

`ooc_synth_check.tcl` runs from the shell, from the repo root, with no
project:

```bash
cd ~/Documents/argus-neural-codec
xilinx
vivado -mode batch -nojournal -nolog -source tools/ooc_synth_check.tcl -tclargs argus_acq_top
```

Post-synthesis WNS against an 8 ns clock, applied after synthesis, so the
number is pessimistic — the right direction for a go/no-go. Reports in
`/tmp/argus_ooc/<module>.timing.rpt` and `.util.rpt`.
