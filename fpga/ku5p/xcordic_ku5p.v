// xcordic_ku5p.v — tt_um_xcordic on the KU5P board (XCKU5P-2FFVB676I), for
// bring-up with the Pico harness. The RTL in ../../src is used unchanged.
//
// Clock: the board's 50 MHz oscillator (E18) into an MMCM. CLK_DIV sets the
// core clock: 1000 MHz / CLK_DIV, so 40 -> 25 MHz (the GF26c target clock),
// 25 -> 40 MHz. build.tcl sets it from the clock asked for.
//
// 40-pin header (3.3 V, banks 86/87), to the Pico harness's default pins:
//   sclk   <- Pico GP2    ui[0]        miso       -> Pico GP4   uo[0]
//   mosi   <- Pico GP3    ui[1]        data_ready -> Pico GP8   uo[1]
//   cs_n   <- Pico GP5    ui[2]        busy       -> Pico GP9   uo[2]
//   proto  <- Pico GP6    ui[3]
//   cpha   <- Pico GP7    ui[4]
// ui[5..7] are tied low. The header balls are in pins.tcl (J7 pins 26..35).
//
// LEDs: 0 DATA_READY, 1 BUSY, 2 CS active, 3 PROTO, 4 reset, 5 heartbeat.
// KEY1 resets the design; it also resets at configuration and until the MMCM locks.
`timescale 1ns/1ps
`default_nettype none

`ifndef XC_GUARD
`define XC_GUARD 4
`endif
`ifndef XC_CLK_DIV
`define XC_CLK_DIV 40.0
`endif

module xcordic_ku5p (
    input  wire       clk50,        // 50 MHz, E18 (bank 67, 1.8 V)
    input  wire       key_n,        // KEY1, active low
    output wire [5:0] led,
    input  wire       sclk,
    input  wire       mosi,
    input  wire       cs_n,
    input  wire       proto,
    input  wire       cpha,
    output wire       miso,
    output wire       data_ready,
    output wire       busy
);
    // ---- clock: 50 MHz x 20 = 1000 MHz VCO, / XC_CLK_DIV
    wire clk50_b, clk_fb, clk_mm, clk, locked;
    IBUF u_ibuf (.I(clk50), .O(clk50_b));
`ifdef XC_NO_MMCM
    // simulation without the Xilinx library: the core runs on the 50 MHz input
    assign clk_fb = 1'b0;
    assign clk_mm = clk50_b;
    assign clk    = clk50_b;
    assign locked = 1'b1;
`else
    MMCME4_BASE #(
        .CLKIN1_PERIOD   (20.000),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (20.000),
        .CLKOUT0_DIVIDE_F(`XC_CLK_DIV)
    ) u_mmcm (
        .CLKIN1  (clk50_b),
        .CLKFBIN (clk_fb),
        .CLKFBOUT(clk_fb),
        .CLKOUT0 (clk_mm),
        .LOCKED  (locked),
        .PWRDWN  (1'b0),
        .RST     (1'b0),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB()
    );
    BUFG u_bufg (.I(clk_mm), .O(clk));
`endif

    // ---- reset: held for 2^16 clocks after lock, and while KEY1 is pressed
    (* ASYNC_REG = "TRUE" *) reg [1:0] key_s = 2'b00;
    always @(posedge clk) key_s <= {key_s[0], key_n};
    reg [16:0] por = 17'd0;
    always @(posedge clk or negedge locked)
        if (!locked)        por <= 17'd0;
        else if (!key_s[1]) por <= 17'd0;
        else if (!por[16])  por <= por + 17'd1;
    reg rst_n_q = 1'b0;
    always @(posedge clk) rst_n_q <= por[16];

    // ---- the design, as on the Tiny Tapeout pins
    wire [7:0] uo_out, uio_out, uio_oe;
    tt_um_xcordic #(.GUARD(`XC_GUARD)) dut (
        .ui_in  ({3'b000, cpha, proto, cs_n, mosi, sclk}),
        .uo_out (uo_out),
        .uio_in (8'h00),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (1'b1),
        .clk    (clk),
        .rst_n  (rst_n_q)
    );
    assign miso       = uo_out[0];
    assign data_ready = uo_out[1];
    assign busy       = uo_out[2];

    // ---- LEDs (LED_ACTIVE_LOW inverts them all)
    reg [25:0] beat = 26'd0;
    always @(posedge clk) beat <= beat + 26'd1;
    wire [5:0] led_i = {beat[24], ~rst_n_q, proto, ~cs_n, uo_out[2], uo_out[1]};
`ifdef LED_ACTIVE_LOW
    assign led = ~led_i;
`else
    assign led = led_i;
`endif

    wire _unused = &{uio_out, uio_oe, uo_out[7:3], beat[25], 1'b0};
endmodule

`default_nettype wire
