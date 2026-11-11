# build.tcl — Vivado non-project build of xcordic_ku5p (called by build.sh).
#   vivado -mode batch -source build.tcl -tclargs <guard> <clk_mhz> [led_active_low]
set here [file dirname [file normalize [info script]]]
set guard [expr {[llength $argv] > 0 ? [lindex $argv 0] : 4}]
set mhz   [expr {[llength $argv] > 1 ? [lindex $argv 1] : 25}]
set ledn  [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0}]
set part  xcku5p-ffvb676-2-i
set name  xcordic_ku5p_g${guard}_${mhz}mhz
set out   $here/build/$name
file mkdir $out

# core clock = 1000 MHz / div; the MMCM takes steps of 0.125 from 2 to 128
set div [expr {1000.0 / $mhz}]
if {$div < 2.0 || $div > 128.0 || abs($div * 8 - round($div * 8)) > 1e-9} {
    error "clock $mhz MHz: 1000/$mhz = $div is not a divider the MMCM can make (multiples of 0.125, 2..128)"
}

# ---- header pins
source $here/pins.tcl
set sigs {sclk mosi cs_n proto cpha miso data_ready busy}
foreach s $sigs {
    if {![info exists HDR($s)] || $HDR($s) eq ""} { error "pins.tcl: no ball given for $s" }
}
set seen {}
foreach s $sigs {
    if {[lsearch -exact $seen $HDR($s)] >= 0} { error "pins.tcl: ball $HDR($s) is used twice" }
    lappend seen $HDR($s)
}

set src $here/../../src
set rtl [list $here/xcordic_ku5p.v]
foreach f {project.v xc_spi_slave.v xc_spi_slave_sclk.v xc_meta.v xc_frame.v xc_bist.v
           xc_exact.v xcordic_core.v xcordic_engine.v xcordic_atan.v xc_add.v} { lappend rtl $src/$f }
read_verilog $rtl
set defs [list XC_GUARD=$guard XC_CLK_DIV=[format %.3f $div]]
if {$ledn} { lappend defs LED_ACTIVE_LOW }
synth_design -top xcordic_ku5p -part $part -verilog_define $defs

read_xdc $here/xcordic_ku5p.xdc
foreach s $sigs {
    set pin [get_package_pins -quiet $HDR($s)]
    if {[llength $pin] != 1} { error "pins.tcl: $HDR($s) ($s) is not a ball of $part" }
    set bank [get_property BANK $pin]
    if {[lsearch -exact {84 86 87} $bank] < 0} {
        error "pins.tcl: $HDR($s) ($s) is in bank $bank, not one of the 3.3 V banks 84, 86, 87"
    }
    set_property -dict [list PACKAGE_PIN $HDR($s) IOSTANDARD LVCMOS33] [get_ports $s]
}
# idle levels when nothing is plugged in: CS_N high, the rest low
set_property PULLTYPE PULLUP   [get_ports cs_n]
set_property PULLTYPE PULLDOWN [get_ports {sclk mosi proto cpha}]
set_property -dict {DRIVE 8 SLEW SLOW} [get_ports {miso data_ready busy}]

opt_design
place_design
phys_opt_design
route_design
report_utilization     -file $out/utilization.rpt
report_timing_summary  -file $out/timing.rpt
report_io              -file $out/io.rpt
report_drc             -file $out/drc.rpt
set wns [get_property SLACK [get_timing_paths -setup]]
set whs [get_property SLACK [get_timing_paths -hold]]
puts "== $name: setup slack $wns ns, hold slack $whs ns"
if {$wns < 0 || $whs < 0} { error "timing not met" }
write_bitstream -force $out/$name.bit
file mkdir $here/prebuilt
file copy -force $out/$name.bit $here/prebuilt/$name.bit
puts "wrote prebuilt/$name.bit"
