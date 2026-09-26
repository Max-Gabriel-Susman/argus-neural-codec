# tools/bd_add_bram.tcl
#
# Adds the replay sample BRAM to the neural_codec block design: an AXI BRAM
# Controller on the same interconnect as argus_acq_top, a Block Memory
# Generator behind it, and the BMG's port B wired to argus_acq_top's BRAM
# master interface.
#
# Run AFTER updating rtl/argus_acq_top.vhd (which gains the bram_* ports)
# and re-sourcing nothing else. Source from the Vivado Tcl console with the
# project open:
#
#   source /home/prometheus/Documents/argus-neural-codec/tools/bd_add_bram.tcl
#
# Then tools/build_bitstream.tcl as before.
#
# Address: 0x40000000, 64 KB -- the first GP0 slot, below argus_acq_top at
# 0x43C00000. Both halves of 147 x 96 x 2 bytes fit in 56,448 of the 65,536.

set repo [get_property DIRECTORY [current_project]]

open_bd_design [get_files neural_codec.bd]

# -- 1. Pick up the new bram_* ports on the module reference. Vivado infers
#       a BRAM master interface from the X_INTERFACE_INFO attributes.
update_module_reference argus_acq_top_0

if {[get_bd_intf_pins -quiet argus_acq_top_0/BRAM] eq ""} {
  error "argus_acq_top_0 has no BRAM interface after refresh -- check the\
         x_interface_info attributes in rtl/argus_acq_top.vhd and that the\
         file in the project is the updated one"
}

# -- 2. AXI BRAM Controller, single port, 32-bit data. AXI4-Lite keeps the
#       interconnect path identical to argus_acq_top's.
if {[get_bd_cells -quiet axi_bram_ctrl_0] eq ""} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl_0
  set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.PROTOCOL {AXI4LITE} \
  ] [get_bd_cells axi_bram_ctrl_0]
}

# -- 3. Onto the interconnect.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config {
    Clk_master {Auto}
    Clk_slave  {Auto}
    Clk_xbar   {Auto}
    Master     {/processing_system7_0/M_AXI_GP0}
    Slave      {/axi_bram_ctrl_0/S_AXI}
    ddr_seg    {Auto}
    intc_ip    {/ps7_0_axi_periph}
    master_apm {0}
  } \
  [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]

# -- 4. The memory itself. Automation on BRAM_PORTA creates a BMG in
#       BRAM-controller mode; then make it true-dual-port so port B exists.
apply_bd_automation -rule xilinx.com:bd_rule:bram_cntlr \
  -config {BRAM "New Blk_Mem_Gen"} \
  [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA]

set bmg [get_bd_cells -quiet -filter {VLNV =~ "xilinx.com:ip:blk_mem_gen:*"}]
if {[llength $bmg] != 1} {
  error "expected exactly one blk_mem_gen after automation, found: $bmg"
}
set_property CONFIG.Memory_Type {True_Dual_Port_RAM} $bmg

# -- 5. Port B to the fetcher.
if {[get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins argus_acq_top_0/BRAM]] eq ""} {
  connect_bd_intf_net [get_bd_intf_pins $bmg/BRAM_PORTB] \
                      [get_bd_intf_pins argus_acq_top_0/BRAM]
}

# -- 6. Pin the address. Same reasoning as argus_acq_top: the firmware
#       hardcodes it, so it must not move on regeneration.
set seg [get_bd_addr_segs \
          -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
          -filter {NAME =~ "*axi_bram_ctrl*"}]
if {[llength $seg] != 1} {
  error "expected one address segment for axi_bram_ctrl_0, found: $seg"
}
set_property offset 0x40000000 $seg
set_property range  64K        $seg

# -- 7. Validate, save, regenerate, export the source of truth.
validate_bd_design
save_bd_design
generate_target all [get_files neural_codec.bd]
write_bd_tcl -force $repo/neural_codec_bd.tcl

puts ""
puts "axi_bram_ctrl_0 at [get_property offset $seg], range [get_property range $seg]"
puts "argus_acq_top_0 at [get_property offset [get_bd_addr_segs -of_objects \
       [get_bd_addr_spaces processing_system7_0/Data] -filter {NAME =~ "*argus_acq_top*"}]]"
puts "Cells: [get_bd_cells]"
puts ""
puts "Review the diagram -- BMG port B should run to argus_acq_top_0/BRAM -- then:"
puts "  source $repo/tools/build_bitstream.tcl"
puts ""
