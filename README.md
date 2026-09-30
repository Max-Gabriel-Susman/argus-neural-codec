# argus-neural-codec

The programmable-logic half of [Argus Cybernetics](https://github.com/Max-Gabriel-Susman/argus_bringup):
a 96-channel neural acquisition chain and a spike-feature codec in the
fabric of a Zynq XC7Z020 (Arty Z7-20), behind one AXI4-Lite register block.
Three simulated Intan RHD2132 chips are read over real SPI at 30,012
sweeps per second; a frame assembler keeps the latest raw frame; the codec
computes, per channel and per 50 ms bin, the number of threshold crossings
and the spike-band power. The firmware in
[argus_safety_controller](https://github.com/Max-Gabriel-Susman/argus_safety_controller)
reads both over AXI and puts them on the wire.

The codec is bit-exact against its Python model
(`argus_sim/tools/spike_features.py`): 5,760 (bin, channel) pairs in
simulation, 139,200 on silicon through the whole wire and ROS path.
Post-route timing at 125 MHz: WNS 0.924 ns, WHS 0.036 ns.

## What is in the fabric

```
                 ┌──────────────────────────────────────────────────────────────┐
  BRAM (PS-filled, ping-pong halves)                                             │
       │                                                                        │
       ▼                                                                        │
  argus_sample_fetch ──ext mode──► argus_rhd2132_model ×3 ──MISO──┐              │
                                   (identity pattern otherwise)   │              │
                                                                  ▼              │
                                                       argus_rhd_spi_master      │
                                                       35 slots/sweep, 119 clk   │
                                                                  │ slot stream  │
                                          ┌───────────────────────┴────────────┐ │
                                          ▼                                    ▼ │
                              argus_frame_assembler                  argus_feature
                              latest raw frame, held                 the codec, held
                                          │                                    │
                                          └────────► argus_acq_axi ◄───────────┘
                                                     ACQ3 register block ──► M_AXI_GP0
```

| file | role | numbers |
| --- | --- | --- |
| `rtl/argus_rhd2132_model.vhd` | RHD2132 chip model: register-accurate SPI behaviour, the ADC pipeline delay, a per-channel identity pattern, or samples from the fetcher in ext mode | 32 channels, 16-bit |
| `rtl/argus_rhd_spi_master.vhd` | The SPI master the real headstage would see: 32 amplifier slots and 3 aux slots per sweep, three chips on parallel MISO lanes | 119 clocks per slot, 30,012 sweeps/s at 125 MHz |
| `rtl/argus_sample_fetch.vhd` | Ext-mode source: plays samples out of two BRAM halves the PS refills; reports each half consumed and any underrun | 147 samples per half, 4.9 ms |
| `rtl/argus_frame_assembler.vhd` | The latest complete raw frame, double-buffered; `hold` freezes the read bank so 96 AXI reads see one sweep | `FRAME_INDEX` = sweep number |
| `rtl/argus_feature.vhd` | The codec (below) | 35 clocks per slot; one time-multiplexed datapath, three DSP48s |
| `rtl/argus_acq_axi.vhd` | AXI4-Lite register block, revision ACQ3 | 4 KB, ID `0x41435133` |
| `rtl/argus_acq_top.vhd` | The chain, instantiated in the block design as a module reference | ports: `s_axi_*`, `bram_*` |

The block design (`neural_codec`) is the Zynq PS, an AXI interconnect, the
module reference, and `axi_bram_ctrl` + `blk_mem_gen` at `0x40000000` for
the replay halves. The register block is at `0x43C00000`.

## The codec

Each channel's sample `code` (16-bit ADC) goes through, in fixed point:

```
x   = code − 32768
y   = (B0·(x − x₁) + A1·y₁ + 2¹⁴) >> 15          first-order high-pass, Q1.15, rounded
sq  = y²
u   = min(sq, T_prev)  once tracking                winsorised input
ms  = ms + ((u − ms + 2^(k−1)) >> k)               mean-square EMA, k = 8 until warm, then 15
T   = (ms · 49) >> 2                               threshold = 3.5σ → 12.25 × mean-square
cross when  sq > T  and  y < 0  and  not in refractory  and  after warm-up
count += cross ;  power += sq                      per 50 ms bin (1,500 sweeps)
```

The rounding terms are not decoration: floor in the recursion biased the
filter by −10 codes and turned 4.5σ into 3.5σ. Both were caught by the
model's synthetic tests before the RTL existed.

| generic | value | meaning |
| --- | --- | --- |
| `B0`, `A1` | 31932, 31096 | 250 Hz high-pass at 30,012 Hz, Q1.15 |
| `MULT_NUM`, `MULT_SHIFT` | 49, 2 | threshold multiplier 12.25 = (3.5σ)² |
| `K`, `K_FAST` | 15, 8 | EMA shifts: 1.09 s tracking, 8.5 ms fast attack |
| `REFRAC` | 30 | refractory, sweeps (1 ms) |
| `WARMUP` | 32768 | sweeps before counting (1.09 s) |
| `BIN` | 1500 | sweeps per bin (50 ms) |
| `WINSOR` | 1 | clamp the EMA input at the threshold once tracking |

These are the values locked by decode accuracy on the Indy session
(`argus_sim/tools/decode_test.py`: counts + power at 3.5σ decode intent at
53.5 % against 49.9 % for the lab's spike-sorted units). Agreement with the
spike sorter was rejected as the metric early on; decode accuracy answers
the actual question.

Structure: one datapath serves all 96 channels from the slot stream, eleven
single-operation states per chip (the first draft did the EMA update and the
threshold multiply in one clock and missed 125 MHz by 2.3 ns). Per-channel
state lives in a 96 × 136-bit RAM — `x₁`, `y₁`, `ms`, the crossing latch,
the refractory counter, the running count and the 48-bit power sum — which
Vivado infers as distributed RAM. Completed bins move to a double-buffered
feature bank with the same `hold`/`held` handshake as the frame; a bin that
completes under a hold is deferred to the release, and `dropped` counts
the rare case of two.

## Register map (ACQ3)

| offset | name | | |
| --- | --- | --- | --- |
| `0x000` | `CTRL` | RW | bit 0 enable · 1 soft reset · 2 ext mode · 3 hold (frame) · 4 feat_hold |
| `0x004` | `STATUS` | RO | bit 0 ready · 1 overrun · 2 held · 3 feat_held |
| `0x008` | `FRAME_INDEX` | RO | sweep number of the frame in the read bank |
| `0x00C` | `ID` | RO | `0x41435133` "ACQ3" — the firmware checks this first |
| `0x010` | `REPLAY_STATUS` | RO | play half, consumed flags, underrun, row |
| `0x014` | `REPLAY_ACK` | WO | clear consumed 0/1, clear underrun |
| `0x018` | `FEATURE_INDEX` | RO | bins completed; the bank holds the latest |
| `0x01C` | `FEAT_DROPPED` | RO | bins lost to a hold longer than one bin |
| `0x100`–`0x27C` | `FRAME[0..95]` | RO | one 16-bit sample in the low half of each word |
| `0x400`–`0x6FC` | `FEATURE[0..95]` | RO | two words per channel: `sum[31:0]`, then `count[15:0]` over `sum[47:32]` |

Reads of `FRAME` and `FEATURE` go through a registered RAM port (two-cycle
read). To read coherently: set the hold bit, poll the held bit, read, clear
the hold. Unmapped addresses read `0xDEADBEEF`.

The revision in `ID` is bumped whenever the map or the fabric's behaviour
changes, and the firmware refuses to run against a revision it does not
know: `acq id=… EXPECTED … -- stale bitstream?` at boot means the platform
was not rebuilt after a gateware change. ACQ1 was the original chain, ACQ2
added the held frame read, ACQ3 the feature bank.

## Building

Headless, from the repository root, with Vivado 2026.1 on the path:

```bash
vivado -mode batch -source tools/build_bitstream.tcl argus_neural_codec.xpr
```

The script adds any `rtl/*.vhd` the project does not yet have, refreshes the
module reference (its out-of-context checkpoint goes stale otherwise, and
`reset_run synth_1` does not touch it), resets and runs synthesis through
`write_bitstream`, and then reports post-route slack and refuses to export
if either is negative. On success it writes `argus_neural_codec.xsa` with
the bitstream included and utilisation and timing reports under
`/tmp/argus_build/`. About three minutes.

The firmware's `tools/build_firmware.sh` consumes that XSA; the bringup
harness (`scripts/hwtest.sh --fabric --firmware`) runs both and then tests
the result on the board.

A change to `argus_acq_top`'s ports (not its internals) is the one thing
`update_module_reference` cannot do; the module has to be removed from the
block design and re-added, as `tools/bd_add_bram.tcl` does. Internal
changes, including new entities, need only the build script.

## Simulating

```bash
cd sim && make            # all seven benches, about five minutes
make tb_argus_feature     # one bench
make synth                # ghdl --synth of argus_acq_top: catches non-synthesisable VHDL early
```

| bench | proves |
| --- | --- |
| `tb_argus_rhd2132_model` | the chip model's pipeline depth and channel identity |
| `tb_argus_rhd_spi_master` | the slot pipeline, three lanes, sweep coherence, aux slots, SCLK timing |
| `tb_argus_sample_fetch` | lane addressing, row advance, consumed/ack, underrun |
| `tb_argus_frame_assembler` | electrode mapping, double buffering, frame indexing |
| `tb_argus_frame_assembler_hold` | the freeze, index freeze, a slow coherent read, release |
| `tb_argus_feature` | **bit-exactness**: real samples in, every (bin, channel, count, power) against the model's golden |
| `tb_argus_acq_top` | the whole chain through AXI: address map, enable, sweep rate, held frame read, the feature bank, soft reset |

`tb_argus_feature` reads a replay `.bin` directly and a golden file the
model wrote for it. The committed pair under `sim/data/` is the CI case —
the first 6,000 rows of the Indy segment at reduced parameters (`ms_shift`
11, `warmup` 2048, `bin` 100) so every arithmetic path runs in about three
minutes. To regenerate it after a change to the model's arithmetic:

```bash
head -c $((6000*96*2)) ~/argus_data/indy_20161005_06_s120_10s.bin > sim/data/feature_ci.dat
python3 <argus_ws>/src/argus_sim/tools/spike_features.py sim/data/feature_ci.dat \
    --mult 3.5 --ms-shift 11 --warmup 2048 --bin 100 --golden sim/data/feature_ci_golden.txt
```

The production-parameter run (48,000 sweeps, about fifteen minutes in
GHDL) is a local check: `make tb_argus_feature FEATURE_BIN=… FEATURE_GOLDEN=…
FEATURE_GENERICS= STOP_TIME=600ms`, with a golden made at `--mult 3.5` and
defaults otherwise.

Every file is VSG-clean: `vsg --fix -c vsg.yaml -f rtl/X.vhd` for RTL,
`vsg --fix -c vsg.yaml sim/vsg_tb.yaml -f sim/tb_X.vhd` for benches. CI
runs the linter, all seven benches, and the synthesis check on every push.

## What it has been checked against

- The model, in GHDL: 5,760 pairs at reduced parameters, and the full
  48,000-sweep run at production parameters, both exact.
- The model, on silicon: `argus_sim/tools/hw_bitexact.py` captures the
  frames the firmware sends and compares them to the model run on the same
  samples — 139,200 / 139,200 over 72.5 s, counts and `sum / 1500` power.
- The board, every change: the bringup harness programs it and judges a
  live run before a hardware-affecting commit lands.

## Data

The samples in `sim/data/` and in the replay files are from O'Doherty,
Cardoso, Makin & Sabes, session `indy_20161005_06`
([10.5281/zenodo.1419774](https://doi.org/10.5281/zenodo.1419774)),
CC-BY-4.0, converted to RHD2132 codes at 30,012 Hz by
`argus_sim/tools/nwb_to_replay.py`. No other data live in this repository.

## Relationship to the rest of the stack

This repository is the fabric only. The wire contract is in
[argus_core](https://github.com/Max-Gabriel-Susman/argus_core); the
firmware that reads these registers is in
[argus_safety_controller](https://github.com/Max-Gabriel-Susman/argus_safety_controller);
the model, the datasets and the validation tools are in
[argus_sim](https://github.com/Max-Gabriel-Susman/argus_sim) and
[argus_data](https://github.com/Max-Gabriel-Susman/argus_data); the launch
and the hardware harness are in
[argus_bringup](https://github.com/Max-Gabriel-Susman/argus_bringup), whose
README is the overview of the whole system.

## License

Apache-2.0.
