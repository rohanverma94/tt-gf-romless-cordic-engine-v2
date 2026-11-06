// xc_add.v — W-bit adder with a Kogge-Stone carry network
//
// s = a + b + ci, modulo 2^W. Written out as generate/propagate prefixes so the
// carry chain is log2(W) levels deep whatever the synthesis script does with a
// plain `+` (in the earlier layout the engine's ripple-carry chains, 20 cells
// long, set the slow corner). Same value as a + b + ci (checked by F7).
`timescale 1ns/1ps
`default_nettype none

module xc_add #(
    parameter W = 20
)(
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         ci,
    output wire [W-1:0] s
);
    localparam integer L = (W <= 2) ? 1 : $clog2(W);
    // level k, bit i at [k*W + i]: generate / propagate of bits [i - 2^k + 1 .. i],
    // the carry-in folded into bit 0
    wire [(L+1)*W-1:0] G, P;
    wire [W-1:0] h = a ^ b;
    assign G[W-1:0] = (a & b) | {{(W-1){1'b0}}, h[0] & ci};
    assign P[W-1:0] = h;
    genvar k, i;
    generate
        for (k = 0; k < L; k = k + 1) begin : lvl
            for (i = 0; i < W; i = i + 1) begin : b
                if (i >= (1 << k)) begin : c
                    assign G[(k+1)*W + i] = G[k*W + i] | (P[k*W + i] & G[k*W + i - (1 << k)]);
                    assign P[(k+1)*W + i] = P[k*W + i] & P[k*W + i - (1 << k)];
                end else begin : t
                    assign G[(k+1)*W + i] = G[k*W + i];
                    assign P[(k+1)*W + i] = P[k*W + i];
                end
            end
        end
    endgenerate
    // the carry into bit i is the group generate of bits [0 .. i-1]; ci into bit 0
    assign s = h ^ {G[L*W + W-2 : L*W], ci};
endmodule

`default_nettype wire
