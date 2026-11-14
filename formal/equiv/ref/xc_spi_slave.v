// xc_spi_slave.v — SPI slave (CPOL = 0, mode 0 or mode 1), MSB first, any
// number of bytes per CS frame. Replaces the ttsky25a SPI_Slave, fixing:
//
//   - MOSI was sampled raw, 3-4 core clocks after the SCLK edge: a mode-0
//     master changes MOSI on the falling edge, so SCLK high had to exceed
//     4 core clocks (~6 MHz at 50 MHz). Here MOSI goes through the same
//     2-flop synchronizer as SCLK and is sampled as it was at the edge.
//   - MISO changed on the master's launch edge, half an SCLK period before the
//     next sample. Here the next bit is driven right after the master's sample
//     edge: it has a full SCLK period to settle.
//   - The first bit appeared 3-4 core clocks after CS fell. Here the shifter
//     follows tx_data while CS is high, so the MSB is valid when CS falls.
//   - Only one byte per CS frame was possible (the shifter reloaded only on CS
//     falling). Here it reloads after every 8th bit.
//
// cpha = 0: master samples MISO and drives MOSI on rising/falling edges (mode 0)
// cpha = 1: master drives on rising, samples on falling (mode 1)
// The slave samples MOSI on the master's sample edge and advances MISO right
// after it, in both modes.
//
// FSM interface (a byte position advances when rx_valid pulses):
//   tx_data   byte for the current position; followed while CS is high, so it
//             is the first byte of the next frame
//   tx_next   byte for the position after it; taken at the end of each byte
//             inside a frame (multi-byte frames), so the next MSB goes out with
//             no extra latency
//   rx_data   valid with the rx_valid pulse, once per complete byte
//   frame_start pulse when the synchronized CS falls; frame_end one cycle after
//             it rises, so always after the last rx_valid of the frame; a byte cut
//             short by CS rising is dropped
`timescale 1ns/1ps
`default_nettype none

module xc_spi_slave (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cpha,
    input  wire       sclk,
    input  wire       mosi,
    output reg        miso,
    input  wire       cs_n,
    input  wire [7:0] tx_data,
    input  wire [7:0] tx_next,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output wire       cs_on,
    output wire       frame_start,
    output reg        frame_end
);
    // 2-flop synchronizers; SCLK and MOSI share the same latency
    reg [1:0] sclk_s, mosi_s, cs_s;
    reg       sclk_d, cs_d;
    always @(posedge clk) begin
        if (!rst_n) begin
            sclk_s <= 2'b00; mosi_s <= 2'b00; cs_s <= 2'b11;
            sclk_d <= 1'b0; cs_d <= 1'b0;
        end else begin
            sclk_s <= {sclk_s[0], sclk};
            mosi_s <= {mosi_s[0], mosi};
            cs_s   <= {cs_s[0], cs_n};
            sclk_d <= sclk_s[1];
            cs_d   <= ~cs_s[1];
        end
    end
    assign cs_on       = ~cs_s[1];
    assign frame_start = cs_on & ~cs_d;
    always @(posedge clk)
        if (!rst_n) frame_end <= 1'b0; else frame_end <= ~cs_on & cs_d;
    wire rise   = sclk_s[1] & ~sclk_d;
    wire fall   = ~sclk_s[1] & sclk_d;
    wire sample = cs_on & (cpha ? fall : rise);

    reg [7:0] tx_sh, rx_sh;
    reg [2:0] bitn;
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_sh <= 8'd0; rx_sh <= 8'd0; bitn <= 3'd0;
            miso <= 1'b0; rx_data <= 8'd0; rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (!cs_on) begin
                // idle: follow tx_data, so the MSB is on MISO when CS falls
                bitn  <= 3'd0;
                tx_sh <= tx_data;
                miso  <= tx_data[7];
            end else if (sample) begin
                rx_sh <= {rx_sh[6:0], mosi_s[1]};
                bitn  <= bitn + 3'd1;
                if (bitn == 3'd7) begin
                    // byte complete: deliver it, start the next one
                    rx_data  <= {rx_sh[6:0], mosi_s[1]};
                    rx_valid <= 1'b1;
                    tx_sh    <= tx_next;
                    miso     <= tx_next[7];
                end else begin
                    tx_sh <= {tx_sh[6:0], 1'b0};
                    miso  <= tx_sh[6];
                end
            end
        end
    end
endmodule

`default_nettype wire
