// xc_frame_props.vh — included in xc_frame when XC_FV_FRAME is defined. N2.
//
// Environment (contracts proved elsewhere):
//   SPI slave (N1): cs_on is any sequence; frame_start = cs_on rising,
//     frame_end = one cycle after cs_on falls; rx_valid only if cs_on was high
//     in the previous cycle, at least 2 cycles after frame_start and after the
//     previous rx_valid (a real byte takes >= 16), with any rx_data. The byte
//     the master reads at frame position 0 is tx_data in the last cycle before
//     frame_start; at position n+1 it is tx_next in the cycle before the
//     rx_valid of byte n.
//   Core (F3a): xcordic_core_abstract (start/busy/done contract, any rd).
//
// N2L (`N2_LEGACY): proto pin 0. The master writes 8 bytes, ends its frame,
//   waits for DATA_READY, reads 6 bytes, any framing; repeatedly.
//   Theorem: each transaction issues exactly cordic.cfg(atan0 << GUARD) then
//   cordic.rot({y, x}, alpha) with the bytes written, and the 6 bytes read are
//   {sin, cos, 0} (little endian) of that rot's rd.
//   With `N2_FREE the master first does anything at all, then is quiet for
//   2^TIMEOUT_LOG2 cycles (CS high, no bytes): same theorem after that (recovery).
//
// N2S (`N2_SWITCH): the proto pin is any sequence at all, with any frames.
//   Theorem: the protocol changes only with CS high, the last frame closed
//   (its frame_end seen) and nothing open in either protocol; a frame moves
//   the queues (instruction accepted, result removed) only if it began in
//   command mode; no legacy transaction is open in command mode and no
//   command state is held in legacy mode. So a frame of one protocol is never
//   acted on by the other, whenever the pin moves.
// N2C (`N2_CMD): proto pin 1, any frames at all. Theorem (queues): a frame
//   with EXEC, >= 5 bytes and a legal op (0..19 or 20 = bist; FUNCS = 0: 0..7,
//   20) joins the instruction queue exactly when the queue has room, with
//   funct7/funct3 = op and rs1/rs2 = the frame's bytes (missing bytes 0); ERR
//   is set exactly by a rejected EXEC frame and cleared by an accepted one;
//   queued instructions start in order, one at a time, exactly when the core
//   is idle, nothing is in flight and the result queue has room; every result
//   joins the result queue with its number (completions mod 16); a frame of
//   >= 5 bytes whose STATUS showed VALID removes the oldest result; every MISO
//   byte of every frame is the STATUS/RD of the last cycle before the frame
//   (RD/SEQ = the oldest unread result, or the last completed one if none,
//   VALID = a result is unread, FULL = 4 instructions queued, BUSY = an
//   instruction queued or in flight), then 0; and the DATA_READY/BUSY pins
//   show not-ready from an EXEC command byte on.

reg [3:0] f_rst = 4'd0;
always @(posedge clk) if (!f_rst[3]) f_rst <= f_rst + 4'd1;
always @* assume(rst_n == f_rst[3]);
wire f_on = f_rst[3];
reg  f_on_d = 0;
always @(posedge clk) f_on_d <= f_on;
always @* if (f_on && !f_on_d) assume(!cs_on);   // PROTO is taken over before any frame

// ---------------- SPI contract ----------------
reg f_cs1 = 0, f_cs2 = 0;                  // cs_on one and two cycles ago
reg [1:0] f_rxgap = 0, f_fsgap = 0;
always @(posedge clk) begin
    f_cs1 <= cs_on; f_cs2 <= f_cs1;
    f_rxgap <= rx_valid ? 2'd0 : (f_rxgap == 2'd3 ? 2'd3 : f_rxgap + 2'd1);
    f_fsgap <= frame_start ? 2'd0 : (f_fsgap == 2'd3 ? 2'd3 : f_fsgap + 2'd1);
end
always @* begin
    assume(frame_start == (cs_on && !f_cs1));
    assume(frame_end == (!f_cs1 && f_cs2));
    if (rx_valid) assume(f_cs1 && f_rxgap >= 1 && f_fsgap >= 1);
    if (!f_on) assume(!cs_on && !rx_valid);
