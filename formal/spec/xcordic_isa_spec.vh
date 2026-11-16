// xcordic_isa_spec.vh — the Xcordic instruction encoding, for formal proofs
// and (through Verilator) for the toolchain checker.
//
// R-type in custom-0 (opcode 0001011). Legal encodings:
//   funct7 = 0, funct3 0..7           base passes
//   funct7 = 1, funct3 0..7           functions
//   funct7 = 2, funct3 0..3           functions
// With FUNCS = 0 only funct7 = 0 is legal.
// The register fields never affect legality. Unary instructions ignore rs2;
// their canonical (assembler/disassembler) form has rs2 = x0.

function sp_isa_legal(input [31:0] insn, input funcs);
    reg [6:0] f7;
    reg [2:0] f3;
    begin
        f7 = insn[31:25];
        f3 = insn[14:12];
        sp_isa_legal = (insn[6:0] == 7'b0001011) &&
                       ((f7 == 7'd0) ||
                        (funcs && f7 == 7'd1) ||
                        (funcs && f7 == 7'd2 && f3 <= 3'd3));
    end
endfunction

// operation number = funct7 * 8 + funct3 (0..19)
function [4:0] sp_isa_op(input [31:0] insn);
    sp_isa_op = {insn[26:25], insn[14:12]};
endfunction

// 1 when the instruction reads rs2
function sp_isa_binary(input [4:0] op);
    case (op)
        5'd0, 5'd3, 5'd7, 5'd11, 5'd12, 5'd16, 5'd17, 5'd19: sp_isa_binary = 1'b1;
        default:                                            sp_isa_binary = 1'b0;
    endcase
endfunction

// mnemonic, 16 ASCII characters, left aligned, NUL padded
function [127:0] sp_isa_name(input [4:0] op);
    case (op)
        5'd0:  sp_isa_name = "cordic.rot";
        5'd1:  sp_isa_name = "cordic.sincos";
        5'd2:  sp_isa_name = "cordic.vec";
        5'd3:  sp_isa_name = "cordic.mac";
        5'd4:  sp_isa_name = "cordic.ldiv";
        5'd5:  sp_isa_name = "cordic.hsincos";
        5'd6:  sp_isa_name = "cordic.hvec";
        5'd7:  sp_isa_name = "cordic.cfg";
        5'd8:  sp_isa_name = "cordic.sin";
        5'd9:  sp_isa_name = "cordic.cos";
        5'd10: sp_isa_name = "cordic.tan";
        5'd11: sp_isa_name = "cordic.atan2";
        5'd12: sp_isa_name = "cordic.hypot";
        5'd13: sp_isa_name = "cordic.exp";
        5'd14: sp_isa_name = "cordic.ln";
        5'd15: sp_isa_name = "cordic.sqrt";
        5'd16: sp_isa_name = "cordic.mul";
        5'd17: sp_isa_name = "cordic.div";
        5'd18: sp_isa_name = "cordic.tanh";
        5'd19: sp_isa_name = "cordic.rotc";
        default: sp_isa_name = 128'd0;
    endcase
endfunction
