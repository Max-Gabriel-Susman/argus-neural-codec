# tools/build_bitstream.tcl
#
# Synthesis, implementation, bitstream, and hardware export for neural_codec.
# Source from the Vivado Tcl console with the project open, after
# tools/bd_add_acq.tcl:
#
#   source /home/prometheus/Documents/argus-neural-codec/tools/build_bitstream.tcl
#
# Several minutes. Refuses to export if implemented timing fails, so a
# marginal design cannot reach the Vitis platform by accident.

set repo [get_property DIRECTORY [current_project]]
set xsa  $repo/argus_neural_codec.xsa
set out  /tmp/argus_build
file mkdir $out

# -- 0. Pre-flight. Building without the acquisition cell produces a
#       PS7-only bitstream that implements cleanly and says nothing; check
#       before spending minutes on it.
open_bd_design [get_files neural_codec.bd]
if {[get_bd_cells -quiet argus_acq_top_0] eq ""} {
  error "argus_acq_top_0 is not in the block design. Run tools/bd_add_acq.tcl first."
}

# -- 1. Full flow through bitstream. reset_run first so a stale synth_1 from
#       the PS7-only design cannot be reused.
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 did not complete: [get_property STATUS [get_runs impl_1]]"
}

# -- 2. Open the implemented design. close_design first in case a previous
#       open_run left a netlist open; this does not touch the block design.
catch {close_design}
open_run impl_1

# -- 3. Timing gate. Post-route numbers, so these are real, not the OOC
#       estimates from ooc_synth_check.tcl.
set setup_paths [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup]
set hold_paths  [get_timing_paths -quiet -max_paths 1 -nworst 1 -hold]

if {[llength $setup_paths] == 0} {
  error "no timed paths in the implemented design -- the PL is empty.\
         Did tools/bd_add_acq.tcl run? Check get_bd_cells."
}

set wns [get_property SLACK $setup_paths]
set whs [get_property SLACK $hold_paths]

report_timing_summary -file $out/timing.rpt
report_utilization -hierarchical -file $out/utilization.rpt

puts ""
puts "=== implemented: WNS $wns ns, WHS $whs ns ==="
puts "    reports in $out"
puts ""

if {$wns < 0 || $whs < 0} {
  error "timing failed -- not exporting. See $out/timing.rpt"
}

# -- 4. Export with the bitstream. First time this design has had one.
write_hw_platform -fixed -include_bit -force $xsa

puts "exported $xsa with bitstream"
puts ""
puts "Next, in Vitis:"
puts "  1. arty_z7_platform -> Settings -> vitis-comp.json -> Update XSA"
puts "  2. Build the platform, then safety_controller"
puts "  3. In safety_controller -> _ide -> launch.json, re-tick Program Device"
puts "     -- the platform now carries a bitstream, and the PL must be"
puts "     configured before the first AXI access or the A9 hangs on it."
puts ""
