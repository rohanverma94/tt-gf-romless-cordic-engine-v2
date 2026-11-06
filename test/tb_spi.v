// tb_spi.v — tt_um_xcordic (or, with -DORIG, the original ttsky25a design)
// through a real-time SPI master on its own timeline (not tied to the core
// clock). Every result is checked bit for bit against a reference
// xcordic_core driven directly.
//
//   +TH=<ns> +TL=<ns>  SCLK high/low time (default 50/50 = 10 MHz)
//   +CPHA=<0|1>        master mode
//   +MULTI=<0|1>       legacy bytes: 1 per CS frame (as the original) or 8/6 per frame
//   +TG=<ns>           CS-high gap between frames (default 230)
//   +TT=<ns>           last SCLK edge -> CS high (default 45)
//   +N=<n>             legacy angles (default 250, the harness sweep)
//   +CMD=<n>           command-mode instructions (new design only)
//   -DORIG             test the original tt_um_romless_cordic_engine
//   -DG=<g>            GUARD of the new design (and of the reference)
//   -DCLKP=<ns>        core clock period (default 20 = 50 MHz)
//   -DSCLKDOM          the SCLK-domain SPI slave (SPI_SCLK = 1)
//   +TS=<ns>           CS low -> first SCLK edge (default 55)
//   +TP=<ns>           pause after each byte but the last of a frame (default 0)
//   +PH=<ns>           SPI timeline offset from the core clock (default 13)
//   +SD=<ns>           master samples MISO this long after its edge (default 0)
//   -DIO_IN/-DIO_OUT/-DIO_SKEW=<ns>  chip I/O delays (default 0)
`timescale 1ns/1ps
`default_nettype none

module tb_spi;
`ifndef G
`define G 4
`endif
`ifndef CLKP
`define CLKP 20
`endif
`ifdef SCLKDOM
    localparam SPI_SCLK = 1;
`else
    localparam SPI_SCLK = 0;
`endif
    reg clk = 0;
    always #(`CLKP / 2.0) clk = ~clk;        // default 50 MHz core clock, as ttsky25a
    reg rst_n = 1;
    reg sclk = 0, mosi = 0, cs_n = 0, proto = 0, cpha_pin = 0;
    // real edges on the reset and CS pins at power-up: flops with asynchronous
    // reset (the SCLK-domain slave) only react to an edge in simulation
    initial begin #1 rst_n = 0; cs_n = 1; end
    wire [7:0] uo_out, uio_out, uio_oe;
    // chip I/O model (Tiny Tapeout pads + muxes): transport delays, ns.
    // -DIO_IN=<ns> on SCLK/MOSI/CS into the design (MOSI +IO_SKEW), -DIO_OUT=<ns> on MISO
`ifndef IO_IN
`define IO_IN 0
`endif
`ifndef IO_OUT
`define IO_OUT 0
`endif
`ifndef IO_SKEW
`define IO_SKEW 0
`endif
    reg sclk_p = 0, mosi_p = 0, cs_n_p = 0, miso = 0;
    always @(sclk) sclk_p <= #(`IO_IN) sclk;
    always @(mosi) mosi_p <= #(`IO_IN + `IO_SKEW) mosi;
    always @(cs_n) cs_n_p <= #(`IO_IN) cs_n;
    always @(uo_out[0]) miso <= #(`IO_OUT) uo_out[0];
    wire data_ready = uo_out[1];

`ifdef ORIG
    tt_um_romless_cordic_engine dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out), .uio_in(8'd0),
        .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));
    localparam RG = 0;
`else
    tt_um_xcordic #(.GUARD(`G), .TIMEOUT_LOG2(10), .SPI_SCLK(SPI_SCLK)) dut (
        .ui_in({3'd0, cpha_pin, proto, cs_n_p, mosi_p, sclk_p}), .uo_out(uo_out), .uio_in(8'd0),
        .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));
    localparam RG = `G;
`endif

    // ---------------- reference core ----------------
    reg r_start = 0; reg [6:0] r_f7; reg [2:0] r_f3; reg [31:0] r_rs1, r_rs2;
    wire r_busy, r_done; wire [31:0] r_rd; wire [1:0] r_flags;
    reg [1:0] r_flg;                         // flags of the last ref_exec
