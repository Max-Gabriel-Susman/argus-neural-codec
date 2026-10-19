# tools/bd_add_pins.tcl
#
# Brings argus_acq_top's spi_* ports out of the neural_codec block design to
# Pmod JA, for an external chip on a lane (LANE_SRC = pins). Source from the
# Vivado Tcl console with the project open:
#
#   source /home/prometheus/Documents/argus-neural-codec/tools/bd_add_pins.tcl
#
# Then tools/build_bitstream.tcl as before.
#
# WHY THIS RECREATES THE MODULE CELL
#   Same reason as tools/bd_add_bram.tcl: the port list changed, and
#   update_module_reference compares against a cached elaboration it does
#   not invalidate. The cell is deleted, its source re-added, the cell
#   recreated, and every connection it had -- S_AXI, its address, and BRAM
#   port B -- restored before the new ports are made external.

set repo    [get_property DIRECTORY [current_project]]
set top_src $repo/rtl/argus_acq_top.vhd
set xdc     $repo/constraints/argus_pmod_ja.xdc

open_bd_design [get_files neural_codec.bd]

# -- 1. Every RTL file in the project (see bd_add_bram.tcl, step 1).
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

if {[get_bd_pins -quiet argus_acq_top_0/spi_sclk] eq ""} {
  error "argus_acq_top_0 has no spi_* pins after re-adding the source.\
         Vivado is not parsing the new entity. Paste the output of\
         'get_bd_pins argus_acq_top_0/*'."
}

if {[get_bd_intf_pins -quiet argus_acq_top_0/bram_clk] ne ""} {
  set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_pins argus_acq_top_0/bram_clk]
}

# -- 3. S_AXI back onto the existing interconnect, and the address pinned.
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

# -- 4. BRAM port B back to the replay memory.
if {[get_bd_intf_pins -quiet argus_acq_top_0/bram] ne ""} {
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

# -- 5. The new ports, external, under the names the XDC uses.
foreach p {spi_cs_n spi_sclk spi_mosi} {
  if {[get_bd_ports -quiet $p] eq ""} {
    create_bd_port -dir O $p
  }
  connect_bd_net [get_bd_ports $p] [get_bd_pins argus_acq_top_0/$p]
}

set w [get_property LEFT [get_bd_pins argus_acq_top_0/spi_miso]]
if {[get_bd_ports -quiet spi_miso] eq ""} {
  create_bd_port -dir I -from $w -to 0 spi_miso
}
connect_bd_net [get_bd_ports spi_miso] [get_bd_pins argus_acq_top_0/spi_miso]

# -- 6. The constraints, once.
if {[get_files -quiet -of_objects [get_filesets constrs_1] $xdc] eq ""} {
  add_files -fileset constrs_1 -norecurse $xdc
}

# -- 7. Validate, save, regenerate. The wrapper now has external ports, so
#       it must be remade for synthesis to see them.
validate_bd_design
save_bd_design
generate_target all [get_files neural_codec.bd]
make_wrapper -files [get_files neural_codec.bd] -top
update_compile_order -fileset sources_1
write_bd_tcl -force $repo/neural_codec_bd.tcl

puts ""
puts "argus_acq_top_0 at [get_property offset $acq_seg]; spi_* external on Pmod JA"
puts "External ports: [get_bd_ports]"
puts ""
puts "Review the diagram -- spi_cs_n, spi_sclk, spi_mosi out, spi_miso\[$w:0\] in -- then:"
puts "  source $repo/tools/build_bitstream.tcl"
puts ""
