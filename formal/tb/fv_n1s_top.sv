// fv_n1s_top.sv — top for N1S: the SCLK-domain slave with free inputs; the
// injected properties tie clk, rst_n, sclk, mosi and cs_n to the time model.
`default_nettype none
module fv_n1s_top (input wire clk, input wire rst_n, input wire cpha, input wire sclk,
                   input wire mosi, input wire cs_n, input wire [7:0] tx_data,
                   input wire [7:0] tx_next);
    wire miso, rx_valid, cs_on, frame_start, frame_end;
    wire [7:0] rx_data;
    xc_spi_slave_sclk dut (
        .clk(clk), .rst_n(rst_n), .cpha(cpha), .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .tx_data(tx_data), .tx_next(tx_next), .rx_data(rx_data), .rx_valid(rx_valid),
        .cs_on(cs_on), .frame_start(frame_start), .frame_end(frame_end));
endmodule
`default_nettype wire
