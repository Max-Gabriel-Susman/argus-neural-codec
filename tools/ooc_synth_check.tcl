# Out-of-context synthesis of one acquisition module, independent of the
# Vivado project. Reports post-synthesis timing against 125 MHz and
# utilisation. Run from the repo root, once per module.

set top  [lindex $argv 0]
set part xc7z020clg400-1
set out  /tmp/argus_ooc
file mkdir $out

read_vhdl [glob rtl/*.vhd]
synth_design -top $top -part $part -mode out_of_context

create_clock -period 8.000 -name clk [get_ports clk]

report_timing_summary -file $out/$top.timing.rpt
report_utilization    -file $out/$top.util.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "\n=== $top: WNS $wns ns ===\n"
