module pads(input pad_in, output y_in, input a_out, output pad_out);
  wire one = 1'b1, zero = 1'b0;
  gf180mcu_ocd_io__in_c   u_in  (.PAD(pad_in), .Y(y_in), .PU(zero), .PD(zero));
  gf180mcu_ocd_io__bi_24t u_out (.A(a_out), .OE(one), .PAD(pad_out), .CS(one), .SL(zero), .IE(zero), .PU(zero), .PD(zero));
endmodule
