// xc_frame.v — SPI byte stream <-> Xcordic instructions, two protocols.
//
// PROTO = 0, legacy (pin-compatible with the ttsky25a design, ROM-less CORDIC):
//   write 8 bytes {x, y, alpha, atan0} (16-bit words, little endian), wait for
//   DATA_READY, read 6 bytes {sin, cos, 0} (little endian). Bytes may come one
//   per CS frame (as the original requires) or several per frame. Executes
//   cordic.cfg atan0 := atan0, then cordic.rot({y, x}, alpha).
//   Fixes against the original cordic_fsm:
//     - a transaction left incomplete (lost byte, read before DATA_READY,
//       aborted host) is abandoned after 2^TIMEOUT_LOG2 cycles without a byte
//       (counted between bytes and from DATA_READY, not while the core runs),
//       so the next one is understood (the original stays misaligned forever)
//     - out_alpha (the residual angle) is returned as 0
//
// PROTO = 1, command: one CS frame per instruction, any Xcordic instruction.
//   MOSI: CMD, RS1[7:0], RS1[15:8], RS1[23:16], RS1[31:24], RS2[7:0] .. RS2[31:24]
//         CMD = {EXEC, 2'b00, op[4:0]},  op = funct7 * 8 + funct3 (0..19)
//         a frame shorter than 9 bytes leaves the missing bytes 0; EXEC needs >= 5
//   MISO: STATUS, RD[7:0], RD[15:8], RD[23:16], RD[31:24], then 0
//         STATUS = {SEQ[3:0], 1'b0, ERR, VALID, BUSY}, sampled when CS falls:
//           BUSY  an instruction is executing
//           VALID RD holds a result (SEQ counts completed instructions, mod 16)
//           ERR   the last EXEC was rejected (core busy, illegal op, frame too short)
//   The instruction starts when CS rises. Reading a result and starting the
//   next instruction can share one frame.
//
// The protocol is selected by the PROTO pin; it is taken over only while no
// transaction is in progress and CS is high.
`timescale 1ns/1ps
`default_nettype none

