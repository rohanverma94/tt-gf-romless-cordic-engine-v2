// xc_spi_slave_sclk.v — SPI slave with its shift registers clocked by SCLK.
// Same interface and FSM contract as xc_spi_slave (CPOL = 0, mode 0 or 1, MSB
// first, any number of bytes per CS frame), for SCLK faster than the core clock
// can oversample: 66.7 MHz SCLK with a 100 MHz core clock is proved (N1S).
//
// Partitioning:
//   SCLK domain   bits. sck = SCLK ^ CPHA: MOSI is sampled on the rising edge of
//                 sck (the master's sample edge), MISO is launched on its
//                 falling edge (the master's launch edge). The bit counter and
//                 launch state are reset asynchronously while CS is high. No
//                 synchronizer sits in the bit path, so the bit rate is limited
//                 only by I/O timing (tools/sta.sh), not by the core clock.
//   clk domain    bytes. Each received byte flips a toggle; the toggle crosses a
//                 2-flop synchronizer and rx_data takes the byte register, which
//                 holds still for the next 8 SCLK periods. Transmit bytes go the
//                 other way: the SCLK domain takes tx_data at the first launch
//                 of a frame (byte 0) and tx_next with the last bit sampled of
//                 each byte (the byte after it), while the FSM holds them still
//                 (contract below).
//   CS            asynchronous reset of the SCLK-domain control; into the clk
//                 domain through a synchronizer that sees CS fall after 2 flops
//                 and rise only after CS_OFF flops, so the last byte's rx_valid
//                 always comes while cs_on is still high (or as it falls).
//
// FSM contract (proved for xc_frame by N2):
//   tx_data   unchanged from the last cycle before frame_start until the first
//             rx_valid of the frame; byte 0 = that value.
//   tx_next   inside a frame, changes only in the cycle after rx_valid or after
//             frame_start; byte n+1 = its value at the rx_valid of byte n.
// Host requirements (N1S): CS setup, CS hold, CS high time and byte time as in
// docs/info.md; at 100 MHz all are a few core clocks.
`timescale 1ns/1ps
`default_nettype none

module xc_spi_slave_sclk #(
    parameter CS_OFF = 4                // flops before cs_on sees CS rise (>= 3)
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cpha,
    input  wire       sclk,
    input  wire       mosi,
    output wire       miso,
    input  wire       cs_n,
    input  wire [7:0] tx_data,
    input  wire [7:0] tx_next,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output wire       cs_on,
    output wire       frame_start,
    output reg        frame_end
);
    // =====================================================================
    // SCLK domain
    // =====================================================================
    wire sck = sclk ^ cpha;             // posedge: sample; negedge: launch

    // receive: bits sampled in the current byte
    reg [2:0] sc;
    always @(posedge sck or posedge cs_n)
        if (cs_n) sc <= 3'd0; else sc <= sc + 3'd1;
    reg [6:0] rsh;
    reg [7:0] rbyte;
    always @(posedge sck) begin
        rsh <= {rsh[5:0], mosi};
        if (sc == 3'd7) rbyte <= {rsh, mosi};
    end
    reg rtog;                           // flips once per received byte
    always @(posedge sck or negedge rst_n)
        if (!rst_n) rtog <= 1'b0; else if (sc == 3'd7) rtog <= ~rtog;

    // next byte: taken from tx_next on the edge that samples the last bit of
    // the current byte, while the clk domain cannot have seen that byte yet, so
    // tx_next is still the byte for the next position. (Taking it later, at
    // the next byte's first launch, fails when the master pauses between bytes:
    // by then the FSM has counted the byte and moved tx_next on. Found by N1S.)
    reg [7:0] tn;
    always @(posedge sck) if (sc == 3'd7) tn <= tx_next;

    // transmit: ld = a bit has been launched in this frame. Before that MISO
    // shows tx_data[7] (the MSB a mode-0 master samples on its first edge).
    // Each launch with sc == 0 (or the first launch of the frame) starts a byte.
    reg ld;
    always @(negedge sck or posedge cs_n)
        if (cs_n) ld <= 1'b0; else ld <= 1'b1;
    reg [7:0] tb;
    reg       mo;
    wire [7:0] nb    = ld ? tn : tx_data;
    wire       nbyte = (sc == 3'd0) || !ld;
    always @(negedge sck)
        if (nbyte) begin tb <= nb; mo <= nb[~sc]; end
        else             mo <= tb[~sc];
    assign miso = ld ? mo : tx_data[7];

    // =====================================================================
    // clk domain
    // =====================================================================
    wire cs_m, tog_m;
    xc_meta m_cs  (.d(cs_n), .q(cs_m));
    xc_meta m_tog (.d(rtog), .q(tog_m));

    reg [CS_OFF-1:0] cs_s;
    reg              cs_d;
    always @(posedge clk)
        if (!rst_n) begin cs_s <= {CS_OFF{1'b1}}; cs_d <= 1'b0; end
        else begin cs_s <= {cs_s[CS_OFF-2:0], cs_m}; cs_d <= cs_on; end
    assign cs_on       = ~&cs_s[CS_OFF-1:1];   // falls after 2 flops, rises after CS_OFF
    assign frame_start = cs_on & ~cs_d;
    always @(posedge clk)
        if (!rst_n) frame_end <= 1'b0; else frame_end <= ~cs_on & cs_d;

    reg [1:0] t_s;
    reg       t_d;
    always @(posedge clk)
        if (!rst_n) begin
            t_s <= 2'b00; t_d <= 1'b0; rx_valid <= 1'b0; rx_data <= 8'd0;
        end else begin
            t_s <= {t_s[0], tog_m};
            t_d <= t_s[1];
            rx_valid <= t_s[1] ^ t_d;
            if (t_s[1] ^ t_d) rx_data <= rbyte;
        end
endmodule

`default_nettype wire
