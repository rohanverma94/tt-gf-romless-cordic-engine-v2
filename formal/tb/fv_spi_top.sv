// fv_spi_top.sv — top for O1/N1: the slave under test with free inputs; the
// injected properties constrain sclk/mosi/cs_n/rst_n to the timed master.
`default_nettype none
module fv_spi_top (input wire clk, input wire rst_n, input wire sclk, input wire mosi,
                   input wire cs_n, input wire [7:0] tx_data, input wire [7:0] tx_next);
    wire miso, tx_req, rx_valid;
    wire [7:0] rx_data;
`ifdef SLAVE_ORIG
    SPI_Slave #(.DATA_WIDTH(8)) dut (
        .clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .tx_data(tx_data), .rx_data(rx_data), .tx_req(tx_req), .rx_valid(rx_valid));
`else
    wire cpha_in = `CPHA;
    xc_spi_slave dut (
        .clk(clk), .rst_n(rst_n), .cpha(cpha_in), .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .tx_data(tx_data), .tx_next(tx_next), .rx_data(rx_data), .rx_valid(rx_valid));
`endif
endmodule
`default_nettype wire
