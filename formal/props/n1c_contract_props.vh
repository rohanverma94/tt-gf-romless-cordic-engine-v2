// n1c_contract_props.vh — injected into a build copy of src/xc_spi_slave.v.
// N1c: the facts the N2 contract assumes about the slave, for ANY inputs
// (no master model; unbounded, k-induction):
//   rx_valid only if cs_on was high in the previous cycle, at least 2 cycles
//   after frame_start and after the previous rx_valid; frame_start is cs_on
//   rising; frame_end is one cycle after cs_on falls (so never with rx_valid).
reg f_init = 1'b1;
always @(posedge clk) f_init <= 1'b0;
always @* if (f_init) assume(!rst_n);

reg f_cs1 = 0, f_cs2 = 0, f_rx1 = 0, f_fs1 = 0, f_r1 = 0, f_r2 = 0;
always @(posedge clk) begin
    f_cs1 <= cs_on; f_cs2 <= f_cs1;
    f_rx1 <= rx_valid; f_fs1 <= frame_start;
    f_r1 <= rst_n; f_r2 <= f_r1;
end
// checked from the third cycle out of reset (the mirrors need two cycles of history)
always @* if (!f_init && rst_n && f_r1 && f_r2) begin
    assert(frame_start == (cs_on && !f_cs1));
    if (f_cs1 || f_cs2 || frame_end) assert(frame_end == (!f_cs1 && f_cs2));
    if (rx_valid) begin
        assert(f_cs1);
        assert(!frame_start && !f_fs1);
        assert(!f_rx1);
        assert(!frame_end);
    end
    // helper invariants for induction
    if (rx_valid) assert(cs_d);
    assert(cs_d == f_cs1);
end
