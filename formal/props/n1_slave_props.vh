// n1_slave_props.vh — injected into a build copy of src/xc_spi_slave.v. N1:
// byte transport against the timed SPI master, `FB bytes per CS frame.
//
// Theorem (per bit):
//   M  every bit the slave shifts in is the bit the master drove for that SCLK
//      period, at the same bit index of the same byte; each rx_data is the
//      last 8 bits shifted in
//   S  every bit the master samples is bit (7-k) of the byte the slave took
//      for that byte position (byte 0: tx_data in the last idle cycle before
//      the frame, also for an MSB sampled before that cycle; byte n > 0:
//      tx_next at the end of byte n-1)
//   F  each frame produces exactly `FB rx_valid pulses
// Same environment as O1 (spi_master_model, BASE or BASE+1 cycle phases).

reg [3:0] f_rst = 4'd0;
always @(posedge clk) if (!f_rst[3]) f_rst <= f_rst + 4'd1;
always @* assume(rst_n == f_rst[3]);

wire f_sclk, f_mosi, f_cs_n, f_fs, f_fe, f_bd, f_inf, f_smp, f_rise;
wire [7:0] f_mtx, f_mrx, f_mcur;

spi_master_model #(.CPHA(`CPHA), .H(`H), .L(`L), .S(`S), .T(`T), .G(`G), .FRAME_BYTES(`FB), .FREE(1), .STRETCH(1)) f_master (
    .clk(clk), .run(rst_n), .next_byte(8'd0), .miso(miso),
    .sclk(f_sclk), .mosi(f_mosi), .cs_n(f_cs_n),
    .frame_start(f_fs), .frame_end(f_fe), .byte_done(f_bd),
    .m_tx(f_mtx), .m_rx(f_mrx), .in_frame(f_inf), .smp(f_smp), .rise(f_rise), .cur_tx(f_mcur)
);
always @* assume(sclk == f_sclk && mosi == f_mosi && cs_n == f_cs_n && cpha == `CPHA);

// master side: the byte sent at each byte position, by parity of the index.
// Byte 0 is latched at CS fall; byte n >= 1 is the master's byte at its first
// rising edge of that byte (rise number 8n).
reg [7:0] f_mq0, f_mq1;
reg [4:0] f_mrises;          // master rising edges in the frame
reg [4:0] f_nsmp;            // master MISO samples in the frame
// slave side: the byte taken from tx_data at each byte position, by parity
reg [7:0] f_sq0, f_sq1;
reg [3:0] f_sb;              // bytes the slave has completed in the frame
reg [3:0] f_nrx, f_frames;

always @(posedge clk) begin
    if (!rst_n) begin
        f_mrises <= 0; f_nsmp <= 0; f_sb <= 0; f_nrx <= 0; f_frames <= 0;
    end else begin
        if (f_fs) begin
            // with the shortest CS setup the first SCLK edge comes at the end of
            // this cycle already: count it in the new frame
            f_mq0 <= f_mcur; f_mrises <= f_rise ? 5'd1 : 5'd0; f_nsmp <= (f_smp && f_inf) ? 5'd1 : 5'd0;
        end else begin
            if (f_rise) begin
                f_mrises <= f_mrises + 1;
                if (f_mrises[2:0] == 3'd0 && f_mrises != 0) begin
                    if (f_mrises[3]) f_mq1 <= f_mcur; else f_mq0 <= f_mcur;
                end
            end
            if (f_smp && f_inf) f_nsmp <= f_nsmp + 1;
        end
        if (!cs_on) begin
            f_sq0 <= tx_data; f_sb <= 0;
        end else if (sample && bitn == 3'd7) begin
            if (f_sb[0]) f_sq0 <= tx_next; else f_sq1 <= tx_next;
            f_sb <= f_sb + 1;
        end
        if (frame_start) f_nrx <= 0;
        else if (rx_valid && f_nrx != 15) f_nrx <= f_nrx + 1;
        if (f_fe && f_frames != 15) f_frames <= f_frames + 1;
    end
end

wire [4:0] f_nsmp_c     = f_fs ? 5'd0 : f_nsmp;  // samples so far in this frame
wire [3:0] f_mbyte_idx = {1'b0, f_nsmp_c[4:3]};  // byte the master is sampling
wire [2:0] f_mbit      = f_nsmp_c[2:0];
wire [7:0] f_slat      = f_mbyte_idx[0] ? f_sq1 : f_sq0;
wire [7:0] f_msent     = f_sb[0] ? f_mq1 : f_mq0;

// M is checked on what the slave actually shifted in: the cycle after each
// sample, rx_sh[0] is the master's bit for that edge; at rx_valid the byte
// handed over is the shift register (so it is the last 8 checked bits)
reg f_smp_d = 0, f_bit_d = 0;
always @(posedge clk) begin
    f_smp_d <= rst_n && f_rst[3] && sample;
    f_bit_d <= f_msent[3'd7 - bitn];
end
always @* if (rst_n && f_rst[3]) begin
    if (f_smp_d) assert(rx_sh[0] == f_bit_d);
    if (rx_valid) assert(rx_data == rx_sh);
    // S: the master's sample sees the bit of the byte the slave took
    if (f_smp && f_inf) begin
        assert(f_mbyte_idx == f_sb);
        assert(miso == f_slat[3'd7 - f_mbit]);
    end
end

// byte 0 is one snapshot: a mode-0 master may sample the MSB before the
// slave's synchronized CS falls, while the slave still reloads tx_data; the MSB
// it got must be bit 7 of the byte the slave finally took
reg f_msb_v = 0, f_msb = 0;
always @(posedge clk) begin
    if (f_fs) f_msb_v <= 0;
    if (rst_n && f_smp && f_inf && f_nsmp_c == 0 && !cs_on) begin f_msb_v <= 1; f_msb <= miso; end
    if (frame_start) f_msb_v <= 0;
end
always @* if (rst_n && f_rst[3] && frame_start && f_msb_v) assert(f_msb == f_sq0[7]);

reg [3:0] f_settle;
always @(posedge clk) begin
    if (!rst_n) f_settle <= 0;
    else if (f_fe) f_settle <= `G - 2;
    else if (f_settle != 0) f_settle <= f_settle - 1;
end
always @* if (rst_n && f_settle == 1) begin
    assert(f_nrx == `FB);
end

always @* cover(rst_n && f_settle == 1 && f_frames == `NFRAMES);
