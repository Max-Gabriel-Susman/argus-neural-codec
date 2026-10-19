# tools/bd_add_pins.tcl
#
# Brings argus_acq_top's spi_* ports out of the neural_codec block design to
# Pmod JA, for an external chip on a lane (LANE_SRC = pins). Headless, from
# the repository root:
#
#   vivado -mode batch -source tools/bd_add_pins.tcl argus_neural_codec.xpr
#
# or from the Vivado Tcl console with the project open. Then
# tools/build_bitstream.tcl as before. Safe to run again: ports and nets
# that already exist are left alone.
#
# WHY update_module_reference AND NOT DELETE/RE-ADD
#   The first version of this script deleted the cell, removed and re-added
#   argus_acq_top.vhd, and recreated the cell, as bd_add_bram.tcl once did.
#   On Vivado 2026.1 that recreated cell came back from the cached
#   elaboration, without the new spi_* pins ("IP ... is restricted: Detected
#   changes to module reference file(s)"). update_module_reference, run by
#   build_bitstream.tcl straight afterwards, did pick them up ("Upgrade has
#   added port 'spi_cs_n'" ...) and kept every existing connection: S_AXI,
#   its address, BRAM port B. So this script does that, and only adds what
#   the upgrade cannot: the external ports, their nets, and the XDC.

set repo [get_property DIRECTORY [current_project]]
set xdc  $repo/constraints/argus_pmod_ja.xdc
set cell argus_acq_top_0

open_bd_design [get_files neural_codec.bd]

# -- 1. Re-elaborate the module reference so the cell grows the new pins.
#       The IP name is the cell's, not a fixed string: a recreated cell may
#       have become neural_codec_argus_acq_top_0_1.
set acq_ip [get_property -quiet CONFIG.Component_Name [get_bd_cells $cell]]
if {$acq_ip eq ""} {
  set acq_ip [lindex [get_ips -quiet *argus_acq_top*] 0]
}
update_module_reference $acq_ip

if {[get_bd_pins -quiet $cell/spi_sclk] eq ""} {
  error "$cell still has no spi_* pins after update_module_reference.\
         Paste the output of 'get_bd_pins $cell/*'."
}

# -- 2. The external ports, under the names the XDC uses, each connected
#       only if its cell pin is not already on a net.
proc argus_connect_port {port pin} {
  if {[get_bd_nets -quiet -of_objects [get_bd_pins $pin]] eq ""} {
    connect_bd_net [get_bd_ports $port] [get_bd_pins $pin]
  }
}

foreach p {spi_cs_n spi_sclk spi_mosi} {
  if {[get_bd_ports -quiet $p] eq ""} {
    create_bd_port -dir O $p
  }
  argus_connect_port $p $cell/$p
}

set w [get_property LEFT [get_bd_pins $cell/spi_miso]]
if {[get_bd_ports -quiet spi_miso] eq ""} {
  create_bd_port -dir I -from $w -to 0 spi_miso
}
argus_connect_port spi_miso $cell/spi_miso

# -- 3. The constraints, once.
if {[get_files -quiet -of_objects [get_filesets constrs_1] $xdc] eq ""} {
  add_files -fileset constrs_1 -norecurse $xdc
}

# -- 4. Validate, save, regenerate. The wrapper gains the external ports,
#       so it must be remade for synthesis to see them.
validate_bd_design
save_bd_design
generate_target all [get_files neural_codec.bd]
make_wrapper -files [get_files neural_codec.bd] -top
update_compile_order -fileset sources_1
write_bd_tcl -force $repo/neural_codec_bd.tcl

puts ""
puts "External ports: [lsort [get_bd_ports]]"
puts "Expect spi_cs_n, spi_sclk, spi_mosi out and spi_miso\[$w:0\] in among them. Then:"
puts "  vivado -mode batch -source tools/build_bitstream.tcl argus_neural_codec.xpr"
puts ""
