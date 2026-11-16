// spi_master_model.v — a timed SPI master (CPOL = 0), in core-clock cycles.
//
// With STRETCH = 1 every phase may also last any longer, freely, so a proof
// holds for every master at least as slow as the minimums.
//
// Drives one byte per frame (CS low for exactly 8 SCLK periods, MSB first),
// or FRAME_BYTES bytes per frame when that parameter is > 1, then CS high for
// a gap. Every phase length is BASE or BASE + 1 cycles, chosen freely each
// time (anyseq): that is any asynchronous alignment between the master's SCLK
// and the core clock, for a master whose phases last at least BASE cycles.
//
//   CPHA = 0 (mode 0): MOSI set before the rising edge; master samples MISO on
//                      the rising edge, changes MOSI on the falling edge.
//   CPHA = 1 (mode 1): master changes MOSI on the rising edge and samples MISO
//                      on the falling edge.
//
// A sample "on an edge" is the MISO value in the cycle before SCLK changes,
// i.e. what a flop clocked by that SCLK edge captures.
//
// Outputs for checkers:
//   frame_start   pulse in the first cycle CS is low
//   byte_done     pulse after the last SCLK edge of each byte; m_tx = byte sent,
//                 m_rx = byte sampled from MISO
//   frame_end     pulse in the first cycle CS is high again
`timescale 1ns/1ps
`default_nettype none

module spi_master_model #(
    parameter CPHA = 0,
    parameter H = 4,            // SCLK high phase >= H cycles
    parameter L = 4,            // SCLK low phase  >= L cycles
    parameter S = 4,            // CS low -> first edge >= S cycles (S >= 1)
    parameter T = 4,            // last edge -> CS high >= T cycles
    parameter G = 6,            // CS high gap >= G cycles
    parameter FRAME_BYTES = 1,
    parameter JITTER = 1,       // 1: each phase lasts BASE or BASE+1 cycles
    parameter FREE = 0,         // 1: every byte is a free choice (next_byte unused)
    parameter STRETCH = 0       // 1: any phase may last longer than its minimum, freely
)(
    input  wire       clk,
    input  wire       run,          // may start a frame (from the gap)
    input  wire [7:0] next_byte,    // byte to send, sampled at each byte start
    input  wire       miso,
    output reg        sclk,
    output reg        mosi,
    output reg        cs_n,
    output reg        frame_start,
    output reg        frame_end,
    output reg        byte_done,
    output reg [7:0]  m_tx,
    output reg [7:0]  m_rx,
    output reg        in_frame,
    output wire       smp,          // this cycle's clock edge is a MISO sample edge
    output wire       rise,         // this cycle's clock edge raises SCLK
    output wire [7:0] cur_tx        // byte being sent
);
    (* anyseq *) wire j;            // jitter choice for the phase being loaded
    (* anyseq *) wire [7:0] free_byte;
    (* anyseq *) wire stretch;      // STRETCH: hold the current phase one more cycle
    wire hold_ph = (STRETCH != 0) && stretch;
    wire [7:0] nb = (FREE != 0) ? free_byte : next_byte;

    localparam [2:0] M_GAP = 0, M_SETUP = 1, M_HI = 2, M_LO = 3, M_HOLD = 4;
    reg [2:0] st = M_GAP;
    reg [7:0] cnt;
    reg [3:0] bitn = 4'd0;          // bits remaining in the byte
    reg [7:0] tx, rx, txs;           // txs: bits still to put on MOSI, MSB first
    reg [7:0] nbytes = 8'd0;        // bytes completed in this frame

    wire edge_up = (st == M_SETUP || st == M_LO) && cnt == 0 && !hold_ph && bitn != 0;
    wire edge_dn = (st == M_HI) && cnt == 0 && !hold_ph;
    assign rise = edge_up;
    assign cur_tx = tx;
    assign smp  = (CPHA == 0) ? edge_up : edge_dn;

    function [7:0] dur(input integer base);
        dur = base - 1 + ((JITTER != 0 && j) ? 1 : 0);
    endfunction

    initial begin
        sclk = 1'b0; cs_n = 1'b1; mosi = 1'b0;
        frame_start = 1'b0; frame_end = 1'b0; byte_done = 1'b0;
        in_frame = 1'b0; cnt = G;
        m_tx = 8'd0; m_rx = 8'd0; tx = 8'd0; rx = 8'd0; txs = 8'd0;
    end

    // MASTER_GCLK: run on the formal global time step (multiclock models, N1S),
    // where one step is a fraction of the core clock period
`ifdef MASTER_GCLK
    always @($global_clock) begin
`else
    always @(posedge clk) begin
`endif
        frame_start <= 1'b0;
        frame_end <= 1'b0;
        byte_done <= 1'b0;
        case (st)
            M_GAP: begin
                if (cnt != 0 || hold_ph) begin if (cnt != 0) cnt <= cnt - 1; end
                else if (run) begin
                    cs_n <= 1'b0;
                    in_frame <= 1'b1;
                    frame_start <= 1'b1;
                    tx <= nb;
                    if (CPHA == 0) begin mosi <= nb[7]; txs <= {nb[6:0], 1'b0}; end
                    else txs <= nb;
                    bitn <= 4'd8;
                    nbytes <= 0;
                    cnt <= dur(S);
                    st <= M_SETUP;
                end
            end
            M_SETUP, M_LO: begin
                if (cnt != 0 || hold_ph) begin if (cnt != 0) cnt <= cnt - 1; end
                else if (bitn == 0) begin
                    // byte complete (after its low phase)
                    if (nbytes + 1 < FRAME_BYTES) begin
                        nbytes <= nbytes + 1;
                        tx <= nb;
                        if (CPHA == 0) begin mosi <= nb[7]; txs <= {nb[6:0], 1'b0}; end
                        else txs <= nb;
                        bitn <= 4'd8;
                        cnt <= dur(L);         // the low phase continues as setup
                        st <= M_LO;
                    end else begin
                        cnt <= dur(T);
                        st <= M_HOLD;
                    end
                end else begin
                    sclk <= 1'b1;              // rising edge
                    if (CPHA == 0) rx <= {rx[6:0], miso};
                    else begin     mosi <= txs[7]; txs <= {txs[6:0], 1'b0}; end
                    cnt <= dur(H);
                    st <= M_HI;
                end
            end
            M_HI: begin
                if (cnt != 0 || hold_ph) begin if (cnt != 0) cnt <= cnt - 1; end
                else begin
                    sclk <= 1'b0;              // falling edge
                    if (CPHA == 1) rx <= {rx[6:0], miso};
                    if (CPHA == 0 && bitn > 1) begin mosi <= txs[7]; txs <= {txs[6:0], 1'b0}; end
                    bitn <= bitn - 1;
                    if (bitn == 1) begin
                        byte_done <= 1'b1;
                        m_tx <= tx;
                        m_rx <= (CPHA == 1) ? {rx[6:0], miso} : rx;
                    end
                    cnt <= dur(L);
                    st <= M_LO;
                end
            end
            M_HOLD: begin
                if (cnt != 0 || hold_ph) begin if (cnt != 0) cnt <= cnt - 1; end
                else begin
                    cs_n <= 1'b1;
                    in_frame <= 1'b0;
                    frame_end <= 1'b1;
                    cnt <= dur(G);
                    st <= M_GAP;
                end
            end
            default: st <= M_GAP;
        endcase
    end
endmodule

`default_nettype wire