`ifdef ORIG
    xcordic_core #(.GUARD(RG)) ref_core (.clk(clk), .rstn(rst_n), .start(r_start), .funct7(r_f7),
        .funct3(r_f3), .rs1(r_rs1), .rs2(r_rs2), .busy(r_busy), .done(r_done), .rd(r_rd), .flags(r_flags));
`else
    // reference: a separate self-test unit + core, so cordic.bist has a reference too
    wire rc_start, rc_busy, rc_done; wire [6:0] rc_f7; wire [2:0] rc_f3; wire [31:0] rc_rs1, rc_rs2, rc_rd; wire [1:0] rc_flags;
    xc_bist ref_bist (.clk(clk), .rst_n(rst_n), .u_start(r_start), .u_funct7(r_f7), .u_funct3(r_f3),
        .u_rs1(r_rs1), .u_rs2(r_rs2), .u_busy(r_busy), .u_done(r_done), .u_rd(r_rd), .u_flags(r_flags),
        .c_start(rc_start), .c_funct7(rc_f7), .c_funct3(rc_f3), .c_rs1(rc_rs1), .c_rs2(rc_rs2),
        .c_busy(rc_busy), .c_done(rc_done), .c_rd(rc_rd), .c_flags(rc_flags));
    xcordic_core #(.GUARD(RG)) ref_core (.clk(clk), .rstn(rst_n), .start(rc_start), .funct7(rc_f7),
        .funct3(rc_f3), .rs1(rc_rs1), .rs2(rc_rs2), .busy(rc_busy), .done(rc_done), .rd(rc_rd), .flags(rc_flags));
