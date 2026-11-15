// n1s_slave_props.vh — injected into a build copy of src/xc_spi_slave_sclk.v. N1S.
//
// Time model (multiclock, global time step = 1 tick): the core clock is 4
// ticks (high 2, low 2); at 100 MHz a tick is 2.5 ns. The timed SPI master runs
// on every tick: SCLK high/low phases last >= `H / `L ticks, CS setup >= `S,
// CS high >= `G, any longer freely (STRETCH), so SCLK takes every alignment to
// the core clock at tick resolution and every slower timing.
// Every synchronizer input that changed in the last tick may be caught old or
// new (xc_meta). One tick = 2.5 ns at 100 MHz: H = L = 3 is 66.7 MHz SCLK.
//
// Environment (proved for xc_frame by N2): tx_data and tx_next are outputs of
// core-clock registers (they change only at core-clock edges), and
//   A1  tx_data is unchanged from the last cycle before frame_start until the
//       first rx_valid of the frame (exclusive)
//   A2  inside a frame, tx_next changes only in the cycle after rx_valid or
//       after frame_start
//
// Theorem:
//   M   every rx_data is the byte the master sent at that position of the frame
//   S   every byte the master reads: byte 0 = tx_data in the last cycle before
//       frame_start, byte n+1 = tx_next at the rx_valid of byte n
//   F   each frame gives exactly `FB rx_valid pulses
//   C   the clk-side outputs keep the byte contract N2 assumes (frame_start,
//       frame_end, rx_valid only while cs_on was high, spacing)
//   X   CDC safety: every value crossing between the clock domains is stable
//       for >= `MX ticks before the edge that captures it (rbyte into rx_data,
//       tx_data at the first launch and tx_next at each last sampled bit into
//       the SCLK domain), and the MSB a mode-0 master
//       reads straight from tx_data before the first launch has been stable for
//       >= `MO ticks when the master samples it

`ifndef MX
`define MX 2
`endif
`ifndef MO
`define MO 4
`endif

// ---------------- time base ----------------
reg [1:0] f_cdiv = 2'd0;
always @($global_clock) f_cdiv <= f_cdiv + 2'd1;
always @* assume(clk == f_cdiv[1]);
reg f_clk_p = 1'b0;
always @($global_clock) f_clk_p <= clk;
wire f_clk_rise = clk && !f_clk_p;

reg [3:0] f_rst = 4'd0;
always @(posedge clk) if (!f_rst[3]) f_rst <= f_rst + 4'd1;
always @* assume(rst_n == f_rst[3]);
wire f_on = f_rst[3];

