// fv_bist_top.sv — F5: xc_bist with the core replaced by its contract
// (models/xcordic_core_abstract.v); source inputs are free.
`default_nettype none
module fv_bist_top #(parameter FUNCS = 1) (
    input wire clk, input wire rst_n,
    input wire u_start, input wire [6:0] u_funct7, input wire [2:0] u_funct3,
    input wire [31:0] u_rs1, input wire [31:0] u_rs2
);
    wire u_busy, u_done; wire [31:0] u_rd; wire [1:0] u_flags, c_flags;
    wire c_start, c_busy, c_done; wire [6:0] c_funct7; wire [2:0] c_funct3; wire [31:0] c_rs1, c_rs2, c_rd;
    xc_bist #(.FUNCS(FUNCS)) dut (
        .clk(clk), .rst_n(rst_n),
        .u_start(u_start), .u_funct7(u_funct7), .u_funct3(u_funct3), .u_rs1(u_rs1), .u_rs2(u_rs2),
        .u_busy(u_busy), .u_done(u_done), .u_rd(u_rd), .u_flags(u_flags),
        .c_start(c_start), .c_funct7(c_funct7), .c_funct3(c_funct3), .c_rs1(c_rs1), .c_rs2(c_rs2),
        .c_busy(c_busy), .c_done(c_done), .c_rd(c_rd), .c_flags(c_flags));
    xcordic_core #(.FUNCS(FUNCS)) core (
        .clk(clk), .rstn(rst_n), .start(c_start), .funct7(c_funct7), .funct3(c_funct3),
        .rs1(c_rs1), .rs2(c_rs2), .busy(c_busy), .done(c_done), .rd(c_rd), .flags(c_flags));
endmodule
`default_nettype wire
