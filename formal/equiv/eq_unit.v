// eq_unit.v — the instruction unit (self-test + core) as xc_frame sees it;
// built once from the reference RTL (equiv/ref/) and once from the new RTL (src/), then compared
// instruction by instruction by equiv.cpp.
`default_nettype none
module eq_unit #(parameter FUNCS = 1, parameter GUARD = 4) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [6:0]  funct7,
    input  wire [2:0]  funct3,
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    output wire        busy,
    output wire        done,
    output wire [31:0] rd,
    output wire [1:0]  flags
);
    wire        c_start, c_busy, c_done;
    wire [6:0]  c_f7;  wire [2:0] c_f3;
    wire [31:0] c_rs1, c_rs2, c_rd;
    wire [1:0]  c_flags;
    xc_bist #(.FUNCS(FUNCS)) bist (
        .clk(clk), .rst_n(rst_n),
        .u_start(start), .u_funct7(funct7), .u_funct3(funct3), .u_rs1(rs1), .u_rs2(rs2),
        .u_busy(busy), .u_done(done), .u_rd(rd), .u_flags(flags),
        .c_start(c_start), .c_funct7(c_f7), .c_funct3(c_f3), .c_rs1(c_rs1), .c_rs2(c_rs2),
        .c_busy(c_busy), .c_done(c_done), .c_rd(c_rd), .c_flags(c_flags));
    xcordic_core #(.FUNCS(FUNCS), .GUARD(GUARD)) core (
        .clk(clk), .rstn(rst_n), .start(c_start), .funct7(c_f7), .funct3(c_f3),
        .rs1(c_rs1), .rs2(c_rs2), .busy(c_busy), .done(c_done), .rd(c_rd), .flags(c_flags));
endmodule
`default_nettype wire
