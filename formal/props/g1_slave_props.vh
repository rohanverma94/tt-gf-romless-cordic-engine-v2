// g1_slave_props.vh — injected into a build copy of src/xc_spi_slave.v. G1:
// the default (oversampled) SPI slave on Tiny Tapeout GF26c, at the chip's pads.
//
// Time model (multiclock, global step = 1 tick): the core clock is 2^`CPL
// ticks (half high, half low). At the GF26c build's 25 MHz: `CPL = 3 is a 5 ns
// tick, `CPL = 2 a 10 ns tick.
//
// The master drives SCLK, MOSI and CS_N at the chip's pads and samples MISO at
// its pad. Between pad and slave port (and back) every transition takes a
// delay in a window, chosen freely for each pin and each transition, so the
// pins also skew against each other by up to the window width:
//   inward  (pad -> ui_in port)   `DI0 .. `DI1 ticks
//   outward (uo_out port -> pad)  `DO0 .. `DO1 ticks
// GF26c: the tt_top signoff constrains pad -> tile input <= 5.0 ns and tile
// output -> pad <= 12.5 ns (30 pF, all corners); the pad cells alone take
// >= 0.9 / 1.9 ns (gf180mcu_ocd_io in_c / bi_24t, ff corner). Windows that
// contain [0.9, 5.3] ns inward and [1.9, 12.8] ns outward (with the tile's own
// port buffers): 5 ns ticks 0..2 / 0..3, 10 ns ticks 0..1 / 0..2.
// Synchronizer capture of a changing input is covered by the delay choice
// (an input moving in the tick before a clock edge may be seen either side).
//
// The master (spi_master_model, STRETCH): SCLK high/low >= `H / `L ticks, CS
// setup >= `S, CS high >= `G, any longer freely. It reads MISO `SD ticks after
// its sample edge (0 = on the edge, a plain master).
//
// Theorem:
//   M  every bit the slave shifts in is the bit the master drove at its pad for
//      that SCLK period; each rx_data is the last 8 bits shifted in
//   S  every bit the master reads at its pad is bit (7-k) of the byte the slave
//      took for that byte position (byte 0: one snapshot of tx_data)
//   F  each frame gives exactly `FB rx_valid pulses
//   D  the master's pins never change faster than the delay windows allow

`ifndef SD
`define SD 0
`endif
`ifndef CPL
`define CPL 3
`endif

// ---------------- time base: 2^`CPL ticks per core clock ----------------
reg [`CPL-1:0] f_cdiv = 0;
always @($global_clock) f_cdiv <= f_cdiv + 1'b1;
always @* assume(clk == f_cdiv[`CPL-1]);
reg f_clk_p = 1'b0;
always @($global_clock) f_clk_p <= clk;
wire f_cr = clk && !f_clk_p;                  // first tick of a core-clock cycle

reg [3:0] f_rst = 4'd0;
always @(posedge clk) if (!f_rst[3]) f_rst <= f_rst + 4'd1;
always @* assume(rst_n == f_rst[3]);
wire f_on = f_rst[3];

// ---------------- master at the pads ----------------
wire f_sclk, f_mosi, f_cs_n, f_fs, f_fe, f_bd, f_inf, f_smp, f_rise, f_miso_pad;
wire [7:0] f_mtx, f_mrx, f_mcur;
spi_master_model #(.CPHA(`CPHA), .H(`H), .L(`L), .S(`S), .T(`T), .G(`G), .FRAME_BYTES(`FB), .FREE(1), .STRETCH(1)) f_master (
    .clk(1'b0), .run(f_on), .next_byte(8'd0), .miso(f_miso_pad),
    .sclk(f_sclk), .mosi(f_mosi), .cs_n(f_cs_n),
    .frame_start(f_fs), .frame_end(f_fe), .byte_done(f_bd),
    .m_tx(f_mtx), .m_rx(f_mrx), .in_frame(f_inf), .smp(f_smp), .rise(f_rise), .cur_tx(f_mcur)
);

