# Out-of-context synthesis of one acquisition module, independent of the
# Vivado project. Reports post-synthesis timing against 125 MHz and
# utilisation. Run from the repo root, once per module:
#
#   vivado -mode batch -nojournal -nolog -source tools/ooc_synth_check.tcl -tclargs <top>
#
# The clock is applied after synthesis rather than before, so the timing is
# an estimate against a netlist that was not optimised for 125 MHz. That
# errs pessimistic, which is the right direction for a go/no-go check.

set top  [lindex $argv 0]
set part xc7z020clg400-1
set out  /tmp/argus_ooc
file mkdir $out

read_vhdl [glob rtl/*.vhd]
synth_design -top $top -part $part -mode out_of_context

# Leaf modules call their clock `clk`; the AXI-facing top uses the bus
# convention `s_axi_aclk`. Accept either.
set clk_port [get_ports -quiet {clk s_axi_aclk}]
if {[llength $clk_port] != 1} {
  puts "ERROR: expected exactly one clock port named clk or s_axi_aclk, found: $clk_port"
  exit 1
}
create_clock -period 8.000 -name clk $clk_port

report_timing_summary -file $out/$top.timing.rpt
report_utilization    -file $out/$top.util.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "\n=== $top: WNS $wns ns ===\n"
