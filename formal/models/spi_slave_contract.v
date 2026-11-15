// spi_slave_contract.v — the byte-level contract of an SPI slave, as a module
// with the ttsky25a SPI_Slave's ports (replaces it in O2).
// Within each CS frame (synchronized CS low, 3-stage synchronizer as the
// original): exactly one tx_req and exactly one rx_valid, tx_req first, both
// while the CS pin is still low; rx_data with rx_valid is any byte (what the
// master sent). O1 proves the real slave keeps this for masters within the
// proven timing.
// The byte the master reads in a frame is tx_data in the cycle the synchronized
// CS falls (checked by the user of this contract, which mirrors the synchronizer).
`default_nettype none
module SPI_Slave #(parameter DATA_WIDTH = 8) (
    input  wire clk, input wire rst_n,
    input  wire sclk, input wire mosi, output reg miso, input wire cs_n,
    input  wire [DATA_WIDTH-1:0] tx_data,
    output reg  [DATA_WIDTH-1:0] rx_data,
    output reg  tx_req, output reg rx_valid
);
    (* anyseq *) wire f_req, f_rx;
    (* anyseq *) wire [DATA_WIDTH-1:0] f_byte;
    reg [2:0] cs_sync;
    reg       active;
    reg       had_req, had_rx;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cs_sync <= 3'b111; else cs_sync <= {cs_sync[1:0], cs_n};
    wire cs_falling = cs_sync[2:1] == 2'b10;
    wire cs_rising  = cs_sync[2:1] == 2'b01;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; had_req <= 0; had_rx <= 0;
            tx_req <= 0; rx_valid <= 0; rx_data <= 0; miso <= 0;
        end else begin
            tx_req <= 0; rx_valid <= 0;
            if (cs_falling) begin active <= 1; had_req <= 0; had_rx <= 0; end
            else if (cs_rising) active <= 0;
            if (active && !cs_rising && !cs_n) begin
                if (f_req && !had_req) begin tx_req <= 1; had_req <= 1; end
                else if (f_rx && had_req && !had_rx) begin rx_valid <= 1; rx_data <= f_byte; had_rx <= 1; end
            end
        end
    end
    // a frame cannot end before both pulses have happened
    always @* if (rst_n && active && cs_rising) assume(had_req && had_rx);
endmodule
`default_nettype wire
