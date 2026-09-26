# tools/bd_add_bram.tcl
#
# Adds the replay sample BRAM to the neural_codec block design: an AXI BRAM
# Controller on the same interconnect as argus_acq_top, a Block Memory
# Generator behind it, and the BMG's port B wired to argus_acq_top's port-B
# master.
#
# Source from the Vivado Tcl console with the project open:
#
#   source /home/prometheus/Documents/argus-neural-codec/tools/bd_add_bram.tcl
#
# Then tools/build_bitstream.tcl as before.
#
# WHY THIS RECREATES THE MODULE CELL
#   update_module_reference compares against a cached elaboration that it
#   does not invalidate when the source changes, and returns silently with
#   nothing done. Removing the source from the project and adding it back
#   forces a fresh parse; deleting and recreating the cell then picks it up.
#   The cell's S_AXI connection and address are restored afterwards.
#
# Address: 0x40000000, 64 KB -- the first GP0 slot, below argus_acq_top at
# 0x43C00000. Both halves of 147 x 96 x 2 bytes fit in 56,448 of the 65,536.

set repo [get_property DIRECTORY [current_project]]
set top_src $repo/rtl/argus_acq_top.vhd

open_bd_design [get_files neural_codec.bd]

# -- 1. Make sure every RTL file is in the project. The module reference's
#       out-of-context synthesis resolves argus_acq_top's dependencies from
#       the project source set, so a file present on disk but never added --
#       argus_sample_fetch.vhd, the first time -- fails there with "no such
#       design unit" even though the OOC check, which reads rtl/ directly,
#       passed.
foreach f [glob $repo/rtl/*.vhd] {
  if {[get_files -quiet [file tail $f]] eq ""} {
    add_files -norecurse $f
  }
}

# -- 2. Force re-elaboration of argus_acq_top.
if {[get_bd_cells -quiet argus_acq_top_0] ne ""} {
  delete_bd_objs [get_bd_cells argus_acq_top_0]
}

remove_files [get_files $top_src]
add_files -norecurse $top_src
update_compile_order -fileset sources_1

create_bd_cell -type module -reference argus_acq_top argus_acq_top_0

if {[get_bd_pins -quiet argus_acq_top_0/bram_addr] eq ""} {
  error "argus_acq_top_0 still has no bram_* pins after re-adding the source.\
         Vivado is not parsing the new entity. Paste the output of\
         'get_bd_pins argus_acq_top_0/*' -- the port default or the attribute\
         block in rtl/argus_acq_top.vhd is the likely cause."
}

set have_bram_intf [expr {[get_bd_intf_pins -quiet argus_acq_top_0/bram] ne ""}]
puts "argus_acq_top_0 recreated; BRAM interface inferred: $have_bram_intf"

# bram_clk is inferred as an output clock interface and Vivado wants a
# frequency on it. Nothing consumes it -- port B is wired pin-by-pin -- but
# without this it raises a critical warning on every regeneration.
if {[get_bd_intf_pins -quiet argus_acq_top_0/bram_clk] ne ""} {
  set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_pins argus_acq_top_0/bram_clk]
}

# -- 3. Restore S_AXI onto the existing interconnect and pin the address.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config {
    Clk_master {Auto}
    Clk_slave  {Auto}
    Clk_xbar   {Auto}
    Master     {/processing_system7_0/M_AXI_GP0}
    Slave      {/argus_acq_top_0/S_AXI}
    ddr_seg    {Auto}
    intc_ip    {/ps7_0_axi_periph}
    master_apm {0}
  } \
  [get_bd_intf_pins argus_acq_top_0/S_AXI]

set acq_seg [get_bd_addr_segs \
              -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
              -filter {NAME =~ "*argus_acq_top*"}]
set_property offset 0x43C00000 $acq_seg
set_property range  4K         $acq_seg

# -- 4. AXI BRAM Controller, single port, 32-bit, AXI4-Lite.
if {[get_bd_cells -quiet axi_bram_ctrl_0] eq ""} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl_0
  set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.PROTOCOL {AXI4LITE} \
  ] [get_bd_cells axi_bram_ctrl_0]
}

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

# -- 5. The memory. Created explicitly rather than by automation so that
#       true-dual-port with an exposed port B is set before generation.
#       Width and depth on port A come from the controller by propagation;
#       port B follows.
if {[get_bd_cells -quiet blk_mem_gen_0] eq ""} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen blk_mem_gen_0
  set_property -dict [list \
    CONFIG.use_bram_block {BRAM_Controller} \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Use_RSTB_Pin {true} \
  ] [get_bd_cells blk_mem_gen_0]
}

if {[get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA]] eq ""} {
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] \
                      [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTA]
}

# -- 6. Port B to the fetcher: one interface net if Vivado inferred the
#       interface, otherwise the seven pins individually.
if {$have_bram_intf} {
  connect_bd_intf_net [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTB] \
                      [get_bd_intf_pins argus_acq_top_0/bram]
} else {
  foreach {mine theirs} {
    bram_clk  clkb
    bram_rst  rstb
    bram_en   enb
    bram_we   web
    bram_addr addrb
    bram_din  dinb
    bram_dout doutb
  } {
    connect_bd_net [get_bd_pins argus_acq_top_0/$mine] [get_bd_pins blk_mem_gen_0/$theirs]
  }
}

# -- 7. Pin the BRAM address.
set bram_seg [get_bd_addr_segs \
               -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
               -filter {NAME =~ "*axi_bram_ctrl*"}]
if {[llength $bram_seg] != 1} {
  error "expected one address segment for axi_bram_ctrl_0, found: $bram_seg"
}
set_property offset 0x40000000 $bram_seg
set_property range  64K        $bram_seg

# -- 8. Validate, save, regenerate, export the source of truth.
validate_bd_design
save_bd_design
generate_target all [get_files neural_codec.bd]
write_bd_tcl -force $repo/neural_codec_bd.tcl

puts ""
puts "argus_acq_top_0  at [get_property offset $acq_seg], range [get_property range $acq_seg]"
puts "axi_bram_ctrl_0  at [get_property offset $bram_seg], range [get_property range $bram_seg]"
puts "Cells: [get_bd_cells]"
puts ""
puts "Review the diagram -- BMG port B should run to argus_acq_top_0 -- then:"
puts "  source $repo/tools/build_bitstream.tcl"
puts ""
