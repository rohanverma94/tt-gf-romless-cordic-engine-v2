// tt_um_xcordic — standalone Xcordic: all 20 Xcordic instructions behind SPI
// with a legacy mode pin-compatible with tt_um_romless_cordic_engine (ttsky25a).
//
//   ui[0] SCLK     ui[1] MOSI     ui[2] CS_N    (as ttsky25a)
//   ui[3] PROTO    0: legacy 8-byte in / 6-byte out frame   1: command frames
//   ui[4] CPHA     0: SPI mode 0 (as ttsky25a)              1: SPI mode 1
//   uo[0] MISO     uo[1] DATA_READY (as ttsky25a)           uo[2] BUSY
//
// SPI_SCLK = 0: oversampled SPI slave (xc_spi_slave), SCLK up to clk/4.
// SPI_SCLK = 1: SCLK-domain shift registers (xc_spi_slave_sclk), e.g. 66.7 MHz
//               SCLK at a 100 MHz clk; needs SCLK as a clock in the flow (sta.sdc).
// GUARD = 0: the ttsky25a 16-bit datapath (bit-exact for rot/sincos with the
// silicon when atan1 = 0x0758); GUARD = 4: 20-bit datapath, ~1 LSB.
// See docs/info.md for the protocols.
`timescale 1ns/1ps
`default_nettype none

module tt_um_xcordic #(
    parameter FUNCS = 1,
    parameter GUARD = 4,
    parameter TIMEOUT_LOG2 = 24,
    parameter SPI_SCLK = 0
)(
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    assign uio_out = 8'd0;
    assign uio_oe  = 8'd0;
    wire _unused = &{ena, uio_in, ui_in[7:5], 1'b0};

    wire       miso, data_ready, busy;
    wire [7:0] rx_data, tx_data, tx_next;
    wire       rx_valid, cs_on, frame_start, frame_end;

    generate if (SPI_SCLK) begin : g_spi
        xc_spi_slave_sclk spi (
            .clk(clk), .rst_n(rst_n), .cpha(ui_in[4]),
            .sclk(ui_in[0]), .mosi(ui_in[1]), .miso(miso), .cs_n(ui_in[2]),
            .tx_data(tx_data), .tx_next(tx_next), .rx_data(rx_data), .rx_valid(rx_valid),
            .cs_on(cs_on), .frame_start(frame_start), .frame_end(frame_end)
        );
    end else begin : g_spi
        xc_spi_slave spi (
            .clk(clk), .rst_n(rst_n), .cpha(ui_in[4]),
            .sclk(ui_in[0]), .mosi(ui_in[1]), .miso(miso), .cs_n(ui_in[2]),
            .tx_data(tx_data), .tx_next(tx_next), .rx_data(rx_data), .rx_valid(rx_valid),
            .cs_on(cs_on), .frame_start(frame_start), .frame_end(frame_end)
        );
    end endgenerate

    // frame -> self-test (xc_bist, transparent except cordic.bist) -> core
    wire        f_start, f_busy, f_done;
    wire [6:0]  f_funct7;
    wire [2:0]  f_funct3;
    wire [31:0] f_rs1, f_rs2, f_rd;
    wire [1:0]  f_flags, c_flags;           // {INV, SAT} (v1.0)
    wire        c_start, c_busy, c_done;
    wire [6:0]  c_funct7;
    wire [2:0]  c_funct3;
    wire [31:0] c_rs1, c_rs2, c_rd;

    xc_frame #(.FUNCS(FUNCS), .GUARD(GUARD), .TIMEOUT_LOG2(TIMEOUT_LOG2)) frame (
        .clk(clk), .rst_n(rst_n), .proto_pin(ui_in[3]),
        .rx_data(rx_data), .rx_valid(rx_valid), .cs_on(cs_on),
        .frame_start(frame_start), .frame_end(frame_end),
        .tx_data(tx_data), .tx_next(tx_next),
        .c_start(f_start), .c_funct7(f_funct7), .c_funct3(f_funct3),
        .c_rs1(f_rs1), .c_rs2(f_rs2), .c_busy(f_busy), .c_done(f_done), .c_rd(f_rd), .c_flags(f_flags),
        .data_ready(data_ready), .busy(busy)
    );

    xc_bist #(.FUNCS(FUNCS)) bist (
        .clk(clk), .rst_n(rst_n),
        .u_start(f_start), .u_funct7(f_funct7), .u_funct3(f_funct3),
        .u_rs1(f_rs1), .u_rs2(f_rs2), .u_busy(f_busy), .u_done(f_done), .u_rd(f_rd), .u_flags(f_flags),
        .c_start(c_start), .c_funct7(c_funct7), .c_funct3(c_funct3),
        .c_rs1(c_rs1), .c_rs2(c_rs2), .c_busy(c_busy), .c_done(c_done), .c_rd(c_rd), .c_flags(c_flags)
    );

    xcordic_core #(.FUNCS(FUNCS), .GUARD(GUARD)) core (
        .clk(clk), .rstn(rst_n), .start(c_start),
        .funct7(c_funct7), .funct3(c_funct3), .rs1(c_rs1), .rs2(c_rs2),
        .busy(c_busy), .done(c_done), .rd(c_rd), .flags(c_flags)
    );

    assign uo_out = {5'd0, busy, data_ready, miso};
endmodule

`default_nettype wire
