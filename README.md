# Argus Neural Codec

The Argus Neural Codec contains the gateware configuration for neural coding and
decoding within the Argus Cybernetics stack. Access to that gateware is mediated
by the Argus Safety Controller, which exposes it to the rest of the ROS graph.
The whole stack, and the one command that runs it on the board, is described in
[argus_bringup/README.md](https://github.com/Max-Gabriel-Susman/argus_bringup/blob/main/README.md).
Build and test this repo with `cd sim && make` (seven GHDL benches, about five
minutes).

The long term plan is to:

- [x] 1. Migrate the current neural decoding logic from the Argus Safety
  Controller to the gateware in this repo while providing safe access to the
  gateware for the rest of the Argus Cybernetics stack's ROS graph. This targets
  the Arty Z7's PL. Done at fabric revision ACQ3: `argus_feature` computes
  crossings and spike-band power in the PL, and the firmware ships them.

- [ ] 2. Modify the Argus Cybernetics stack implementation to be a closed-loop
  interface (shape still undecided).

## Register map (fabric revision ACQ3)

`argus_acq_top` is an AXI4-Lite slave on `M_AXI_GP0` at `0x43C00000`, 4 KB.
Byte offsets, 32-bit words; the header of `rtl/argus_acq_axi.vhd` is the
authoritative copy. Unmapped addresses read `0xDEADBEEF` with an OKAY
response (a SLVERR would data-abort the A9 during bring-up).

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| `0x000` | `CTRL` | RW | bit 0 `enable` start / park the SPI master; bit 1 `soft_reset` hold the chain in reset; bit 2 `ext_mode` chips serve BRAM replay samples instead of the built-in pattern; bit 3 `hold` freeze the frame read bank; bit 4 `feat_hold` freeze the feature bank |
| `0x004` | `STATUS` | RO | bit 0 `ready` init sequence complete; bit 1 `overrun` assembler dropped a slot; bit 2 `held` frame freeze in effect and settled; bit 3 `feat_held` the same for the feature bank |
| `0x008` | `FRAME_INDEX` | RO | sweep number of the frame in the read bank |
| `0x00C` | `ID` | RO | `0x41435133`, "ACQ3". Read this first |
| `0x010` | `REPLAY_STATUS` | RO | bit 0 `play_half`; bit 1 `consumed0`; bit 2 `consumed1`; bit 3 `underrun`; bits 23:8 `play_row` |
| `0x014` | `REPLAY_ACK` | WO | write 1 to bit 0 / 1 / 2 to clear `consumed0` / `consumed1` / `underrun` |
| `0x018` | `FEATURE_INDEX` | RO | feature bins completed; the bank holds the latest |
| `0x01C` | `FEAT_DROPPED` | RO | bins lost to a `feat_hold` longer than one bin |
| `0x100`–`0x27C` | `FRAME[0..95]` | RO | one 16-bit sample in the low half of each word |
| `0x400`–`0x6FC` | `FEATURE[0..95]` | RO | two words per channel, channel *c* at `0x400 + 8c`: word 0 is `sum[31:0]`, word 1 is `count[15:0] & sum[47:32]` |

`sum` is the channel's spike-band power for the bin, the 48-bit sum of the
squared high-passed signal over 1500 sweeps (50 ms); `count` is its
threshold crossings. Both match `argus_sim/tools/spike_features.py`
bit-exact, in simulation and on silicon (`argus_sim/tools/hw_bitexact.py`:
139200/139200 counts and powers over 1450 bins of a 90 s board run).

**Reading a frame or a bin.** Set `CTRL.hold` (`CTRL.feat_hold`), poll
`STATUS.held` (`STATUS.feat_held`), read the index and the words at any
pace, clear the bit. The index is frozen with its bank, so it names what is
actually being read. A GP0 read costs about 1.1 µs, so 96 frame words take
~114 µs against a 33.3 µs sweep: a seqlock cannot work, which is why the
hold is in hardware. Frames completing under hold are dropped; a feature
bin completing under hold is deferred to the release, and only a hold
longer than a whole bin loses one (`FEAT_DROPPED`).

**Revisions.** `ID` changes whenever the firmware comes to depend on
something new. ACQ1 is everything before hold/held; ACQ2 added `hold` /
`held`; ACQ3 adds `argus_feature`, `CTRL` bit 4, `STATUS` bit 3,
`FEATURE_INDEX`, `FEAT_DROPPED` and the `0x400` feature bank.

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

Every bench is its own target, so per-bench settings apply: `tb_argus_acq_top`
runs to 120 ms to see its first feature bin, and `tb_argus_feature` runs to
200 ms with no waveform (the feature block over 7.5 M clocks would be hundreds
of MB of `.ghw`). The whole suite, seven benches, takes about five minutes.
Waveforms for the others land in `sim/build/<testbench>.ghw` and are uploaded
as CI artifacts on every run.

### `sim/data/`: the bit-exact CI pair

`tb_argus_feature` drives real cortex through `argus_feature` and checks every
(bin, channel, count, power) against `spike_features.py`'s golden,
bit-exact. `sim/data/` holds the CI-sized pair: `feature_ci.dat`, the first
6000 sweeps of the Indy replay segment (1.2 MB of raw `uint16` codes), and
`feature_ci_golden.txt`, the model's output for them: 60 bins × 96 channels,
5760 pairs, at a 2048-sweep warm-up and 100-sweep bins so every arithmetic
path runs in about three minutes. The samples are from O'Doherty et al.,
doi:10.5281/zenodo.1419774, CC-BY-4.0; how the pair is regenerated is in
`scripts/derive.sh` of the
[argus_data](https://github.com/Max-Gabriel-Susman/argus_data) repository,
and in the comment above `FEATURE_BIN` in `sim/Makefile`. Regenerate both
after any change to the model's arithmetic.

The bench takes its inputs as Make variables, so the production-parameter
run (48000 sweeps, 1500-sweep bins, ~15 min) is a local check against the
full segment:

```bash
make tb_argus_feature FEATURE_BIN=~/argus_data/indy_20161005_06_s120_10s.bin \
    FEATURE_GOLDEN=~/argus_data/indy_20161005_06_s120_10s.golden.txt \
    FEATURE_GENERICS= STOP_TIME=600ms
```

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

The firmware now reads `ID` at boot and prints `acq id=... EXPECTED ...
-- stale bitstream?` on a mismatch, which `hwtest.sh` fails on. That catches a
missed revision bump, not a changed bit inside one revision.

### What `build_bitstream.tcl` does and gates

`build_bitstream.tcl` is the only way a bitstream is made. Before building it
adds any `rtl/*.vhd` missing from `sources_1` (the module reference is
synthesised from `sources_1`, and an entity that was never added is invisible
to it: `argus_feature.vhd` was the first to hit this) and regenerates the
module reference so RTL edits are not linked from a stale checkpoint. Then
it runs synthesis, implementation and bitstream, and exports the XSA only if:

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
4. Relay up, serial console open, then Run — in that order. Today
   `argus_bringup/scripts/hwtest.sh` (or `argus.launch.py program:=true`)
   does this: it starts the relay and console, then programs the board.

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