// ---------------- master ----------------
wire f_sclk, f_mosi, f_cs_n, f_fs, f_fe, f_bd, f_inf, f_smp, f_rise;
wire [7:0] f_mtx, f_mrx, f_mcur;
spi_master_model #(.CPHA(`CPHA), .H(`H), .L(`L), .S(`S), .T(`T), .G(`G), .FRAME_BYTES(`FB), .FREE(1), .STRETCH(1)) f_master (
    .clk(1'b0), .run(rst_n), .next_byte(8'd0), .miso(miso),
    .sclk(f_sclk), .mosi(f_mosi), .cs_n(f_cs_n),
    .frame_start(f_fs), .frame_end(f_fe), .byte_done(f_bd),
    .m_tx(f_mtx), .m_rx(f_mrx), .in_frame(f_inf), .smp(f_smp), .rise(f_rise), .cur_tx(f_mcur)
);
always @* assume(sclk == f_sclk && mosi == f_mosi && cs_n == f_cs_n && cpha == `CPHA);

// ---------------- environment: tx_data / tx_next ----------------
reg [7:0] f_txd_p = 8'd0, f_txn_p = 8'd0;
always @($global_clock) begin f_txd_p <= tx_data; f_txn_p <= tx_next; end
always @* if (!f_clk_rise) assume(tx_data == f_txd_p && tx_next == f_txn_p);

reg f_cs1 = 1'b0, f_cs2 = 1'b0, f_rxv1 = 1'b0, f_fs1 = 1'b0, f_rxs = 1'b0;
reg [7:0] f_t0, f_txn1;
reg [1:0] f_rxgap = 2'd0, f_fsgap = 2'd0;
always @(posedge clk) begin
    f_cs1 <= cs_on; f_cs2 <= f_cs1; f_rxv1 <= rx_valid; f_fs1 <= frame_start; f_txn1 <= tx_next;
    if (!cs_on) f_t0 <= tx_data;
    if (frame_start) f_rxs <= 1'b0; else if (rx_valid) f_rxs <= 1'b1;
    f_rxgap <= rx_valid ? 2'd0 : (f_rxgap == 2'd3 ? 2'd3 : f_rxgap + 2'd1);
    f_fsgap <= frame_start ? 2'd0 : (f_fsgap == 2'd3 ? 2'd3 : f_fsgap + 2'd1);
end
always @* if (f_on) begin
    if (cs_on && (frame_start || !f_rxs) && !rx_valid) assume(tx_data == f_t0);                   // A1
    if (cs_on && f_cs1 && !f_rxv1 && !f_fs1) assume(tx_next == f_txn1);                            // A2
end

// ---------------- C: the clk-side byte contract ----------------
reg f_on_d = 1'b0;
always @(posedge clk) f_on_d <= f_on;
always @* if (f_on) begin
    if (!f_on_d) assert(!cs_on);
    assert(frame_start == (cs_on && !f_cs1));
    assert(frame_end == (!f_cs1 && f_cs2));
    if (rx_valid) assert(f_cs1 && f_rxgap >= 1 && f_fsgap >= 1);
end

// ---------------- M, S, F ----------------
// master side (global time): bytes sent (taken at each byte's first SCLK rise,
// a rise in the frame_start step included) and bytes read (at byte_done)
reg [7:0] f_m0, f_m1, f_m2;
reg [1:0] f_mst = 2'd0;                     // bytes started in the frame
reg [4:0] f_mr = 5'd0;                      // SCLK rises in the frame
reg [1:0] f_mcnt = 2'd0;                    // bytes read in the frame
always @($global_clock) begin
    if (f_fs) begin
        f_m0 <= f_mcur; f_mst <= 2'd1; f_mr <= f_rise ? 5'd1 : 5'd0; f_mcnt <= 2'd0;
    end else begin
        if (f_rise) begin
            if (f_mr != 5'd31) f_mr <= f_mr + 5'd1;
            if (f_mr[2:0] == 3'd0 && f_mr != 5'd0 && f_mst != 2'd3) begin
                if (f_mst == 2'd1) f_m1 <= f_mcur; else f_m2 <= f_mcur;
                f_mst <= f_mst + 2'd1;
            end
        end
        if (f_bd && f_mcnt != 2'd3) f_mcnt <= f_mcnt + 2'd1;
    end
end
// slave side (clk): bytes received in the frame, and the bytes the master is owed
reg [1:0] f_nrx = 2'd0;
reg [7:0] f_e1, f_e2;
reg       f_v1 = 1'b0, f_v2 = 1'b0;
always @(posedge clk) begin
    if (frame_start) begin f_nrx <= 2'd0; f_v1 <= 1'b0; f_v2 <= 1'b0; end
    else if (rx_valid) begin
        if (f_nrx == 2'd0) begin f_e1 <= tx_next; f_v1 <= 1'b1; end
        if (f_nrx == 2'd1) begin f_e2 <= tx_next; f_v2 <= 1'b1; end
        if (f_nrx != 2'd3) f_nrx <= f_nrx + 2'd1;
    end
end
wire [7:0] f_msent = (f_nrx == 2'd0) ? f_m0 : (f_nrx == 2'd1) ? f_m1 : f_m2;
always @* if (f_on) begin
    if (rx_valid) begin                                  // M
        assert(f_nrx < `FB && f_mst > f_nrx);
        assert(rx_data == f_msent);
    end
    if (frame_end) assert(f_nrx == `FB);                 // F
end
// S: checked when the master finishes reading a byte
always @* if (f_on && f_bd) begin
    if (f_mcnt == 2'd0) assert(cs_on && f_cs1 && f_mrx == f_t0);
    else if (f_mcnt == 2'd1) assert(f_v1 && f_mrx == f_e1);
    else assert(f_v2 && f_mrx == f_e2);
end

// ---------------- X: CDC safety ----------------
reg [7:0] f_rb_p = 8'd0, f_tn_p = 8'd0, f_td_p = 8'd0;
reg [3:0] f_rb_age = 4'd0, f_tn_age = 4'd0, f_td_age = 4'd0, f_t7_age = 4'd0;
reg       f_sck_p = 1'b0, f_ld_p = 1'b0, f_t7_p = 1'b0;
reg [2:0] f_sc_p = 3'd0;
always @($global_clock) begin
    f_rb_p <= rbyte;      f_rb_age <= (rbyte != f_rb_p)   ? 4'd0 : (&f_rb_age ? f_rb_age : f_rb_age + 4'd1);
    f_tn_p <= tx_next;    f_tn_age <= (tx_next != f_tn_p) ? 4'd0 : (&f_tn_age ? f_tn_age : f_tn_age + 4'd1);
    f_td_p <= tx_data;    f_td_age <= (tx_data != f_td_p) ? 4'd0 : (&f_td_age ? f_td_age : f_td_age + 4'd1);
    f_t7_p <= tx_data[7]; f_t7_age <= (tx_data[7] != f_t7_p) ? 4'd0 : (&f_t7_age ? f_t7_age : f_t7_age + 4'd1);
    f_sck_p <= sck; f_ld_p <= ld; f_sc_p <= sc;
end
always @* if (f_on) begin
    // rx_data takes rbyte at the edge ending the cycle in which t_s[1] ^ t_d
    if (t_s[1] ^ t_d) assert(f_rb_age >= `MX && rbyte == f_rb_p);
    // the SCLK domain takes tx_next with the last sampled bit of a byte ...
    if (!f_sck_p && sck && f_sc_p == 3'd7 && !cs_n) assert(f_tn_age >= `MX);
    // ... and tx_data at the first launch of a frame
    if (f_sck_p && !sck && !f_ld_p && !cs_n) assert(f_td_age >= `MX);
    // a mode-0 master reads the MSB from tx_data directly before the first launch
    if (f_smp && f_inf && !ld) assert(f_t7_age >= `MO);
end

// reachability: two complete frames
reg [1:0] f_frames = 2'd0;
always @(posedge clk) if (f_on && frame_end && f_frames != 2'd3) f_frames <= f_frames + 2'd1;
always @* cover(f_on && f_frames == 2'd2);
