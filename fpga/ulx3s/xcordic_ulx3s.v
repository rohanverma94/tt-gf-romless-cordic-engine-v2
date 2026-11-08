// xcordic_ulx3s.v — tt_um_xcordic on a ULX3S (ECP5 LFE5U-85F), for bring-up
// with the Pico harness before silicon. The RTL in ../../src is used unchanged.
//
// Clock: the board's 25 MHz oscillator, the GF26c target clock. Build with
// CLK_MHZ=<f> to run the core from an ECP5 PLL instead (build.sh).
//
// Header J1 (3.3 V), Pico harness default pins:
//   gp[0] <- Pico GP2  SCLK      ui[0]      gn[0] -> Pico GP4  MISO        uo[0]
//   gp[1] <- Pico GP3  MOSI      ui[1]      gn[1] -> Pico GP8  DATA_READY  uo[1]
//   gp[5] <- Pico GP5  CS_N      ui[2]      gn[2] -> Pico GP9  BUSY        uo[2]
//   (CS_N moved from gp[2], J1-9+, to gp[5], J1-15+: J1-9 had a bad contact)
//   gp[3] <- Pico GP6  PROTO     ui[3]      gn[3] -> BUSY again, a spare pin for GP9
//   gp[4] <- Pico GP7  CPHA      ui[4]
// ui[5..7] are tied low, as with the DIP switches off on the demo board.
//
// LEDs: 0 DATA_READY, 1 BUSY, 2 CS active, 3 PROTO, 4 CPHA, 6 reset, 7 heartbeat.
// BTN1 (F1 on the silkscreen) resets the design; it also resets at power-up.
`timescale 1ns/1ps
`default_nettype none

`ifndef XC_GUARD
`define XC_GUARD 4
`endif

module xcordic_ulx3s (
    input  wire       clk_25mhz,
    input  wire [6:0] btn,          // btn[0] PWR is active low, btn[1..6] active high
    output wire [7:0] led,
    input  wire [5:0] gp,           // gp[0,1,3,4] -> ui[0,1,3,4], gp[5] -> ui[2] CS_N; gp[2] unused
    output wire [3:0] gn            // from uo[2:0]; gn[3] repeats BUSY
);
    // ---- clock
    wire clk;
`ifdef USE_PLL
    wire locked;
    xc_pll pll (.clkin(clk_25mhz), .clkout0(clk), .locked(locked));
`else
    wire locked = 1'b1;
    assign clk = clk_25mhz;
`endif

    // ---- reset: held for 2^16 clocks after configuration, and while BTN1 is pressed
    reg [16:0] por = 17'd0;
    always @(posedge clk)
        if (!locked || btn[1]) por <= 17'd0;
        else if (!por[16])     por <= por + 17'd1;
    reg rst_n_q = 1'b0;
    always @(posedge clk) rst_n_q <= por[16];

    // ---- the design, as on the Tiny Tapeout pins
    wire [7:0] uo_out, uio_out, uio_oe;
    tt_um_xcordic #(.GUARD(`XC_GUARD)) dut (
        .ui_in  ({3'b000, gp[4], gp[3], gp[5], gp[1:0]}),
        .uo_out (uo_out),
        .uio_in (8'h00),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (1'b1),
        .clk    (clk),
        .rst_n  (rst_n_q)
    );
    assign gn = {uo_out[2], uo_out[2:0]};   // BUSY on J1-9- and J1-11-

    // ---- LEDs
    reg [24:0] beat = 25'd0;
    always @(posedge clk) beat <= beat + 25'd1;
    assign led = {beat[24], ~rst_n_q, 1'b0, gp[4], gp[3], ~gp[5], uo_out[2], uo_out[1]};

    wire _unused = &{uio_out, uio_oe, uo_out[7:3], btn[0], btn[6:2], gp[2], 1'b0};
endmodule

`default_nettype wire
