// o1_slave_props.vh — injected into a build copy of the ttsky25a SPI_Slave
// (formal/tools/inject.sh). O1: byte transport against a timed SPI master.
//
// The environment is spi_master_model: CPOL = 0, one byte per CS frame (the
// original protocol), master mode `CPHA, SCLK high >= `H and low >= `L core
// clocks, CS setup >= `S, every phase BASE or BASE+1 cycles (any asynchronous
// alignment). The FSM side (tx_data) may change at any time.
//
// Theorem (per bit, so every byte of every frame):
//   M  every bit the slave shifts in is the bit the master drove for that SCLK
//      period, at the same bit index
//   S  every bit the master samples from MISO is bit (7-k) of the byte the slave
//      latched from tx_data when it detected CS falling, k = bits sampled so far
//   F  each frame produces exactly one rx_valid and one tx_req, tx_req first,
//      both while the CS pin is still low
// A FAIL is a counterexample: that timing does not work.

reg [3:0] f_rst = 4'd0;
always @(posedge clk) if (!f_rst[3]) f_rst <= f_rst + 4'd1;
always @* assume(rst_n == f_rst[3]);

wire f_sclk, f_mosi, f_cs_n, f_fs, f_fe, f_bd, f_inf, f_smp, f_rise;
wire [7:0] f_mtx, f_mrx, f_mcur;

spi_master_model #(.CPHA(`CPHA), .H(`H), .L(`L), .S(`S), .T(`T), .G(`G), .FREE(1), .STRETCH(1)) f_master (
    .clk(clk), .run(rst_n), .next_byte(8'd0), .miso(miso),
    .sclk(f_sclk), .mosi(f_mosi), .cs_n(f_cs_n),
    .frame_start(f_fs), .frame_end(f_fe), .byte_done(f_bd),
    .m_tx(f_mtx), .m_rx(f_mrx), .in_frame(f_inf), .smp(f_smp), .rise(f_rise), .cur_tx(f_mcur)
);
always @* assume(sclk == f_sclk && mosi == f_mosi && cs_n == f_cs_n);

// ---- per-frame bookkeeping (master side) ----
reg [7:0] f_byte;       // byte the master sends in this frame
reg [3:0] f_nrise;      // SCLK rising edges so far in this frame
reg [3:0] f_nsmp;       // MISO samples so far in this frame
reg [7:0] f_txlat;      // tx_data when the slave saw CS fall
reg       f_lat;
reg [2:0] f_nrx, f_nreq;
reg       f_req_late;
reg [3:0] f_frames;
always @(posedge clk) begin
    if (!rst_n) begin
        f_nrise <= 0; f_nsmp <= 0; f_lat <= 0; f_nrx <= 0; f_nreq <= 0; f_req_late <= 0; f_frames <= 0;
    end else begin
        if (f_fs) begin
            // with the shortest CS setup the first SCLK edge comes at the end of
            // this cycle already: count it in the new frame
            f_byte <= f_mcur;           // the master latched it at the CS-fall edge
            f_nrise <= f_rise ? 4'd1 : 4'd0; f_nsmp <= f_smp ? 4'd1 : 4'd0;
            f_lat <= 0; f_nrx <= 0; f_nreq <= 0; f_req_late <= 0;
        end else begin
            if (f_rise) f_nrise <= f_nrise + 1;
            if (f_smp)  f_nsmp <= f_nsmp + 1;
        end
        if (cs_falling && !f_lat) begin f_txlat <= tx_data; f_lat <= 1; end
        if (rx_valid && f_nrx != 7) f_nrx <= f_nrx + 1;
        if (tx_req) begin
            if (f_nreq != 7) f_nreq <= f_nreq + 1;
            if (f_nrx != 0) f_req_late <= 1;
        end
        if (f_fe && f_frames != 15) f_frames <= f_frames + 1;
    end
end

always @* if (rst_n && f_rst[3]) begin
    // M: the slave samples MOSI (mode-0 slave: on its detected rising edge)
    if (sample_edge && cs_active) begin
        assert(bit_count == f_nrise - 1);                 // the edge the master made
        assert(mosi == f_byte[3'd7 - bit_count[2:0]]);    // the bit it drove for it
    end
    // S: the master samples MISO (in the frame_start cycle the counters still
    // hold the previous frame's values: this frame has no samples yet)
    if (f_smp && f_inf) begin
        assert(f_lat && !f_fs);
        assert(miso == f_txlat[3'd7 - f_nsmp[2:0]]);
    end
end

// F: checked once the frame is over and the synchronizers have flushed
reg [3:0] f_settle;
always @(posedge clk) begin
    if (!rst_n) f_settle <= 0;
    else if (f_fe) f_settle <= `G - 2;
    else if (f_settle != 0) f_settle <= f_settle - 1;
end
// both pulses come while the CS pin is low (used by the O2 contract)
always @* if (rst_n && f_rst[3] && (rx_valid || tx_req)) assert(!cs_n);

always @* if (rst_n && f_settle == 1) begin
    assert(f_nrx == 1);
    assert(f_nreq == 1);
    assert(!f_req_late);
end

always @* cover(rst_n && f_settle == 1 && f_frames == `NFRAMES);
