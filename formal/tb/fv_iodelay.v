// fv_iodelay.v — a wire with an unknown transport delay, for formal models on
// the global time step ($global_clock, 1 tick).
//
// Every transition of `in` reaches `out` after D0..D1 ticks, chosen freely for
// each transition (independently for each instance), never glitching: while a
// transition is in flight `out` holds the old value and may switch to the new
// one once, at any tick. `ok` is low when two transitions are in flight at
// once (the input changed faster than the window allows): properties assert it.
`default_nettype none
module fv_iodelay #(
    parameter D0 = 0,          // minimum delay, ticks
    parameter D1 = 1           // maximum delay, ticks (>= D0, >= 1)
)(
    input  wire in,
    output wire out,
    output wire ok
);
    reg [D1:1] past = {D1{1'b0}};             // past[d] = in, d ticks ago
    always @($global_clock) past <= {past, in} ;
    wire [D1:0] hist = {past, in};            // hist[d] = in at t - d
    wire [D1:0] win  = hist >> D0;            // win[0] = newest, win[D1-D0] = oldest
    localparam [D1:0] MASK = ({{D1{1'b0}}, 1'b1} << (D1 - D0)) - 1'b1;
    wire [D1:0] chg  = (win ^ (win >> 1)) & MASK;   // transitions inside the window
    wire newest = win[0];
    wire oldest = win[D1 - D0];
    wire steady = (newest == oldest) && (chg == 0);
    reg  sw = 1'b0;
    (* anyseq *) wire go;
    assign out = steady ? newest : ((sw | go) ? newest : oldest);
    always @($global_clock) sw <= steady ? 1'b0 : (sw | go);
    // at most one transition inside the window
    assign ok = (chg & (chg - 1)) == 0;
endmodule
`default_nettype wire