module xc_frame #(
    parameter FUNCS = 1,
    parameter GUARD = 0,
    parameter TIMEOUT_LOG2 = 24
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        proto_pin,
    // SPI slave
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        cs_on,
    input  wire        frame_start,
    input  wire        frame_end,
    output wire [7:0]  tx_data,
    output wire [7:0]  tx_next,
    // core
    output reg         c_start,
    output reg  [6:0]  c_funct7,
    output reg  [2:0]  c_funct3,
    output reg  [31:0] c_rs1,
    output reg  [31:0] c_rs2,
    input  wire        c_busy,
    input  wire        c_done,
    input  wire [31:0] c_rd,
    // pins
    output wire        data_ready,
    output wire        busy
);
    reg proto;                              // 0 legacy, 1 command

    // =====================================================================
    // legacy protocol
    // =====================================================================
    localparam [2:0] L_IDLE = 0, L_RX = 1, L_CFG = 2, L_ROT = 3, L_WAIT = 4, L_TX = 5;
    reg [2:0]  ls;
    reg [2:0]  lk;                          // byte index within the phase
    reg [63:0] lin;                         // {atan0, alpha, y, x}
    reg [47:0] lout;                        // {0, cos, sin}
    reg        lready;
    reg [TIMEOUT_LOG2-1:0] lquiet;          // cycles since the last byte
    wire       ltimeout = &lquiet;

    // byte at read position k, and k+1 (k = 0..5)
    function [7:0] lbyte(input [47:0] v, input [2:0] k);
        case (k)
            3'd0: lbyte = v[7:0];   3'd1: lbyte = v[15:8];  3'd2: lbyte = v[23:16];
            3'd3: lbyte = v[31:24]; 3'd4: lbyte = v[39:32]; 3'd5: lbyte = v[47:40];
            default: lbyte = 8'd0;
        endcase
    endfunction

    // =====================================================================
    // command protocol
    // =====================================================================
    reg [3:0]  ck;                          // bytes received in this frame (saturates)
    reg [7:0]  ccmd;
    reg [31:0] crs1, crs2;
    reg [31:0] crd;                         // last result
    reg        cvalid, cerr;
    reg [3:0]  cseq;
    reg        cexec;                       // the core is running a command-mode instruction
    reg        cpend;                       // an EXEC command byte arrived, frame end not yet seen
    reg [39:0] csnap;                       // {RD, STATUS} as seen by this frame
    wire [7:0] cstatus = {cseq, 1'b0, cerr, cvalid, c_busy || cexec};
    wire [4:0] cop = ccmd[4:0];
    wire       cop_ok = (FUNCS != 0) ? (cop <= 5'd19) : (cop <= 5'd7);

    function [7:0] cbyte(input [39:0] v, input [3:0] k);
        case (k)
            4'd0: cbyte = v[7:0];   4'd1: cbyte = v[15:8];  4'd2: cbyte = v[23:16];
            4'd3: cbyte = v[31:24]; 4'd4: cbyte = v[39:32];
            default: cbyte = 8'd0;
        endcase
    endfunction

    // =====================================================================
    // transmit bytes
    // =====================================================================
    wire [39:0] csrc = cs_on ? csnap : {crd, cstatus};      // live while idle
    // legacy: in the cycle a read byte completes the position is already the
    // next one, so a CS-high gap of a single cycle still loads the right byte (N2)
    wire [2:0] lk_cur = (rx_valid && ls == L_TX) ? lk + 3'd1 : lk;
    // in the frame_start cycle ck still holds the last frame's count (it is
    // cleared at the end of that cycle): use 0, so tx_data stays the STATUS
    // snapshot from CS fall to the first byte (the SCLK-domain slave may take
    // byte 0 in that cycle; N2 proves tx_data is constant there)
    assign tx_data = proto ? cbyte(csrc, (cs_on && !frame_start) ? ck : 4'd0) : lbyte(lout, lk_cur);
    wire [3:0] ck_next = (ck == 4'hf) ? 4'hf : ck + 4'd1;     // saturates with ck (N2)
    assign tx_next = proto ? cbyte(csrc, ck_next) : lbyte(lout, lk + 3'd1);

    // the pins drop DATA_READY / raise BUSY as soon as an EXEC command byte is
    // in, so a host polling them right after CS rises never sees the previous
    // instruction's "ready" (CS takes several core clocks to be seen; N2)
    assign data_ready = proto ? (cvalid && !c_busy && !cexec && !cpend) : lready;
    assign busy       = c_busy || cexec || cpend || (ls == L_CFG) || (ls == L_ROT) || (ls == L_WAIT);

    // =====================================================================
    // control
    // =====================================================================
    always @(posedge clk) begin
        c_start <= 1'b0;
        if (!rst_n) begin
            proto <= 1'b0;
            ls <= L_IDLE; lk <= 0; lin <= 0; lout <= 0; lready <= 0; lquiet <= 0;
            ck <= 0; ccmd <= 0; crs1 <= 0; crs2 <= 0; crd <= 0;
            cvalid <= 0; cerr <= 0; cseq <= 0; cexec <= 0; cpend <= 0; csnap <= 0;
            c_funct7 <= 0; c_funct3 <= 0; c_rs1 <= 0; c_rs2 <= 0;
        end else begin
            // take over the protocol pin only between transactions
            if (!cs_on && ls == L_IDLE && !cexec && !cpend && !c_busy) proto <= proto_pin;

            if (!proto) begin
                // ---------------- legacy ----------------
                // host inactivity only: the count restarts with every byte and
                // is held while the core computes, so DATA_READY opens a full
                // timeout window for the reads (N2)
                if (rx_valid || ls == L_WAIT) lquiet <= 0;
                else if (!ltimeout) lquiet <= lquiet + 1'b1;
                case (ls)
                    L_IDLE: begin
                        lk <= 0;
                        if (rx_valid) begin lin[7:0] <= rx_data; lk <= 1; ls <= L_RX; end
                    end
                    L_RX: begin
                        if (rx_valid) begin
                            case (lk)
                                3'd1: lin[15:8]  <= rx_data;  3'd2: lin[23:16] <= rx_data;
                                3'd3: lin[31:24] <= rx_data;  3'd4: lin[39:32] <= rx_data;
                                3'd5: lin[47:40] <= rx_data;  3'd6: lin[55:48] <= rx_data;
                                default: lin[63:56] <= rx_data;
                            endcase
                            lk <= lk + 1;
                            if (lk == 3'd7) ls <= L_CFG;
                        end else if (ltimeout) ls <= L_IDLE;
                    end
                    L_CFG: if (!c_busy) begin
                        // cordic.cfg atan0 := in_atan_0 (S3.12, scaled to the datapath)
                        c_funct7 <= 7'd0; c_funct3 <= 3'd7;
                        c_rs1 <= {{16{lin[63]}}, lin[63:48]} << GUARD;
                        c_rs2 <= 32'd0;
                        c_start <= 1'b1;
                        ls <= L_ROT;
                    end
                    L_ROT: if (!c_start && !c_busy) begin
                        // cordic.rot({y, x}, alpha)
                        c_funct7 <= 7'd0; c_funct3 <= 3'd0;
                        c_rs1 <= lin[31:0];
                        c_rs2 <= {16'd0, lin[47:32]};
                        c_start <= 1'b1;
                        ls <= L_WAIT;
                    end
                    L_WAIT: if (c_done && !c_start) begin
                        lout <= {16'd0, c_rd[15:0], c_rd[31:16]};   // {0, cos, sin}
                        lready <= 1'b1;
                        lk <= 0;
                        ls <= L_TX;
                    end
                    L_TX: begin
                        if (rx_valid) begin
                            lk <= lk + 1;
                            if (lk == 3'd5) begin lready <= 1'b0; ls <= L_IDLE; end
                        end else if (ltimeout) begin lready <= 1'b0; ls <= L_IDLE; end
                    end
                    default: ls <= L_IDLE;
                endcase
            end else begin
                // ---------------- command ----------------
                if (!cs_on) csnap <= {crd, cstatus};
                if (frame_start) ck <= 0;
                else if (rx_valid) begin
                    case (ck)
                        4'd0: begin ccmd <= rx_data; if (rx_data[7]) cpend <= 1'b1; end
                        4'd1: crs1[7:0]   <= rx_data;  4'd2: crs1[15:8]  <= rx_data;
                        4'd3: crs1[23:16] <= rx_data;  4'd4: crs1[31:24] <= rx_data;
                        4'd5: crs2[7:0]   <= rx_data;  4'd6: crs2[15:8]  <= rx_data;
                        4'd7: crs2[23:16] <= rx_data;  4'd8: crs2[31:24] <= rx_data;
                        default: ;
                    endcase
                    if (ck != 4'hf) ck <= ck + 1;
                end
                if (frame_start) begin crs1 <= 0; crs2 <= 0; ccmd <= 0; end
                // frame_end comes after the frame's last rx_valid; a frame_start in
                // the same cycle clears the frame registers only after this reads them
                if (frame_end) cpend <= 1'b0;
                if (frame_end && ccmd[7]) begin
                    if (ck >= 4'd5 && cop_ok && !c_busy && !cexec) begin
                        c_funct7 <= {5'd0, cop[4:3]}; c_funct3 <= cop[2:0];
                        c_rs1 <= crs1; c_rs2 <= crs2;
                        c_start <= 1'b1;
                        cexec <= 1'b1;
                        cerr <= 1'b0;
                    end else
                        cerr <= 1'b1;
                end
                if (cexec && c_done && !c_start) begin
                    crd <= c_rd;
                    cvalid <= 1'b1;
                    cseq <= cseq + 1'b1;
                    cexec <= 1'b0;
                end
            end
        end
    end
    // formal properties (formal/props), compiled only by the matching proof
`ifdef XC_FV_FRAME
`include "xc_frame_props.vh"
`endif
endmodule

`default_nettype wire
