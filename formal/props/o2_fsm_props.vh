// o2_fsm_props.vh — injected into a build copy of the ttsky25a cordic_fsm
// (top_fsm.v). O2: the frame protocol, with SPI_Slave and top_CORDIC_Engine_v1
// replaced by their contracts (formal/models; O1 and F4 discharge them).
//
// A byte-level master drives cs_n: frames (CS low >= 3 cycles), gaps >= 2.
//   O2A (`O2_FREE undefined): the master follows the documented protocol
//        forever: 8 write frames, wait for data_ready, 6 read frames.
//        Theorem: each transaction launches the CORDIC exactly once, with
//        {atan0, alpha, y, x} = the 8 bytes written (little endian), and the 6
//        bytes read are {alpha, cos, sin} of that launch (little endian, sin first);
//        and the FSM ends it back in its reset state (idle, counters 0, no launch
//        pending, DATA_READY low). Proved unbounded (PDR), for every transaction.
//   O2B (`O2_FREE defined): before that, the master may do any frames at all
//        (a lost byte, a read before data_ready, an aborted transaction), then
//        keeps CS high for `O2_QUIET cycles and starts following the protocol.
//        Same theorem for the transactions after that point: recovery.

reg [3:0] f_rst = 4'd0;
always @(posedge i_clk) if (!f_rst[3]) f_rst <= f_rst + 4'd1;
always @* assume(rst_n == f_rst[3]);
wire f_on = f_rst[3];

// ---------------- byte-level master ----------------
(* anyseq *) wire f_any_end, f_any_go;
localparam [1:0] MG = 0, ML = 1;
reg [1:0] f_ms;            // gap / low
reg [3:0] f_cnt;
reg       f_cs = 1'b1;
reg       f_proto;         // following the protocol
reg [3:0] f_k;             // frames done in the current phase
reg       f_rd;            // current phase: 0 = writing, 1 = reading
reg [7:0] f_quiet;
always @* assume(cs_n == f_cs);

