// xc_meta.v — the input of a synchronizer's first flop. A wire in hardware.
//
// In the formal model (XC_FV_META, multiclock with a global time step), a
// signal that changed in the last time step may be caught by the first flop
// on either side of the change: the flop goes metastable and resolves to the
// old or the new value, freely. Every proof that involves a synchronizer is
// done with that freedom, so it holds however each crossing resolves.
`timescale 1ns/1ps
`default_nettype none

module xc_meta #(parameter W = 1) (
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
`ifdef XC_FV_META
    reg [W-1:0] d_prev;
    always @($global_clock) d_prev <= d;
    (* anyseq *) wire [W-1:0] pick;
    assign q = (d_prev & pick) | (d & ~pick);
`else
    assign q = d;
`endif
endmodule

`default_nettype wire
