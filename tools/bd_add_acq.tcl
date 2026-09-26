# tools/bd_add_acq.tcl
#
# Adds argus_acq_top to the neural_codec block design behind M_AXI_GP0.
# Source from the Vivado Tcl console with the project open:
#
#   source /home/prometheus/Documents/argus-neural-codec/tools/bd_add_acq.tcl
#
# Fast (a minute or so, mostly IP generation). Review the diagram when it
# finishes, then run tools/build_bitstream.tcl.
#
# Idempotent where practical: re-sourcing after a partial run does not add
# the sources twice or create a second module cell.

set repo [get_property DIRECTORY [current_project]]
set rtl  $repo/rtl

# -- 1. RTL into the project, by reference. rtl/ stays the source of truth
#       and CI keeps linting and simulating the same files Vivado builds.
foreach f [glob $rtl/*.vhd] {
  if {[get_files -quiet [file tail $f]] eq ""} {
    add_files -norecurse $f
  }
}
update_compile_order -fileset sources_1

# -- 2. Block design.
open_bd_design [get_files neural_codec.bd]

# -- 3. Module reference. The S_AXI interface is inferred from the s_axi_*
#       port names; AXI4-Lite because there are no burst signals.
if {[get_bd_cells -quiet argus_acq_top_0] eq ""} {
  create_bd_cell -type module -reference argus_acq_top argus_acq_top_0
}

# -- 4. Connection automation: interconnect, proc_sys_reset, clock and reset
#       fan-out, and a first address assignment. The M_AXI_GP0_ACLK already
#       wired to FCLK_CLK0 is reused.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config {
    Clk_master {Auto}
    Clk_slave  {Auto}
    Clk_xbar   {Auto}
    Master     {/processing_system7_0/M_AXI_GP0}
    Slave      {/argus_acq_top_0/S_AXI}
    ddr_seg    {Auto}
    intc_ip    {Auto}
    master_apm {0}
  } \
  [get_bd_intf_pins argus_acq_top_0/S_AXI]

# -- 5. Pin the address so the firmware's base #define survives regeneration.
#       0x43C00000 is the conventional first AXI-Lite slave on Zynq GP0;
#       4K matches the 12-bit address port.
set seg [get_bd_addr_segs \
          -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
          -filter {NAME =~ "*argus_acq_top*"}]
if {[llength $seg] != 1} {
  error "expected one address segment for argus_acq_top_0, found: $seg"
}
set_property offset 0x43C00000 $seg
set_property range  4K         $seg

# -- 6. Validate. The 41-2670 incomplete-address-path warning from the
#       FCLK0 change should be gone: M_AXI_GP0 now has a slave.
validate_bd_design
save_bd_design

# -- 7. Regenerate. Interconnect and reset IP are new, so this takes longer
#       than previous runs.
generate_target all [get_files neural_codec.bd]

# The wrapper is Vivado-managed and has no new external ports, but refresh
# it anyway so the .gen tree is consistent.
make_wrapper -files [get_files neural_codec.bd] -top
set_property top neural_codec_wrapper [current_fileset]
update_compile_order -fileset sources_1

# -- 8. Source of truth. The generated script now carries a module-reference
#       check, so it needs rtl/ in the project before it can be sourced.
write_bd_tcl -force $repo/neural_codec_bd.tcl

puts ""
puts "argus_acq_top_0 at [get_property offset $seg], range [get_property range $seg]"
puts "Cells: [get_bd_cells]"
puts ""
puts "Review the diagram, then:"
puts "  source $repo/tools/build_bitstream.tcl"
puts ""
