# gf_pads.tcl — delays of the GF26c user I/O pad cells (gf180mcu_ocd_io), as
# Tiny Tapeout configures them (tt-multiplexer rtl/tt_gf_gpio.v, ol2/tt_top):
#   ui_in, clk: gf180mcu_ocd_io__in_c   (CMOS input, no pulls)
#   uo_out:     gf180mcu_ocd_io__bi_24t (24 mA, fast slew, input disabled)
#   LIB=<pdk>/gf180mcuD/libs.ref/gf180mcu_ocd_io/lib/gf180mcu_ocd_io__tt_025C_3v30.lib \
#   TIN=<input slew ns> CL=<board load pF> sta -no_splash -exit formal/sta/gf_pads.tcl
read_liberty $env(LIB)
read_verilog [file join [file dirname [info script]] gf_pads.v]
link_design pads
set_input_transition $env(TIN) [get_ports {pad_in a_out}]
set_load $env(CL) [get_ports pad_out]
set_load 0.05 [get_ports y_in]
foreach {f t name} {pad_in y_in "in_c   pad -> core" a_out pad_out "bi_24t core -> pad"} {
  foreach rf {rise fall} {
    puts "== $name, $rf"
    report_checks -unconstrained -${rf}_from [get_ports $f] -to [get_ports $t] -digits 3
  }
}
