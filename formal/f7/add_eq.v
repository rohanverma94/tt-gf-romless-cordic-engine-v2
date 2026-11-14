// F7: xc_add equals a + b + ci, every width used
module add_eq #(parameter W = 20) (input [W-1:0] a, input [W-1:0] b, input ci, output ok);
    wire [W-1:0] s;
    xc_add #(.W(W)) u (.a(a), .b(b), .ci(ci), .s(s));
    wire [W-1:0] r = a + b + {{(W-1){1'b0}}, ci};
    assign ok = (s == r);
endmodule