`ifdef O2_FREE
initial f_proto = 1'b0;
`else
initial f_proto = 1'b1;
`endif

always @(posedge i_clk) begin
    if (!f_on) begin
        f_ms <= MG; f_cnt <= 0; f_cs <= 1; f_k <= 0; f_rd <= 0; f_quiet <= 0;
    end else case (f_ms)
        MG: begin
            if (f_cnt != 4'hf) f_cnt <= f_cnt + 1;
            if (!f_proto) begin
                // free phase: any frames; or go quiet and switch to the protocol
                if (f_quiet != 0) begin
                    f_quiet <= f_quiet - 1;
                    if (f_quiet == 1) begin f_proto <= 1; f_k <= 0; f_rd <= 0; f_cnt <= 0; end
                end else if (f_any_go) f_quiet <= `O2_QUIET;
                else if (f_cnt >= 2 && f_any_end) begin f_cs <= 0; f_ms <= ML; f_cnt <= 0; end
            end else if (f_cnt >= 2 && f_any_end && (!f_rd || f_k != 0 || data_ready)) begin
                // reads start only once data_ready is high
                f_cs <= 0; f_ms <= ML; f_cnt <= 0;
            end
        end
        ML: begin
            if (f_cnt != 4'hf) f_cnt <= f_cnt + 1;
            if (f_cnt >= 3 && f_any_end) begin
                f_cs <= 1; f_ms <= MG; f_cnt <= 0;
                if (f_proto) begin
                    if (!f_rd && f_k == 7) begin f_rd <= 1; f_k <= 0; end
                    else if (f_rd && f_k == 5) begin f_rd <= 0; f_k <= 0; end
                    else f_k <= f_k + 1;
                end
            end
        end
        default: f_ms <= MG;
    endcase
end

// ---------------- what the protocol promises ----------------
// mirror of the slave's 3-stage CS synchronizer: the byte the master reads in
// a frame is spi_tx_data when the synchronized CS falls
reg [2:0] f_cs_sync;
always @(posedge i_clk or negedge rst_n)
    if (!rst_n) f_cs_sync <= 3'b111; else f_cs_sync <= {f_cs_sync[1:0], cs_n};
wire f_cs_fall = f_cs_sync[2:1] == 2'b10;

reg [63:0] f_wr;           // bytes written in this transaction
reg [47:0] f_res;          // CORDIC results of this transaction
reg        f_launched, f_have_res;
reg [3:0]  f_rx_k;         // write bytes received by the slave in this transaction
reg [3:0]  f_rd_k;         // read frames started
reg        f_in_txn;       // inside a protocol transaction
reg [3:0]  f_txns;
// protocol transactions begin with the first frame after the switch
always @(posedge i_clk) begin
    if (!f_on) begin
        f_launched <= 0; f_have_res <= 0; f_rx_k <= 0; f_rd_k <= 0; f_in_txn <= 0; f_txns <= 0;
    end else begin
        if (f_proto && f_ms == MG && !f_rd && f_k == 0 && f_cnt >= 2 && f_any_end && !f_in_txn) begin
            // first write frame of a transaction
            f_in_txn <= 1; f_launched <= 0; f_have_res <= 0; f_rx_k <= 0; f_rd_k <= 0;
        end
        if (f_in_txn && spi_rx_valid && f_rx_k < 8) begin
            case (f_rx_k[2:0])
                3'd0: f_wr[7:0]   <= spi_rx_data;  3'd1: f_wr[15:8]  <= spi_rx_data;
                3'd2: f_wr[23:16] <= spi_rx_data;  3'd3: f_wr[31:24] <= spi_rx_data;
                3'd4: f_wr[39:32] <= spi_rx_data;  3'd5: f_wr[47:40] <= spi_rx_data;
                3'd6: f_wr[55:48] <= spi_rx_data;  default: f_wr[63:56] <= spi_rx_data;
            endcase
            f_rx_k <= f_rx_k + 1;
        end
        if (f_in_txn && valid_cordic_angle) f_launched <= 1;
        if (f_in_txn && o_valid_out) begin f_res <= {out_alpha, out_costheta, out_sintheta}; f_have_res <= 1; end
        if (f_in_txn && f_rd && f_cs_fall) f_rd_k <= f_rd_k + 1;
        // transaction over after its 6th read frame ends
        if (f_in_txn && f_rd && f_k == 5 && f_ms == ML && f_cnt >= 3 && f_any_end) begin
            f_in_txn <= 0; if (f_txns != 15) f_txns <= f_txns + 1;
        end
    end
end

wire [47:0] f_res_sh = f_res >> {f_rd_k, 3'b000};
wire [7:0]  f_res_byte = f_res_sh[7:0];

always @* if (f_on && f_in_txn) begin
    // the CORDIC is launched once, after all 8 bytes, with exactly those bytes
    if (valid_cordic_angle) begin
        assert(!f_launched);
        assert(f_rx_k == 8);
        assert({in_atan_0, in_alpha, in_y, in_x} == f_wr);
    end
    // each read frame returns the next result byte
    if (f_rd && f_cs_fall) begin
        assert(f_have_res);
        assert(spi_tx_data == f_res_byte);
    end
end

// the transaction leaves the FSM as reset left it (data registers are all
// overwritten before they are used again)
reg [1:0] f_after;
always @(posedge i_clk) begin
    if (!f_on) f_after <= 0;
    else if (f_in_txn && f_rd && f_k == 5 && f_ms == ML && f_cnt >= 3 && f_any_end) f_after <= 1;
    else if (f_after != 0) f_after <= (f_after == 3) ? 2'd0 : f_after + 2'd1;   // one check per transaction
end
always @* if (f_on && f_after == 3 && cs_n) begin
    assert(state == S_IDLE && rx_byte_count == 0 && tx_byte_count == 0);
    assert(!valid_cordic_angle && !data_ready);
end

// reachability: complete transactions
always @* cover(f_on && f_txns == `O2_TXNS);