// ---------------- I/O paths ----------------
wire f_sclk_p, f_mosi_p, f_cs_p, f_ok_sclk, f_ok_mosi, f_ok_cs, f_ok_miso;
fv_iodelay #(.D0(`DI0), .D1(`DI1)) f_d_sclk (.in(f_sclk),  .out(f_sclk_p), .ok(f_ok_sclk));
fv_iodelay #(.D0(`DI0), .D1(`DI1)) f_d_mosi (.in(f_mosi),  .out(f_mosi_p), .ok(f_ok_mosi));
fv_iodelay #(.D0(`DI0), .D1(`DI1)) f_d_cs   (.in(f_cs_n),  .out(f_cs_p),   .ok(f_ok_cs));
fv_iodelay #(.D0(`DO0), .D1(`DO1)) f_d_miso (.in(miso),    .out(f_miso_pad), .ok(f_ok_miso));
always @* assume(sclk == f_sclk_p && mosi == f_mosi_p && cs_n == f_cs_p && cpha == `CPHA);

// tx_data / tx_next are core-clock registers: they change only at clock edges
reg [7:0] f_txd_p = 8'd0, f_txn_p = 8'd0;
always @($global_clock) begin f_txd_p <= tx_data; f_txn_p <= tx_next; end
always @* if (!f_cr) assume(tx_data == f_txd_p && tx_next == f_txn_p);

// ---------------- bookkeeping ----------------
// master side (every tick): the byte sent at each byte position, by parity
reg [7:0] f_mq0 = 8'd0, f_mq1 = 8'd0;
reg [4:0] f_mrises = 5'd0, f_nsmp = 5'd0;
always @($global_clock) begin
    if (f_fs) begin
        f_mq0 <= f_mcur; f_mrises <= f_rise ? 5'd1 : 5'd0; f_nsmp <= (f_smp && f_inf) ? 5'd1 : 5'd0;
    end else begin
        if (f_rise) begin
            f_mrises <= f_mrises + 5'd1;
            if (f_mrises[2:0] == 3'd0 && f_mrises != 0) begin
                if (f_mrises[3]) f_mq1 <= f_mcur; else f_mq0 <= f_mcur;
            end
        end
        if (f_smp && f_inf) f_nsmp <= f_nsmp + 5'd1;
    end
end
wire [4:0] f_nsmp_c = f_fs ? 5'd0 : f_nsmp;   // index of a sample taken this tick

// slave side (once per core-clock cycle, at its first tick)
reg [7:0] f_sq0 = 8'd0, f_sq1 = 8'd0;
reg [3:0] f_sb = 4'd0, f_nrx = 4'd0, f_frames = 4'd0;
reg f_smp_d = 1'b0, f_bit_d = 1'b0;
wire [7:0] f_msent = f_sb[0] ? f_mq1 : f_mq0;
always @($global_clock) if (f_cr) begin
    if (!rst_n) begin
        f_sb <= 0; f_nrx <= 0; f_frames <= 0; f_smp_d <= 1'b0;
    end else begin
        if (!cs_on) begin
            f_sq0 <= tx_data; f_sb <= 0;
        end else if (sample && bitn == 3'd7) begin
            if (f_sb[0]) f_sq0 <= tx_next; else f_sq1 <= tx_next;
            f_sb <= f_sb + 4'd1;
        end
        if (frame_start) f_nrx <= 0;
        else if (rx_valid && f_nrx != 15) f_nrx <= f_nrx + 4'd1;
        if (frame_end && f_frames != 15) f_frames <= f_frames + 4'd1;
        f_smp_d <= sample;
        f_bit_d <= f_msent[3'd7 - bitn];
    end
end

// ---------------- M, F ----------------
always @* if (f_on && f_cr) begin
    if (f_smp_d) assert(rx_sh[0] == f_bit_d);
    if (rx_valid) assert(rx_data == rx_sh);
    if (frame_end) assert(f_nrx == `FB);
end

// ---------------- S: the master reads MISO `SD ticks after its sample edge ----
reg [5:0] f_cd = 6'd0;                        // ticks until the pending read, 0 = none
reg [4:0] f_tok = 5'd0;                       // sample index of the pending read
wire f_now  = (`SD == 0) ? (f_smp && f_inf) : (f_cd == 6'd1);
wire [4:0] f_idx = (`SD == 0) ? f_nsmp_c : f_tok;
always @($global_clock) begin
    if (`SD != 0) begin
        if (f_smp && f_inf) begin f_cd <= `SD; f_tok <= f_nsmp_c; end
        else if (f_cd != 0) f_cd <= f_cd - 6'd1;
    end
end
wire [7:0] f_slat = f_idx[3] ? f_sq1 : f_sq0;
// byte 0's MSB may be read before the slave has seen CS: check it against the
// byte the slave finally takes
reg f_msb_v = 1'b0, f_msb = 1'b0;
always @($global_clock) begin
    if (f_now && f_idx == 0 && !cs_on) begin f_msb_v <= 1'b1; f_msb <= f_miso_pad; end
    if (f_cr && frame_start) f_msb_v <= 1'b0;
end
always @* if (f_on) begin
    if (f_now && !(f_idx == 0 && !cs_on)) assert(f_miso_pad == f_slat[3'd7 - f_idx[2:0]]);
    if (f_cr && frame_start && f_msb_v) assert(f_msb == f_sq0[7]);
    // a pending read is done before the next sample edge (SD < one SCLK period)
    if (`SD != 0 && f_smp && f_inf) assert(f_cd <= 6'd1);
    // D: the delay windows hold
    assert(f_ok_sclk && f_ok_mosi && f_ok_cs && f_ok_miso);
end

always @* cover(f_on && f_cr && frame_end && f_frames == 4'd0);
