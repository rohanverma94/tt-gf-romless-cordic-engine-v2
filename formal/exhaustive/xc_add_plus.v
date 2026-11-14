// xc_add_plus.v — stand-in for src/xc_add.v in the exhaustive runs: the same
// function written as a + b + ci. F7 proves the two equal for every input at
// every width the design uses, and the simulator runs this form about five
// times faster than the prefix network. Used only with ADD=plus (run_pairs.sh).
`timescale 1ns/1ps
module xc_add #(
    parameter W = 20
)(
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         ci,
    output wire [W-1:0] s
);
    assign s = a + b + {{(W-1){1'b0}}, ci};
endmodule