end
// what the master reads
reg [7:0] f_txd_d, f_txn_d;
always @(posedge clk) begin f_txd_d <= tx_data; f_txn_d <= tx_next; end
reg [7:0] f_byte0;                          // byte 0 of the current frame
always @(posedge clk) if (!cs_on) f_byte0 <= tx_data;
// byte the master gets at the current read position: at frame_start it has
// byte 0 (f_byte0); each rx_valid of a byte n is followed by byte n+1 = f_txn_d
reg [3:0] f_pos;                            // frame position of the byte now being shifted
always @(posedge clk) begin
    if (frame_start) f_pos <= 0;
    else if (rx_valid && f_pos != 15) f_pos <= f_pos + 1;
end
reg [7:0] f_cur;                            // byte the master is reading now
always @(posedge clk) begin
    if (frame_start) f_cur <= f_txd_d;      // the last idle cycle's tx_data
    else if (rx_valid) f_cur <= f_txn_d;
end
// the byte completed by an rx_valid was read by the master as f_cur (before update)

`ifdef N2_LEGACY
// =====================================================================
// legacy
// =====================================================================
always @* assume(!proto_pin);
(* anyseq *) wire f_go;
reg       f_wf;                             // master follows the protocol
reg [3:0] f_nw, f_nr;                       // bytes written / read in this transaction
reg       f_wph;                            // in the write phase
reg [TIMEOUT_LOG2:0] f_q;                   // quiet cycles (free phase)
reg [63:0] f_in;
reg [31:0] f_rot_rd;
reg [1:0]  f_starts;
reg        f_got;                           // rot result seen
reg [3:0]  f_txns;
`ifdef N2_FREE
initial f_wf = 0;
`else
initial f_wf = 1;
`endif
always @(posedge clk) begin
    if (!f_on) begin
        f_nw <= 0; f_nr <= 0; f_wph <= 1; f_q <= 0; f_starts <= 0; f_got <= 0; f_txns <= 0;
    end else begin
        if (!f_wf) begin
            // free phase: anything; quiet time counts CS high with no bytes
            if (cs_on || rx_valid) f_q <= 0;
            else if (!f_q[TIMEOUT_LOG2]) f_q <= f_q + 1;
            if (f_q[TIMEOUT_LOG2] && f_go) begin
                f_wf <= 1; f_nw <= 0; f_nr <= 0; f_wph <= 1; f_starts <= 0; f_got <= 0;
            end
        end else begin
            if (rx_valid) begin
                if (f_wph) begin
                    case (f_nw[2:0])
                        3'd0: f_in[7:0]   <= rx_data; 3'd1: f_in[15:8]  <= rx_data;
                        3'd2: f_in[23:16] <= rx_data; 3'd3: f_in[31:24] <= rx_data;
                        3'd4: f_in[39:32] <= rx_data; 3'd5: f_in[47:40] <= rx_data;
                        3'd6: f_in[55:48] <= rx_data; default: f_in[63:56] <= rx_data;
                    endcase
                    f_nw <= f_nw + 1;
                end else begin
                    f_nr <= f_nr + 1;
                    if (f_nr == 5) begin
                        f_wph <= 1; f_nw <= 0; f_nr <= 0; f_starts <= 0; f_got <= 0;
                        if (f_txns != 15) f_txns <= f_txns + 1;
                    end
                end
            end
            if (f_wph && f_nw == 8 && !cs_on) f_wph <= 0;
            if (c_start && f_starts != 3) f_starts <= f_starts + 1;
            if (c_done && f_starts == 2) begin f_rot_rd <= c_rd; f_got <= 1; end
        end
    end
end
// protocol: 8 write bytes, then CS high; reads begin only once DATA_READY is
// up. The master lowers the CS pin at or after DATA_READY rises, and the
// slave's 2-flop CS synchronizer makes cs_on follow 2 cycles later, so cs_on
// rises at least one cycle after DATA_READY (assumed here; reality gives two)
reg f_dr1 = 0;
always @(posedge clk) f_dr1 <= data_ready;
// the master does not pause for the timeout inside a transaction: between
// bytes, and from DATA_READY rising to the reads (2^TIMEOUT_LOG2 cycles; a
// margin of 4 cycles keeps the assumption on the master side of the edge)
reg [TIMEOUT_LOG2:0] f_mq = 0;
always @(posedge clk)
    f_mq <= (rx_valid || (data_ready && !f_dr1)) ? 0 : (f_mq[TIMEOUT_LOG2] ? f_mq : f_mq + 1);
always @* if (f_on && f_wf && ((f_wph && f_nw != 0 && f_nw != 8) || (!f_wph && data_ready)))
    assume(f_mq < (1 << TIMEOUT_LOG2) - 4);