`endif
    task ref_exec(input [6:0] f7, input [2:0] f3, input [31:0] a, input [31:0] b, output [31:0] rd);
        begin
            @(negedge clk); r_f7 = f7; r_f3 = f3; r_rs1 = a; r_rs2 = b; r_start = 1;
            @(negedge clk); r_start = 0;
            while (!r_done) @(negedge clk);
            rd = r_rd;
            r_flg = r_flags;
        end
    endtask

    // ---------------- SPI master ----------------
    integer TH = 50, TL = 50, TS = 55, TT = 45, TG = 230, TP = 0, CPHA = 0, PH = 13;
    reg [7:0] txb [0:15];
    reg [7:0] rxb [0:15];
    // SD: the master samples MISO SD ns after its sample edge (a read delay, as
    // QSPI controllers have), not on the edge
    integer SD = 0, smp_b, smp_i;
    event smp_ev;
    always @(smp_ev) begin : late_sample
        integer b2, i2;
        b2 = smp_b; i2 = smp_i;
        #(SD) rxb[b2][i2] = miso;
    end
    task frame(input integer n);              // n bytes in one CS frame
        integer b, i;
        begin
            cs_n = 0;
            for (b = 0; b < n; b = b + 1) begin
                for (i = 7; i >= 0; i = i - 1) begin
                    // TP: pause after the last sample of a byte that is not the
                    // frame's last (mode 0: long high phase; mode 1: long low)
                    if (CPHA == 0) begin
                        mosi = txb[b][i];
                        #((b == 0 && i == 7) ? TS : TL);
                        sclk = 1; if (SD == 0) rxb[b][i] = miso; else begin smp_b = b; smp_i = i; -> smp_ev; end  // sample on the rising edge
                        #TH; if (i == 0 && b < n - 1) #TP; sclk = 0;
                    end else begin
                        #((b == 0 && i == 7) ? TS : TL);
                        sclk = 1; mosi = txb[b][i];
                        #TH; sclk = 0; if (SD == 0) rxb[b][i] = miso; else begin smp_b = b; smp_i = i; -> smp_ev; end // sample on the falling edge
                        if (i == 0 && b < n - 1) #TP;
                    end
                end
            end
            #TT; cs_n = 1; #TG;
        end
    endtask
    // n bytes, one CS frame each (the original protocol) or all in one frame
    task bytes(input integer n, input integer multi);
        integer b; reg [7:0] t;
        begin
            if (multi) frame(n);
            else for (b = 0; b < n; b = b + 1) begin
                t = txb[b]; txb[0] = t; frame(1); rxb[b] = rxb[0];
                txb[b] = t;
            end
        end
    endtask

    integer errors = 0, checks = 0;

    // ---------------- legacy transaction ----------------
    task legacy(input [15:0] x, input [15:0] y, input [15:0] a, input [15:0] at0, input integer multi,
                output [15:0] s, output [15:0] c);
        integer k, w;
        reg [7:0] save [0:7];
        begin
            {txb[1], txb[0]} = x; {txb[3], txb[2]} = y; {txb[5], txb[4]} = a; {txb[7], txb[6]} = at0;
            for (k = 0; k < 8; k = k + 1) save[k] = txb[k];
            if (multi) frame(8);
            else for (k = 0; k < 8; k = k + 1) begin txb[0] = save[k]; frame(1); if (slow && k < 7) #(slow * `CLKP); end
            w = 0;
            while (!data_ready && w < 5000) begin #(`CLKP); w = w + 1; end
            if (!data_ready) begin $display("  no DATA_READY"); errors = errors + 1; end
            if (slow) #(slow * `CLKP);                  // a host slow to read
            for (k = 0; k < 6; k = k + 1) txb[k] = 0;
            if (multi) frame(6);
            else for (k = 0; k < 6; k = k + 1) begin txb[0] = 0; frame(1); save[k] = rxb[0]; end
            if (multi) for (k = 0; k < 6; k = k + 1) save[k] = rxb[k];
            s = {save[1], save[0]}; c = {save[3], save[2]};
        end
    endtask

    // ---------------- command frame ----------------
    task cmd(input [7:0] c0, input [31:0] a, input [31:0] b, input integer n,
             output [7:0] status, output [31:0] rd);
        begin
            txb[0] = c0; {txb[4], txb[3], txb[2], txb[1]} = a; {txb[8], txb[7], txb[6], txb[5]} = b;
            frame(n);
            status = rxb[0]; rd = {rxb[4], rxb[3], rxb[2], rxb[1]};
        end
    endtask
    // one instruction, then check RD and the FLAGS byte against fixed values
    task dchk(input [7:0] c0, input [31:0] a, input [31:0] b, input [31:0] want_rd, input [1:0] want_fl);
        reg [7:0] st_;
        reg [31:0] rd_;
        begin
            cmd(c0, a, b, 9, st_, rd_);
            wait_idle;
            cmd(8'h00, 0, 0, 6, st_, rd_);
            checks = checks + 1;
            if (rd_ !== want_rd || rxb[5] !== {6'd0, want_fl}) begin
                errors = errors + 1;
                $display("  exact op %02h a %08h b %08h: got %08h flags %02h, want %08h flags %0d",
                         c0, a, b, rd_, rxb[5], want_rd, want_fl);
            end
        end
    endtask
    task wait_idle;
        integer w;
        begin w = 0; while ((uo_out[2] || !data_ready) && w < 10000) begin #(`CLKP); w = w + 1; end end
    endtask

    integer i, n, ncmd, multi, op, legal;
    integer slow = 0;                        // host pause (core clocks) between bytes and before reading
    reg [15:0] s, c, rs_, rc_;
    reg [31:0] a, b, rd, want, want_cfg;
    reg [7:0] st, st2;
    real th;
    integer seed = 7;
    initial begin
        if (!$value$plusargs("TH=%d", TH)) TH = 50;
        if (!$value$plusargs("TL=%d", TL)) TL = 50;
        if (!$value$plusargs("CPHA=%d", CPHA)) CPHA = 0;
        if (!$value$plusargs("TG=%d", TG)) TG = 230;                // CS-high gap, ns
        if (!$value$plusargs("TT=%d", TT)) TT = 45;                 // last edge -> CS high, ns
        if (!$value$plusargs("TS=%d", TS)) TS = 55;                 // CS low -> first edge, ns
        if (!$value$plusargs("TP=%d", TP)) TP = 0;                  // pause between bytes, ns
        if (!$value$plusargs("MULTI=%d", multi)) multi = 0;
        if (!$value$plusargs("N=%d", n)) n = 250;
        if (!$value$plusargs("CMD=%d", ncmd)) ncmd = 0;
        cpha_pin = CPHA;
        if (!$value$plusargs("PH=%d", PH)) PH = 13;
        if (!$value$plusargs("SD=%d", SD)) SD = 0;
        #(PH);                               // SPI timeline offset from the clock (+PH=<ns>)
        repeat (8) @(posedge clk); #7 rst_n = 1;
        #500;
        $display("SCLK %0d/%0d ns (%.2f MHz) mode %0d, %0s", TH, TL, 1000.0 / (TH + TL), CPHA,
                 multi ? "multi-byte frames" : "one byte per CS frame");

`ifdef ORIG
        ref_exec(0, 7, 32'h0758, 1, want);           // the reference with the taped-out atan1
`endif
        // ---- legacy: the harness sweep (in_x 0x09B7, atan0 0x0C91) ----
        for (i = 0; i < n; i = i + 1) begin
            a = $rtoi(6.283185307179586 * i / n * 4096.0 + 0.5);
            proto = 0;
            legacy(16'h09B7, 16'h0000, a[15:0], 16'h0C91, multi, s, c);
            ref_exec(0, 7, 32'h0C91 << RG, 0, want);
            ref_exec(0, 0, {16'h0000, 16'h09B7}, {16'd0, a[15:0]}, want);
            checks = checks + 1;
            if ({s, c} !== want) begin
                errors = errors + 1;
                if (errors <= 5) $display("  legacy #%0d angle 0x%04h: got sin %04h cos %04h, want %04h %04h",
                                          i, a[15:0], s, c, want[31:16], want[15:0]);
            end
        end
        $display("legacy: %0d / %0d transactions bit-exact", checks - errors, checks);

`ifndef ORIG
        // ---- legacy recovery: garbage, quiet > timeout, then a transaction ----
        begin : recover
            integer e0; e0 = errors;
            txb[0] = 8'h55; frame(1); txb[0] = 8'hAA; frame(1); txb[0] = 8'h12; frame(1);
            #(1100 * `CLKP);                         // 2^10-cycle timeout
            legacy(16'h09B7, 16'h0000, 16'h0C90, 16'h0C91, multi, s, c);
            ref_exec(0, 7, 32'h0C91 << RG, 0, want);
            ref_exec(0, 0, {16'h0000, 16'h09B7}, 32'h0C90, want);
            if ({s, c} !== want) begin errors = errors + 1; $display("  recovery FAILED"); end
            else $display("legacy recovery after 3 stray bytes: OK");
        end

        // ---- legacy with a slow host: 900-clock pauses, under the 2^10 timeout with the byte time ----
        begin : slowhost
            slow = 900;
            legacy(16'h09B7, 16'h0000, 16'h0C90, 16'h0C91, multi, s, c);
            slow = 0;
            ref_exec(0, 7, 32'h0C91 << RG, 0, want);
            ref_exec(0, 0, {16'h0000, 16'h09B7}, 32'h0C90, want);
            checks = checks + 1;
            if ({s, c} !== want) begin errors = errors + 1; $display("  slow host FAILED"); end
            else $display("legacy with 900-clock host pauses: OK");
        end

        // ---- command mode: random instructions vs the reference ----
        if (ncmd > 0) begin : cmdmode
            integer e0, k, len;
            e0 = errors;
            proto = 1; #2000;
            // reset cfg atan0 written by the legacy test, in both cores
            cmd(8'h87, 32'h0C91 << RG, 32'd0, 9, st, rd); wait_idle;
            ref_exec(0, 7, 32'h0C91 << RG, 0, want);
            for (k = 0; k < ncmd; k = k + 1) begin
                op = $unsigned($random(seed)) % 20;
                a = $random(seed); b = $random(seed);
                if (op == 7) b = {28'd0, 1'b1, b[2:0]};      // cfg: read-only, so state stays equal
                len = (k % 3 == 0) ? 9 : ((op == 1 || op == 2 || op == 4 || op == 5 || op == 6 ||
                       op == 8 || op == 9 || op == 10 || op == 13 || op == 14 || op == 15 || op == 18) ? 5 : 9);
                if (len == 5) b = 0;
                cmd({1'b1, 2'b00, op[4:0]}, a, b, len, st, rd);
                wait_idle;
                cmd(8'h00, 0, 0, 6, st, rd);                 // read STATUS + RD + FLAGS
                ref_exec(op[4:3], op[2:0], a, b, want);
                checks = checks + 1;
                if (rd !== want || st[2] || !st[1] || st[0] || rxb[5] !== {6'd0, r_flg}) begin
                    errors = errors + 1;
                    if (errors - e0 <= 5) $display("  cmd op %0d rs1 %08h rs2 %08h: got %08h status %02h flags %02h, want %08h flags %0d",
                                                  op, a, b, rd, st, rxb[5], want, r_flg);
                end
            end
            $display("command: %0d instructions, %0d errors", ncmd, errors - e0);
            // error cases: illegal op, short frame, exec while busy
            cmd(8'h95, 0, 0, 9, st, rd); cmd(8'h00, 0, 0, 1, st, rd);     // op 21: illegal
            if (!st[2]) begin errors = errors + 1; $display("  illegal op not flagged"); end
            cmd(8'h88, 32'h1000, 0, 3, st, rd); cmd(8'h00, 0, 0, 1, st, rd);
            if (!st[2]) begin errors = errors + 1; $display("  short frame not flagged"); end
            // (EXEC while busy cannot be provoked over SPI: a 5-byte frame outlasts
            // the longest instruction at any SCLK the slave supports; N2 covers it)
            // pipelined: the frame that reads a result starts the next instruction
            cmd(8'h88, 32'h0800, 0, 5, st, rd); wait_idle;   // sin(0.5)
            cmd(8'h89, 32'h0800, 0, 5, st, rd);              // reads sin, starts cos(0.5)
            ref_exec(1, 0, 32'h0800, 0, want);
            if (rd !== want) begin errors = errors + 1; $display("  pipelined read wrong"); end
            wait_idle; cmd(8'h00, 0, 0, 5, st, rd);
            ref_exec(1, 1, 32'h0800, 0, want);
            if (rd !== want) begin errors = errors + 1; $display("  pipelined exec wrong"); end
            $display("command error/status cases: %0s", errors == e0 ? "OK" : "FAILED");
            // exact mul / div / sqrt and the FLAGS byte, values worked out by hand
            e0 = errors;
            dchk(8'h90, 32'h1000, 32'h1000, 32'h00001000, 2'b00);   // 1 * 1 = 1
            dchk(8'h90, 32'h7000, 32'h2000, 32'h00007FFF, 2'b01);   // 7 * 2 = 14: SAT
            dchk(8'h90, 32'hFFFF, 32'h0800, 32'h00000000, 2'b00);   // -1 LSB * 0.5 = -0.5 LSB: ties up -> 0
            dchk(8'h90, 32'h0001, 32'h0800, 32'h00000001, 2'b00);   // +0.5 LSB -> 1
            dchk(8'h91, 32'h1000, 32'h3000, 32'h00000555, 2'b00);   // 1/3 = 1365.33 LSB
            dchk(8'h91, 32'hF000, 32'h3000, 32'hFFFFFAAB, 2'b00);   // -1/3 -> -1365
            dchk(8'h91, 32'h1000, 32'h0000, 32'h00007FFF, 2'b10);   // 1/0: INV
            dchk(8'h91, 32'h0000, 32'h0000, 32'h00000000, 2'b10);   // 0/0: INV
            dchk(8'h91, 32'h7000, 32'h0800, 32'h00007FFF, 2'b01);   // 7/0.5 = 14: SAT
            dchk(8'h91, 32'hC000, 32'h0800, 32'hFFFF8000, 2'b00);   // -4/0.5 = -8 exactly: not clipped
            dchk(8'h8F, 32'h2000, 32'h0000, 32'h000016A1, 2'b00);   // sqrt 2 = 5792.62 LSB
            dchk(8'h8F, 32'hFFFF, 32'h0000, 32'hFFFF8000, 2'b10);   // sqrt of < 0: INV
            dchk(8'h8F, 32'h0000, 32'h0000, 32'h00000000, 2'b00);   // sqrt 0
            dchk(8'h8E, 32'h0000, 32'h0000, 32'hFFFF8000, 2'b10);   // ln 0: INV
            dchk(8'h8D, 32'h3000, 32'h0000, 32'h00007FFF, 2'b01);   // exp 3 = 20.1: SAT
            $display("exact mul/div/sqrt and flags: %0s", errors == e0 ? "OK" : "FAILED");
            // queues: 5 EXECs back to back (the 5th must be rejected while 4
            // wait, or accepted if one already started), then the results in order
            e0 = errors;
            begin : queue_test
                // every frame of >= 5 bytes returns (and removes) the oldest unread
                // result when its STATUS shows VALID: collect them in order
                integer q, nacc, ngot; reg [31:0] qa [0:4]; reg [31:0] got [0:4]; reg [31:0] qw;
                nacc = 0; ngot = 0;
                for (q = 0; q < 5; q = q + 1) begin
                    qa[q] = 32'h0400 * (q + 1);
                    cmd(8'h88, qa[q], 0, 5, st, rd);                 // sin((q+1)/4)
                    if (st[1]) begin got[ngot] = rd; ngot = ngot + 1; end
                    cmd(8'h00, 0, 0, 1, st, rd);
                    if (!st[2]) nacc = nacc + 1;
                end
                if (nacc != 5) begin errors = errors + 1; $display("  queue accepted %0d of 5", nacc); end
                wait_idle;
                while (ngot < nacc) begin
                    cmd(8'h00, 0, 0, 5, st, rd);
                    if (!st[1]) begin errors = errors + 1; $display("  result %0d missing", ngot); ngot = nacc; end
                    else begin got[ngot] = rd; ngot = ngot + 1; end
                end
                for (q = 0; q < nacc; q = q + 1) begin
                    ref_exec(1, 0, qa[q], 0, qw);
                    if (got[q] !== qw) begin errors = errors + 1; $display("  queued result %0d: %08h want %08h", q, got[q], qw); end
                end
                cmd(8'h00, 0, 0, 5, st, rd);
                if (st[1]) begin errors = errors + 1; $display("  results left after reading all"); end
            end
            // cordic.bist (op 20): N = 0 -> 0xFFFFFFFF; N = 25 against the reference unit
            cmd(8'h94, 32'd0, 32'd0, 9, st, rd); wait_idle; cmd(8'h00, 0, 0, 5, st, rd);
            if (rd !== 32'hFFFFFFFF) begin errors = errors + 1; $display("  bist N=0: %08h", rd); end
            cmd(8'h94, 32'd25, 32'h1234_5678, 9, st, rd); wait_idle; cmd(8'h00, 0, 0, 5, st, rd);
            ref_exec(2, 4, 32'd25, 32'h1234_5678, want);
            if (rd !== want) begin errors = errors + 1; $display("  bist N=25: %08h want %08h", rd, want); end
            checks = checks + 8;
            $display("command queues and bist: %0s (bist 25 = %08h)", errors == e0 ? "OK" : "FAILED", rd);
        end
`endif
        $display("RESULT: %0d checks, %0d errors", checks, errors);
        $finish;
    end
    initial begin #2000000000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
