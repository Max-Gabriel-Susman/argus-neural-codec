## constraints/argus_pmod_ja.xdc
##
## Arty Z7-20 Pmod JA: the SPI bus to external RHD2000-compatible chips, one
## MISO per lane. The top row follows the Digilent Pmod SPI convention
## (Type 2A), so a single-chip board or a ribbon cable to another FPGA's
## SPI Pmod lines up pin for pin; lanes 1 and 2 use the bottom row.
##
##   JA1  CS_n    Y18      JA7   MISO1  U18
##   JA2  MOSI    Y19      JA8   MISO2  U19
##   JA3  MISO0   Y16      JA9   (n/c)  W18
##   JA4  SCLK    Y17      JA10  (n/c)  W19
##   JA5/JA11 GND          JA6/JA12 3.3 V
##
## Pins and IOSTANDARD from Digilent's Arty-Z7-20-Master.xdc.

set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports spi_cs_n]
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 } [get_ports spi_mosi]
set_property -dict { PACKAGE_PIN Y17  IOSTANDARD LVCMOS33 } [get_ports spi_sclk]

## MISO inputs are pulled down, so a lane with nothing plugged in reads
## clean zeros rather than noise. The first register on each one is an IOB
## flop (attribute in argus_acq_top.vhd).
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33  PULLDOWN true } [get_ports {spi_miso[0]}]
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33  PULLDOWN true } [get_ports {spi_miso[1]}]
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33  PULLDOWN true } [get_ports {spi_miso[2]}]

## The bus runs at 20.8 MHz from a 125 MHz fabric clock and its timing at the
## far chip is calibrated at run time by MISO_DELAY, so these paths are not
## timed against the fabric clock. Without these, Vivado reports the ports
## as unconstrained I/O.
set_false_path -to   [get_ports {spi_cs_n spi_mosi spi_sclk}]
set_false_path -from [get_ports {spi_miso[*]}]