always @* if (f_on && f_wf) begin
    if (f_wph && f_nw == 8) assume(!rx_valid && !(cs_on && !f_cs1));
    if (!f_wph && f_nr == 0 && cs_on && !f_cs1) assume(data_ready && f_dr1);
end
// in the protocol phase the first frame starts clean: no stray CS-low frame
// carried over from the free phase (the master raised CS for the quiet time)

wire [47:0] f_out = {16'd0, f_rot_rd[15:0], f_rot_rd[31:16]};
wire [47:0] f_out_sh = f_out >> {f_nr[2:0], 3'b000};

always @* if (f_on && f_wf) begin
    // the two instructions, in order, with the written bytes
    if (c_start) begin
        assert(f_nw == 8);
        assert(f_starts < 2);
        if (f_starts == 0)
            assert(c_funct7 == 0 && c_funct3 == 7 && c_rs1 == ({{16{f_in[63]}}, f_in[63:48]} << GUARD) && c_rs2 == 0);
        else
            assert(c_funct7 == 0 && c_funct3 == 0 && c_rs1 == f_in[31:0] && c_rs2 == {16'd0, f_in[47:32]});
    end
    // each read byte is the result
    if (rx_valid && !f_wph) begin
        assert(f_got);
        assert(f_cur == f_out_sh[7:0]);
    end
end
always @* cover(f_on && f_wf && f_txns == 2);
`endif

`ifdef N2_CMD
// =====================================================================
// command
// =====================================================================
always @* assume(proto_pin);
// frame bookkeeping
reg [3:0]  f_n;                             // bytes in this frame
reg [7:0]  f_c;
reg [31:0] f_a, f_b;
reg        f_pend;                          // an instruction is in flight
reg [31:0] f_lrd;                           // last completed result
reg [1:0]  f_lflg;                          // ... and its flags
reg        f_err;
reg [3:0]  f_seq;
reg        f_exp_start;                     // a start is due this cycle
reg [6:0]  f_e7; reg [2:0] f_e3; reg [31:0] f_ea, f_eb;
reg [47:0] f_snap;                          // {FLAGS, RD, STATUS}
reg        f_cfv;                           // VALID in this frame's snapshot
reg [3:0]  f_starts_seen;
reg        f_proto_set;
// the queues (spec copies, same pointer discipline as a plain ring buffer)
reg [68:0] f_iq [0:3]; reg [1:0] f_iqw, f_iqr; reg [2:0] f_iqn;
reg [37:0] f_oq [0:3]; reg [1:0] f_oqw, f_oqr; reg [2:0] f_oqn;   // {flags, seq, rd}
wire [37:0] f_oqh = f_oq[f_oqr];
wire [68:0] f_iqh = f_iq[f_iqr];
wire       f_busy_now = f_pend || c_start || (f_iqn != 3'd0);
wire       f_valid    = (f_oqn != 3'd0);
wire [31:0] f_rd_now  = f_valid ? f_oqh[31:0] : f_lrd;
wire [3:0]  f_seq_now = f_valid ? f_oqh[35:32] : f_seq;
wire [1:0]  f_flg_now = f_valid ? f_oqh[37:36] : f_lflg;
wire [7:0] f_status_now = {f_seq_now, f_iqn == 3'd4, f_err, f_valid, f_busy_now};
wire       f_legal = ((FUNCS != 0) ? (f_c[4:0] <= 5'd19) : (f_c[4:0] <= 5'd7)) || (f_c[4:0] == 5'd20);
wire       f_push  = frame_end && f_proto_set && f_c[7] && f_n >= 4'd5 && f_legal && f_iqn != 3'd4;
wire       f_disp  = f_proto_set && !f_pend && !c_start && !c_busy && f_iqn != 3'd0 && f_oqn != 3'd4;
wire       f_fin   = c_done && f_pend && !c_start;
wire       f_popr  = frame_end && f_proto_set && f_n >= 4'd5 && f_cfv && f_valid;
always @(posedge clk) begin
    if (!f_on) begin
        f_n <= 0; f_c <= 0; f_a <= 0; f_b <= 0; f_pend <= 0; f_lrd <= 0; f_lflg <= 0; f_err <= 0; f_seq <= 0;
        f_exp_start <= 0; f_starts_seen <= 0; f_proto_set <= 0; f_cfv <= 0;
        f_iqw <= 0; f_iqr <= 0; f_iqn <= 0; f_oqw <= 0; f_oqr <= 0; f_oqn <= 0;
    end else begin
        f_exp_start <= 0;
        if (proto) f_proto_set <= 1;
        if (frame_start) begin f_n <= 0; f_c <= 0; f_a <= 0; f_b <= 0; f_cfv <= f_snap[1]; end
        else if (rx_valid) begin
            case (f_n)
                4'd0: f_c <= rx_data;
                4'd1: f_a[7:0] <= rx_data;   4'd2: f_a[15:8] <= rx_data;
                4'd3: f_a[23:16] <= rx_data; 4'd4: f_a[31:24] <= rx_data;
                4'd5: f_b[7:0] <= rx_data;   4'd6: f_b[15:8] <= rx_data;
                4'd7: f_b[23:16] <= rx_data; 4'd8: f_b[31:24] <= rx_data;
                default: ;
            endcase
            if (f_n != 15) f_n <= f_n + 1;
        end
        // decision at frame end (spec)
        if (frame_end && f_proto_set && f_c[7]) f_err <= !f_push;
        if (f_push) begin f_iq[f_iqw] <= {f_c[4:0], f_a, f_b}; f_iqw <= f_iqw + 2'd1; end
        if (f_disp) begin
            f_exp_start <= 1;
            f_e7 <= {5'd0, f_iqh[68:67]}; f_e3 <= f_iqh[66:64]; f_ea <= f_iqh[63:32]; f_eb <= f_iqh[31:0];
            f_iqr <= f_iqr + 2'd1;
        end
        f_iqn <= f_iqn + {2'd0, f_push} - {2'd0, f_disp};
        if (c_start) f_pend <= 1;
        if (f_fin) begin
            f_pend <= 0; f_lrd <= c_rd; f_lflg <= c_flags; f_seq <= f_seq + 1;
            f_oq[f_oqw] <= {c_flags, f_seq + 4'd1, c_rd}; f_oqw <= f_oqw + 2'd1;
        end
        if (f_popr) f_oqr <= f_oqr + 2'd1;
        f_oqn <= f_oqn + {2'd0, f_fin} - {2'd0, f_popr};
        if (!cs_on) f_snap <= {6'd0, f_flg_now, f_rd_now, f_status_now};
        if (c_start && f_starts_seen != 15) f_starts_seen <= f_starts_seen + 1;
    end
end
wire [47:0] f_snap_sh = f_snap >> {f_pos[2:0], 3'b000};
wire [7:0]  f_want = (f_pos <= 5) ? f_snap_sh[7:0] : 8'd0;     // byte 5 = FLAGS

always @* if (f_on && f_proto_set) begin
    // instructions start exactly when the spec says, with the queued operands
    assert(c_start == f_exp_start);
    if (c_start) assert(c_funct7 == f_e7 && c_funct3 == f_e3 && c_rs1 == f_ea && c_rs2 == f_eb);
    // STATUS/RD and the queues
    assert(cerr == f_err && cseq == f_seq && crd == f_lrd && cflg == f_lflg && cexec == (f_pend || c_start));
    assert(iq_n == f_iqn && iq_r == f_iqr && iq_w == f_iqw && iq_n <= 3'd4);
    assert(oq_n == f_oqn && oq_r == f_oqr && oq_w == f_oqw && oq_n <= 3'd4);
    assert(iq_w == iq_r + iq_n[1:0] && oq_w == oq_r + oq_n[1:0]);
    if (iq_n > 3'd0) assert(iq_m[iq_r] == f_iq[iq_r]);
    if (iq_n > 3'd1) assert(iq_m[iq_r + 2'd1] == f_iq[iq_r + 2'd1]);
    if (iq_n > 3'd2) assert(iq_m[iq_r + 2'd2] == f_iq[iq_r + 2'd2]);
    if (iq_n > 3'd3) assert(iq_m[iq_r + 2'd3] == f_iq[iq_r + 2'd3]);
    if (oq_n > 3'd0) assert(oq_m[oq_r] == f_oq[oq_r]);
    if (oq_n > 3'd1) assert(oq_m[oq_r + 2'd1] == f_oq[oq_r + 2'd1]);
    if (oq_n > 3'd2) assert(oq_m[oq_r + 2'd2] == f_oq[oq_r + 2'd2]);
    if (oq_n > 3'd3) assert(oq_m[oq_r + 2'd3] == f_oq[oq_r + 2'd3]);
    // a result always has a place: in flight + waiting <= 4
    if (cexec) assert(oq_n != 3'd4);
    assert(cfv == f_cfv);
    // every byte the master reads
    if (rx_valid) assert(f_cur == f_want);
end
// the snapshot the master reads is the one taken in the last idle cycle
always @* if (f_on && f_proto_set && cs_on && f_cs1) assert(csnap == f_snap);
// pins: from the cycle after an EXEC command byte arrives until the frame end
// is processed, DATA_READY is low and BUSY high, so a host that polls them
// right after raising CS never sees the previous instruction's ready
reg f_xp = 1'b0;
always @(posedge clk)
    if (!f_on || frame_end) f_xp <= 1'b0;
    else if (rx_valid && f_pos == 4'd0 && rx_data[7]) f_xp <= 1'b1;
always @* if (f_on && f_proto_set && f_xp) assert(!data_ready && busy);
always @* cover(f_on && f_proto_set && f_starts_seen == 2);
always @* cover(f_on && f_proto_set && iq_n == 3'd4);          // the queue can fill
always @* cover(f_on && f_proto_set && oq_n == 3'd2 && cs_on);  // results wait while a frame runs
`endif

`ifdef N2_SWITCH
// =====================================================================
// protocol switches
// =====================================================================
reg f_cf = 1'b0;                            // the frame in progress (or just ended) began in command mode
reg f_p1 = 1'b0, f_p1v = 1'b0;              // proto one cycle ago
reg [1:0] f_sw = 2'd0;                      // switches seen (cover)
reg       f_lt = 1'b0;                      // a legacy transaction completed (cover)
always @(posedge clk) begin
    f_p1 <= proto; f_p1v <= f_on;
    if (!f_on) f_cf <= 1'b0;
    else if (frame_start) f_cf <= proto;
    if (f_on && f_p1v && proto != f_p1 && f_sw != 2'd3) f_sw <= f_sw + 2'd1;
    if (f_on && ls == L_TX && rx_valid && lk == 3'd5) f_lt <= 1'b1;
end
always @* if (f_on) begin
    // S1: only a frame that began in command mode moves the queues
    if (c_push || c_pop) assert(proto && f_cf);
    // S2: the protocol changes only between frames: CS was high, the last
    // frame's end has been seen, nothing is open
    if (f_p1v && proto != f_p1) begin
        assert(!f_cs1 && !frame_end);
        assert(ls == L_IDLE && !lready && iq_n == 3'd0 && !cexec && !cpend);
    end
    // S3: nothing of the other protocol is open
    if (proto) assert(ls == L_IDLE && !lready);
    if (!proto) assert(iq_n == 3'd0 && !cexec && !cpend);
    if (!proto && f_p1v && !f_p1) assert(ck == 4'd0 && !ccmd[7] && !cfv);
end
// reachable: command, legacy transaction, command again with an accepted EXEC
always @* cover(f_on && f_sw == 2'd2 && f_lt && proto && c_push);
`endif

`ifndef N2_SWITCH
// =====================================================================
// SCLK-domain slave contract (N1S assumes these; xc_spi_slave_sclk takes the
// bytes at times only known to lie in these windows):
//   A1  tx_data unchanged from the last cycle before frame_start until the
//       first rx_valid of the frame (exclusive)
//   A2  inside a frame, tx_next changes only in the cycle after rx_valid or
//       after frame_start
// Required wherever what the master reads matters: command mode always,
// legacy mode in the read phase of the protocol.
// =====================================================================
reg [7:0] f_a_t0, f_a_txn1;
reg       f_a_rxs = 1'b0, f_a_rxv1 = 1'b0, f_a_fs1 = 1'b0;
always @(posedge clk) begin
    if (!cs_on) f_a_t0 <= tx_data;
    if (frame_start) f_a_rxs <= 1'b0; else if (rx_valid) f_a_rxs <= 1'b1;
    f_a_rxv1 <= rx_valid; f_a_fs1 <= frame_start; f_a_txn1 <= tx_next;
end
`ifdef N2_CMD
wire f_a_need = f_on && f_proto_set;
`else
wire f_a_need = f_on && f_wf && !f_wph;
`endif
always @* if (f_a_need) begin
    if (cs_on && (frame_start || !f_a_rxs) && !rx_valid) assert(tx_data == f_a_t0);   // A1
    if (cs_on && f_cs1 && !f_a_rxv1 && !f_a_fs1) assert(tx_next == f_a_txn1);          // A2
end
`endif
