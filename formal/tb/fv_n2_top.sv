// fv_n2_top.sv — N2: xc_frame with free SPI-side inputs (constrained by the
// N1 contract in xc_frame_props.vh) and the core's contract model.
`default_nettype none
module fv_n2_top (input wire clk, input wire rst_n, input wire proto_pin,
                  input wire [7:0] rx_data, input wire rx_valid, input wire cs_on,
                  input wire frame_start, input wire frame_end);
    wire [7:0] tx_data, tx_next;
    wire c_start, c_busy, c_done, data_ready, busy;
    wire [6:0] c_funct7; wire [2:0] c_funct3; wire [31:0] c_rs1, c_rs2, c_rd;
    wire [1:0] c_flags;
    xc_frame #(.FUNCS(1), .GUARD(`N2_GUARD), .TIMEOUT_LOG2(4)) dut (
        .clk(clk), .rst_n(rst_n), .proto_pin(proto_pin),
        .rx_data(rx_data), .rx_valid(rx_valid), .cs_on(cs_on),
        .frame_start(frame_start), .frame_end(frame_end),
        .tx_data(tx_data), .tx_next(tx_next),
        .c_start(c_start), .c_funct7(c_funct7), .c_funct3(c_funct3),
        .c_rs1(c_rs1), .c_rs2(c_rs2), .c_busy(c_busy), .c_done(c_done), .c_rd(c_rd), .c_flags(c_flags),
        .data_ready(data_ready), .busy(busy));
    xcordic_core #(.FUNCS(1), .GUARD(`N2_GUARD)) core (
        .clk(clk), .rstn(rst_n), .start(c_start), .funct7(c_funct7), .funct3(c_funct3),
        .rs1(c_rs1), .rs2(c_rs2), .busy(c_busy), .done(c_done), .rd(c_rd), .flags(c_flags));
endmodule
`default_nettype wire
