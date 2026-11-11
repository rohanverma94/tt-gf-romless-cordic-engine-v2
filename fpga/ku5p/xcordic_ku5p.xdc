## xcordic_ku5p.xdc — fixed pins of the KU5P board (XCKU5P-2FFVB676I).
## Clock, key and LED balls are the ones the GPU project already uses on this
## board. The header pins come from pins.tcl (build.tcl applies them).

## 50 MHz oscillator: bank 67, powered from VADJ (1.8 V as shipped)
set_property -dict {PACKAGE_PIN E18  IOSTANDARD LVCMOS18} [get_ports clk50]
create_clock -period 20.000 -name clk50 [get_ports clk50]

## KEY1 (active low) and the six LEDs: 3.3 V banks 84 and 86
set_property -dict {PACKAGE_PIN AF14 IOSTANDARD LVCMOS33} [get_ports key_n]
set_property -dict {PACKAGE_PIN K10  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K9   IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J11  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN J10  IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN J9   IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN H9   IOSTANDARD LVCMOS33} [get_ports {led[5]}]

## The SPI pins are asynchronous to the core clock: the design samples them
## through its own synchronisers, and the formal proofs (N1, G1) cover any
## alignment. So they are not timed against the core clock here.
set_false_path -from [get_ports {sclk mosi cs_n proto cpha key_n}]
set_false_path -to   [get_ports {miso data_ready busy led[*]}]

## configuration, as in the GPU project's builds for this board
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
