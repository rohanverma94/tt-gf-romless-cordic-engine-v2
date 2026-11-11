# pins.tcl — where the eight SPI-side signals sit on the board's 40-pin header J7.
#
# The balls are the ones printed on the board next to each header pin (read
# from the board's assembly drawing). Pin numbers assume the usual numbering:
# pin 1 at the PIN1 mark (5V0), odd pins in that column, even pins in the other.
# If in doubt, go by the printed ball name, not the pin number.
#
# build.tcl checks that every ball exists, is used once, and is in a 3.3 V
# bank (84, 86 or 87).
#
# Inputs are on the PIN1 column, next to the GND at pin 37; outputs are on the
# other column, a few rows up, so SCLK is not beside MISO.
#
#            signal       ball      J7 pin   Pico harness pin
set HDR(sclk)        D11  ;# 35       <- GP2
set HDR(mosi)        J12  ;# 33       <- GP3
set HDR(cs_n)        J14  ;# 31       <- GP5
set HDR(proto)       F13  ;# 29       <- GP6
set HDR(cpha)        F14  ;# 27       <- GP7
set HDR(miso)        H14  ;# 30       -> GP4
set HDR(data_ready)  F12  ;# 28       -> GP8
set HDR(busy)        H12  ;# 26       -> GP9
# GND: J7 pins 37 and 38 (also pin 2). Do not use pin 1 (5 V) or pins 39/40 (3.3 V).
