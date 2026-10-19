#!/usr/bin/env bash
# basys3_check.sh: is this Basys 3 still alive?
#
#   xilinx                              # your alias that sources Vivado's settings64.sh
#   bash ~/Downloads/basys3_check.sh
#
# Checks in order: USB enumeration, Digilent udev rule, the FPGA on JTAG, XADC die temperature
# and rails, configuration (builds and programs a self-test design), UART loopback. Then it
# prints what to look for on the board. Files go to ~/basys3_selftest and a rerun reuses the
# bitstream. Other Digilent boards (the Arty) can stay plugged in. JTAG programming is volatile:
# the board's QSPI flash is not touched.

set -u

WORK="$HOME/basys3_selftest"
MSG="basys3-loopback"

say()  { printf '\n==== %s ====\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*"; }
die()  { printf '\nFAIL: %s\n' "$*"; exit 1; }

# put FILE: write stdin to FILE only when the content changed, so the cached bitstream stays valid
put() {
    local tmp
    tmp=$(mktemp) || die "mktemp failed"
    cat > "$tmp"
    if cmp -s "$tmp" "$1"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$1" && chmod 644 "$1"
    fi
}

# uart_loopback PORT: the self-test wires RX to TX, so whatever goes out must come straight back.
# Raw mode with echo off matters: a tty that echoes would bounce the bytes around the loop forever.
uart_loopback() {
    local port=$1 reply="" n
    stty -F "$port" 115200 raw -echo -crtscts clocal || return 1
    exec 3<>"$port" || return 1
    stty -F "$port" 115200 raw -echo -crtscts clocal
    for ((n = 0; n < 200; n++)); do
        IFS= read -r -t 0.1 -N 1 _ <&3 || break        # drop anything already queued
    done
    printf '%s' "$MSG" >&3
    IFS= read -r -t 2 -N "${#MSG}" reply <&3
    exec 3<&-
    if [ "$reply" = "$MSG" ]; then
        echo "PASS: sent \"$MSG\" to $port and got it back"
    else
        echo "FAIL: sent \"$MSG\" to $port, got \"$reply\""
        return 1
    fi
}

main() {
    command -v vivado >/dev/null 2>&1 \
        || die "vivado is not on PATH. Run your 'xilinx' alias in this terminal, then rerun."

    say "USB"
    if command -v lsusb >/dev/null 2>&1; then
        local ftdi
        ftdi=$(lsusb -d 0403:6010)
        [ -n "$ftdi" ] || die "no Digilent USB-JTAG chip (FTDI 0403:6010) on USB. Check: the PROG/UART micro-USB port, a data cable (not charge-only), JP2 on USB, power switch on, power LED lit."
        printf '%s\n' "$ftdi"
        echo "($(printf '%s\n' "$ftdi" | wc -l) FT2232 device(s); any other Digilent board plugged in is listed too)"
    else
        warn "lsusb not found (sudo apt install usbutils), skipping the USB check"
    fi

    say "Cable driver"
    if grep -qsi digilent /etc/udev/rules.d/*.rules; then
        echo "Digilent udev rule present"
    else
        warn "no Digilent udev rule in /etc/udev/rules.d. If Vivado finds no cable below, run this, replug the board and rerun:"
        echo "  cd \"${XILINX_VIVADO:-<Vivado install dir>}/data/xicom/cable_drivers/lin64/install_script/install_drivers\" && sudo ./install_drivers"
    fi

    say "Writing the self-test design to $WORK"
    mkdir -p "$WORK" || die "cannot create $WORK"

put "$WORK/basys3_selftest.v" <<'EOF_VERILOG'
// basys3_selftest.v: hardware check for a Digilent Basys 3 (XC7A35T-1CPG236C)
//
//   SW0..SW15          each switch lights the LED above it (LD0..LD15)
//   7-seg, left pair   seconds since programming, 00..99 (proves the 100 MHz clock)
//   7-seg, right pair  SW7..SW0 in hex (switches 1000 1000 show "88": every segment)
//   btnC held          lamp test: all 16 LEDs, every segment, every decimal point
//   btnL btnU btnD btnR one decimal point each, left to right
//   UART               RX wired straight back to TX, so bytes sent over USB echo back

module basys3_selftest #(
    parameter integer CLK_HZ       = 100_000_000, // clocks per counted second
    parameter integer REFRESH_BITS = 20           // 2^(REFRESH_BITS-2) clocks per digit
) (
    input  wire        clk,
    input  wire [15:0] sw,
    input  wire        btnC,
    input  wire        btnU,
    input  wire        btnL,
    input  wire        btnR,
    input  wire        btnD,
    output wire [15:0] led,
    output reg  [6:0]  seg,   // active low, seg[0] = CA ... seg[6] = CG
    output reg         dp,    // active low
    output reg  [3:0]  an,    // active low, an[0] = rightmost digit
    input  wire        RsRx,
    output wire        RsTx
);

    assign led  = btnC ? 16'hFFFF : sw;
    assign RsTx = RsRx;

    // Seconds counter, two decimal digits
    localparam integer TICK_W = $clog2(CLK_HZ);

    reg [TICK_W-1:0] tick     = 0;
    reg [3:0]        sec_ones = 4'd0;
    reg [3:0]        sec_tens = 4'd0;

    always @(posedge clk) begin
        if (tick == CLK_HZ - 1) begin
            tick <= 0;
            if (sec_ones == 4'd9) begin
                sec_ones <= 4'd0;
                sec_tens <= (sec_tens == 4'd9) ? 4'd0 : sec_tens + 4'd1;
            end else begin
                sec_ones <= sec_ones + 4'd1;
            end
        end else begin
            tick <= tick + 1'b1;
        end
    end

    // Display scan: ~2.6 ms per digit at 100 MHz, ~95 Hz per digit refresh
    reg [REFRESH_BITS-1:0] scan = 0;

    always @(posedge clk) begin
        scan <= scan + 1'b1;
    end

    reg [3:0] nibble;
    reg       dp_on;

    always @(*) begin
        case (scan[REFRESH_BITS-1 -: 2])
            2'd0:    begin an = 4'b1110; nibble = sw[3:0];  dp_on = btnR; end
            2'd1:    begin an = 4'b1101; nibble = sw[7:4];  dp_on = btnD; end
            2'd2:    begin an = 4'b1011; nibble = sec_ones; dp_on = btnU; end
            default: begin an = 4'b0111; nibble = sec_tens; dp_on = btnL; end
        endcase

        case (nibble)                  // active low, {g,f,e,d,c,b,a}
            4'h0:    seg = 7'b1000000;
            4'h1:    seg = 7'b1111001;
            4'h2:    seg = 7'b0100100;
            4'h3:    seg = 7'b0110000;
            4'h4:    seg = 7'b0011001;
            4'h5:    seg = 7'b0010010;
            4'h6:    seg = 7'b0000010;
            4'h7:    seg = 7'b1111000;
            4'h8:    seg = 7'b0000000;
            4'h9:    seg = 7'b0010000;
            4'hA:    seg = 7'b0001000;
            4'hB:    seg = 7'b0000011;
            4'hC:    seg = 7'b1000110;
            4'hD:    seg = 7'b0100001;
            4'hE:    seg = 7'b0000110;
            default: seg = 7'b0001110; // F
        endcase

        dp = ~dp_on;

        if (btnC) begin                // lamp test, still scanning one digit at a time
            seg = 7'b0000000;
            dp  = 1'b0;
        end
    end

endmodule
EOF_VERILOG

put "$WORK/basys3_selftest.xdc" <<'EOF_XDC'
## basys3_selftest.xdc: lines uncommented from Digilent's Basys-3-Master.xdc (rev B)

## 100 MHz clock
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## Switches
set_property -dict { PACKAGE_PIN V17   IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN V16   IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN W17   IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
set_property -dict { PACKAGE_PIN W15   IOSTANDARD LVCMOS33 } [get_ports {sw[4]}]
set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS33 } [get_ports {sw[5]}]
set_property -dict { PACKAGE_PIN W14   IOSTANDARD LVCMOS33 } [get_ports {sw[6]}]
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports {sw[7]}]
set_property -dict { PACKAGE_PIN V2    IOSTANDARD LVCMOS33 } [get_ports {sw[8]}]
set_property -dict { PACKAGE_PIN T3    IOSTANDARD LVCMOS33 } [get_ports {sw[9]}]
set_property -dict { PACKAGE_PIN T2    IOSTANDARD LVCMOS33 } [get_ports {sw[10]}]
set_property -dict { PACKAGE_PIN R3    IOSTANDARD LVCMOS33 } [get_ports {sw[11]}]
set_property -dict { PACKAGE_PIN W2    IOSTANDARD LVCMOS33 } [get_ports {sw[12]}]
set_property -dict { PACKAGE_PIN U1    IOSTANDARD LVCMOS33 } [get_ports {sw[13]}]
set_property -dict { PACKAGE_PIN T1    IOSTANDARD LVCMOS33 } [get_ports {sw[14]}]
set_property -dict { PACKAGE_PIN R2    IOSTANDARD LVCMOS33 } [get_ports {sw[15]}]

## LEDs
set_property -dict { PACKAGE_PIN U16   IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN E19   IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN U19   IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN V19   IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN U15   IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN V14   IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN V13   IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN V3    IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN W3    IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN U3    IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN P3    IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN N3    IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN P1    IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN L1    IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## 7-segment display (segments, decimal point, digit anodes)
set_property -dict { PACKAGE_PIN W7   IOSTANDARD LVCMOS33 } [get_ports {seg[0]}]
set_property -dict { PACKAGE_PIN W6   IOSTANDARD LVCMOS33 } [get_ports {seg[1]}]
set_property -dict { PACKAGE_PIN U8   IOSTANDARD LVCMOS33 } [get_ports {seg[2]}]
set_property -dict { PACKAGE_PIN V8   IOSTANDARD LVCMOS33 } [get_ports {seg[3]}]
set_property -dict { PACKAGE_PIN U5   IOSTANDARD LVCMOS33 } [get_ports {seg[4]}]
set_property -dict { PACKAGE_PIN V5   IOSTANDARD LVCMOS33 } [get_ports {seg[5]}]
set_property -dict { PACKAGE_PIN U7   IOSTANDARD LVCMOS33 } [get_ports {seg[6]}]

set_property -dict { PACKAGE_PIN V7   IOSTANDARD LVCMOS33 } [get_ports dp]

set_property -dict { PACKAGE_PIN U2   IOSTANDARD LVCMOS33 } [get_ports {an[0]}]
set_property -dict { PACKAGE_PIN U4   IOSTANDARD LVCMOS33 } [get_ports {an[1]}]
set_property -dict { PACKAGE_PIN V4   IOSTANDARD LVCMOS33 } [get_ports {an[2]}]
set_property -dict { PACKAGE_PIN W4   IOSTANDARD LVCMOS33 } [get_ports {an[3]}]

## Buttons
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports btnC]
set_property -dict { PACKAGE_PIN T18   IOSTANDARD LVCMOS33 } [get_ports btnU]
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports btnL]
set_property -dict { PACKAGE_PIN T17   IOSTANDARD LVCMOS33 } [get_ports btnR]
set_property -dict { PACKAGE_PIN U17   IOSTANDARD LVCMOS33 } [get_ports btnD]

## USB-UART (FTDI channel B)
set_property -dict { PACKAGE_PIN B18   IOSTANDARD LVCMOS33 } [get_ports RsRx]
set_property -dict { PACKAGE_PIN A18   IOSTANDARD LVCMOS33 } [get_ports RsTx]

## Configuration bank voltage (from the same file)
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
EOF_XDC

put "$WORK/build_and_program.tcl" <<'EOF_TCL'
# build_and_program.tcl: Basys 3 self-test, run by basys3_check.sh as
#   vivado -mode batch -notrace -nojournal -source build_and_program.tcl
#
# 1. find the xc7a35t on any JTAG cable (other boards can stay plugged in)
# 2. read die temperature and core rails from the XADC (works before configuration)
# 3. build the self-test bitstream (reused while it is newer than its sources)
# 4. program it; on success write build/jtag_target.txt for the UART check

set part   xc7a35tcpg236-1
set top    basys3_selftest
set here   [file dirname [file normalize [info script]]]
set outdir [file join $here build]
set bit    [file join $outdir $top.bit]
set srcs   [list [file join $here $top.v] [file join $here $top.xdc]]

proc banner {msg} { puts "\n==== $msg ====" }

banner "JTAG: looking for an xc7a35t on every cable"
open_hw_manager
connect_hw_server

set dev ""
set tgt ""
foreach t [get_hw_targets -quiet] {
    if {[catch {open_hw_target $t} err]} {
        puts "  $t: could not open ($err)"
        continue
    }
    set devs [get_hw_devices -quiet]
    if {[llength $devs] == 0} {
        puts "  $t: cable answers, but nothing on its JTAG chain"
    } else {
        puts "  $t: [join $devs {, }]"
    }
    set d [lindex [get_hw_devices -quiet xc7a35t*] 0]
    if {$d ne ""} {
        set dev $d
        set tgt $t
        break
    }
    close_hw_target $t
}

if {$dev eq ""} {
    if {[llength [get_hw_targets -quiet]] == 0} {
        banner "FAIL: Vivado sees no JTAG cable at all"
        puts "  Board on (power LED lit), data-capable cable, Digilent udev rule installed?"
        puts "  After fixing: replug the board, run 'pkill hw_server', rerun."
    } else {
        banner "FAIL: no xc7a35t on the cables listed above"
        puts "  A cable with nothing on its chain: the Basys 3's USB side works but the FPGA is not answering."
        puts "  Only other boards listed: the Basys 3 is not enumerating (cable, port, power switch)."
    }
    close_hw_manager
    return
}

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
banner "PASS: $dev answered on $tgt"

if {[catch {
    set sm [lindex [get_hw_sysmons -of_objects $dev] 0]
    refresh_hw_sysmon $sm
    puts [format "  XADC: die %s C, VCCINT %s V (nominal 1.0), VCCAUX %s V (nominal 1.8)" \
        [get_property TEMPERATURE $sm] [get_property VCCINT $sm] [get_property VCCAUX $sm]]
} err]} {
    puts "  XADC read skipped: $err"
}

set stale [expr {![file exists $bit]}]
foreach s $srcs {
    if {!$stale && [file mtime $s] > [file mtime $bit]} {
        set stale 1
    }
}

if {$stale} {
    banner "Building the bitstream (a few minutes)"
    file mkdir $outdir
    read_verilog [lindex $srcs 0]
    read_xdc     [lindex $srcs 1]
    synth_design -top $top -part $part
    opt_design
    place_design
    route_design
    write_bitstream -force $bit
} else {
    banner "Bitstream is newer than its sources, reusing it"
}

banner "Programming $dev"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev

set fh [open [file join $outdir jtag_target.txt] w]
puts $fh $tgt
close $fh

banner "PASS: configured, DONE is high"
close_hw_manager
EOF_TCL

    ls -l "$WORK"

    say "Vivado: JTAG scan, XADC, build, program"
    rm -f "$WORK/build/jtag_target.txt"
    cd "$WORK" || die "cannot cd to $WORK"
    vivado -mode batch -notrace -nojournal -log "$WORK/vivado.log" -source "$WORK/build_and_program.tcl"
    [ -s "$WORK/build/jtag_target.txt" ] \
        || die "Vivado stopped before the board was programmed; its last ==== line above says why (full log: $WORK/vivado.log)."

    say "UART loopback (FTDI channel B)"
    local target serial uart_result="skipped" ports=()
    target=$(< "$WORK/build/jtag_target.txt")
    serial=${target##*/}            # Digilent appends the channel letter to the USB serial number
    shopt -s nullglob
    ports=(/dev/serial/by-id/*"${serial%?}"*-if01-port0)
    shopt -u nullglob
    if [ "${#ports[@]}" -ne 1 ]; then
        warn "could not pick out the Basys 3's serial port (ls -l /dev/serial/by-id/), skipping"
    elif [ ! -r "${ports[0]}" ] || [ ! -w "${ports[0]}" ]; then
        warn "no permission on ${ports[0]}: sudo usermod -aG dialout \$USER, log out and back in, rerun"
    elif uart_loopback "${ports[0]}"; then
        uart_result="passed"
    else
        uart_result="FAILED (FTDI channel B, or FPGA pins A18/B18)"
    fi

    say "Automated checks done: FPGA found and configured, UART loopback $uart_result"
    cat <<'EOF_CHECKS'
Now check the board by eye:
  LD0..LD15     flip each switch; the LED above it follows
  left digits   count seconds from 00 (watch a clock for a minute)
  right digits  SW7..SW0 in hex; SW7 and SW3 up gives 88 = every segment
  hold btnC     lamp test: all LEDs, every segment and decimal point
  btnL/U/D/R    light the four decimal points, left to right
The self-test stays loaded until the board is powered off.
EOF_CHECKS
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
