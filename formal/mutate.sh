#!/usr/bin/env bash
# mutate.sh — the proofs of the new design are not vacuous: put one known bug at
# a time into a copy of the project; its proof task must FAIL.
#   ./mutate.sh            all mutants      ./mutate.sh n03 n07    selected
#   ./mutate.sh --check    only check that every mutation applies
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
SBY=${SBY:-sby}
work="$here/build/mutants"
mkdir -p "$work"

# id @ file @ sed expression @ sby file @ task @ what the mutant reintroduces
# (no literal @ inside a field: write \x40)
MUTANTS=(
"n01@src/xc_spi_slave.v@s/rx_sh <= {rx_sh\[6:0\], mosi_s\[1\]};/rx_sh <= {rx_sh[6:0], mosi};/@n1_spi@m0_h2_l2_s5@MOSI sampled raw (the ttsky25a race)"
"n02@src/xc_spi_slave.v@s/wire sample = cs_on \& (cpha ? fall : rise);/wire sample = cs_on \& (cpha ? rise : fall);/@n1_spi@m0_h2_l2_s5@slave on the wrong SCLK edge"
"n03@src/xc_spi_slave.v@0,/miso  <= tx_data\[7\];/s//miso  <= 1'b0;/@n1_spi@m0_h5_l5_s3@no MSB preload while CS is high"
"n04@src/xc_spi_slave.v@s/tx_sh    <= tx_next;/tx_sh    <= tx_data;/@n1_spi@m0_h2_l2_s5_fb3@multi-byte frames resend the same byte"
"n05@src/xc_spi_slave.v@s/                    miso  <= tx_sh\[6\];/                    miso  <= tx_sh[7];/@n1_spi@m1_h2_l2_s5@MISO shifted one bit late"
"n06@src/xc_frame.v@s/ccmd\[7\] \&\& (ck >= 4'd5) \&\& cop_ok/ccmd[7] \&\& (ck >= 4'd1) \&\& cop_ok/@n2_top@cmd_g4@EXEC accepted from a frame without RS1"
"n07@src/xc_frame.v@s/c_busy || cexec || (iq_n != 3'd0)};/c_busy || (iq_n != 3'd0)};/@n2_top@cmd_g4@BUSY missing between EXEC and core start"
"n08@src/xc_frame.v@s/wire \[3:0\] ck_next = (ck == 4'hf) ? 4'hf : ck + 4'd1;/wire [3:0] ck_next = ck + 4'd1;/@n2_top@cmd_g4@byte position wraps in long frames (found by N2)"
"n09@src/xc_frame.v@s/c_rs1 <= {{16{lin\[63\]}}, lin\[63:48\]} << GUARD;/c_rs1 <= {{16{lin[63]}}, lin[63:48]};/@n2_top@legacy_g4@legacy atan0 not scaled to the GUARD datapath"
"n10@src/xc_frame.v@s/lout <= {16'd0, c_rd\[15:0\], c_rd\[31:16\]};/lout <= {16'd0, c_rd[31:16], c_rd[15:0]};/@n2_top@legacy_g0@legacy sin and cos swapped"
"n11@src/xc_frame.v@s/wire       ltimeout = \&lquiet;/wire       ltimeout = 1'b0;/@n2_top@recover_g4@no legacy timeout (the ttsky25a lock-up)"
"n12@src/xc_frame.v@s/wire       c_push  = proto \&\& frame_end/wire       c_push  = proto \&\& frame_start/@n2_top@cmd_g4@instruction decided at the wrong frame edge"
"n13@src/xc_frame.v@s/wire \[2:0\] lk_cur = (rx_valid \&\& ls == L_TX) ? lk + 3'd1 : lk;/wire [2:0] lk_cur = lk;/@n2_top@legacy_g0@stale read byte with a one-cycle CS gap (found by N2)"
"n14@src/xc_frame.v@s/if (rx_valid || ls == L_WAIT) lquiet <= 0;/if (rx_valid) lquiet <= 0;/@n2_top@legacy_g4@timeout counts the core's computing time (found by N2)"
"n15@src/xc_frame.v@s/cbyte(csrc, (cs_on \&\& !frame_start) ? ck : 4'd0)/cbyte(csrc, cs_on ? ck : 4'd0)/@n2_top@cmd_g4@STATUS glitch in the frame_start cycle (found in simulation, SPI_SCLK = 1)"
"n16@src/xc_spi_slave_sclk.v@s/parameter CS_OFF = 4 /parameter CS_OFF = 2 /@n1s_spi@m1_h3_l3_s8_t1_g24@cs_on falls as fast as it rises: last byte after frame end"
"n17@src/xc_spi_slave_sclk.v@s/    always \x40(negedge sck)$/    always \x40(posedge sck)/@n1s_spi@m0_h3_l3_s12_t1_g24@MISO launched on the sample edge"
"n18@src/xc_spi_slave_sclk.v@s/wire \[7:0\] nb    = ld ? tn : tx_data;/wire [7:0] nb    = tx_data;/@n1s_spi@m0_h3_l3_s12_t1_g24_fb2@multi-byte frames resend byte 0"
"n19@src/xc_spi_slave_sclk.v@s/assign miso = ld ? mo : tx_data\[7\];/assign miso = mo;/@n1s_spi@m0_h3_l3_s12_t1_g24@no MSB before the first launch (mode 0)"
"n20@src/xc_spi_slave_sclk.v@s/wire \[7:0\] nb    = ld ? tn : tx_data;/wire [7:0] nb    = ld ? tx_next : tx_data;/@n1s_spi@m1_h3_l3_s8_t1_g24_fb2@next byte taken at its first launch: wrong after a pause (found by N1S)"
"n21@src/xc_frame.v@s/(cany \&\& (iq_n == 3'd0) \&\& !c_busy \&\& !cexec \&\& !cpend)/(cany \&\& (iq_n == 3'd0) \&\& !c_busy \&\& !cexec)/@n2_top@cmd_g4@DATA_READY shows the old instruction ready until CS is synchronized (found in simulation)"
"n22@src/xcordic_engine.v@s/.i_iter(iter + 5'd3)/.i_iter(iter + 5'd2)/@f2_engine@prove_g4@angle lookahead shift one iteration late"
"n23@src/xcordic_core.v@s/S_PREP: state <= S_PRE1;/S_PREP: state <= S_PRE;/@f3_core@b_op14_g4@ln mantissa used before it is scaled (pipeline)"
"n24@src/xcordic_core.v@s/                        state <= S_MIDP;       \/\/ rescale: y' this time/                        \/\/ no rescale/@f3_core@b_op19_g4@rotc returns the stale scaled x' as y' (pipeline)"
"n25@src/xcordic_engine.v@s/wire rbit    = lin_rot \&\& xs2\[0\];/wire rbit    = 1'b0;/@f2_engine@prove_g4@linear rotation truncates again (rounding)"
"n26@src/xcordic_engine.v@s/wire zhold   = lin_rot \&\& (o_z == {DATA_WIDTH{1'b0}});/wire zhold   = 1'b0;/@f2_engine@prove_g4@linear rotation keeps iterating at z = 0 (hold)"
"n27@src/xcordic_engine.v@s/localparam LROUND = (GUARD > 0);/localparam LROUND = 1;/@f2_engine@prove_g0@the rounded product pass leaks into GUARD 0 (no longer silicon-exact)"
"n28@src/xc_exact.v@s/wire        incr   = neg ? sticky : 1'b1;/wire        incr   = 1'b1;/@exact@smoke@exact unit rounds negative results like positive ones"
"n29@src/xc_frame.v@s/wire       c_pop   = proto \&\& frame_end \&\& (ck >= 4'd5)/wire       c_pop   = proto \&\& frame_end \&\& (ck >= 4'd1)/@n2_top@cmd_g4@result taken off by a frame too short to read it (queue)"
"n30@src/xc_frame.v@s/(ck >= 4'd5) \&\& cfv \&\& cvalid/(ck >= 4'd5) \&\& cvalid/@n2_top@cmd_g4@result that arrived during a frame taken off unseen (queue)"
"n31@src/xc_frame.v@s/ \&\& (iq_n != 3'd0) \&\& (oq_n != 3'd4);/ \&\& (iq_n != 3'd0);/@n2_top@cmd_g4@instruction started with the result queue full (queue)"
"n32@src/xc_bist.v@s/brs2 <= l2;/brs2 <= l1;/@f5_bist@prove_f1@bist rs2 = rs1 (LFSR stepped once)"
"n33@src/xc_bist.v@s/((FUNCS != 0) ? 5'd8 : 5'd0) :/((FUNCS != 0) ? 5'd7 : 5'd0) :/@f5_bist@bmc_f1@bist issues cfg (would change the cfg registers)"
"n34@src/xc_bist.v@s/if (bk == bn) begin/if (bk + 16'd1 == bn) begin/@f5_bist@prove_f1@bist stops one instruction early"
"n35@src/xc_frame.v@s/ \&\& cop_ok \&\& !cfull;/ \&\& cop_ok;/@n2_top@cmd_g4@EXEC accepted with the instruction queue full (queue; missed while N2 bounded the core to 6 cycles)"
"n36@src/xc_exact.v@s/cnt <= 5'd17;/cnt <= 5'd16;/@exact@smoke@divide runs one step short"
"n37@src/xc_exact.v@s/{1'd0, R\[16:0\], X\[15:14\]};/{1'd0, R[16:0], X[13:12]};/@exact@smoke@square root takes the wrong argument bits"
"n38@src/xc_exact.v@0,/flags <= 2'b10;/s//flags <= 2'b00;/@exact@smoke@division by zero not flagged INV"
"n39@src/xcordic_core.v@s/S_XRUN: if (x_done) finish(sx(x_rd), x_flags);/S_XRUN: if (x_done) finish(sx(x_rd), 2'b00);/@f3_core@b_op17_g4@the core drops the exact unit's flags"
"n40@src/xcordic_core.v@s/S_XRUN: if (x_done) finish(sx(x_rd), x_flags);/S_XRUN: if (x_done) finish({16'd0, x_rd}, x_flags);/@f3_core@b_op16_g4@exact result not sign-extended"
"n41@src/xc_frame.v@s/{6'd0, cflg_out, crd_out, cstatus}/{6'd0, cflg, crd_out, cstatus}/@n2_top@cmd_g4@FLAGS byte of the last result, not of the one shown"
"n42@src/xc_frame.v@s/oq_m\[oq_w\] <= {c_flags, cseq + 4'd1, c_rd};/oq_m[oq_w] <= {2'b00, cseq + 4'd1, c_rd};/@n2_top@cmd_g4@result queue loses the flags"
"n43@src/xcordic_core.v@s/finish({q_rs, q_rc}, {1'b0, q_ss || q_sc_});/finish({q_rs, q_rc}, {1'b0, q_sc_});/@f3_core@b_op0_g4@SAT of one half of a pair missed"
"n44@src/xc_bist.v@s/misr <= lstep(misr) ^ c_rd ^ {c_flags, 30'd0};/misr <= lstep(misr) ^ c_rd;/@f5_bist@prove_f1@self-test signature ignores the flags"
"n45@src/xcordic_atan.v@s/(one_i >> 2) | (one_i >> 4) | (one_i >> 6) | (one_i >> 8) | (one_i >> 10)/(one_i >> 2) | (one_i >> 4) | (one_i >> 6) | (one_i >> 8)/@f2_engine@prove_g4@angle generator pattern loses a term of the 1/3 series (rewrite)"
"n46@src/xcordic_core.v@s/sc_i = sc_h + {{(SCW-1){1'b0}}, 1'b1};/sc_i = sc_h;/@f3_core@b_op13_g4@scaler drops its rounding increment (rewrite)"
"n47@src/xcordic_core.v@s/q_van <= shl(q_va, q_na);/q_van <= q_va;/@f3_core@b_op11_g4@normalization lane registered unshifted (timing register)"
"n48@src/xcordic_core.v@s/if (state == S_MIDP) begin q_psin <= p_sin;/if (state == S_PREP) begin q_psin <= p_sin;/@f3_core@b_op8_g4@sin captured before the engine pass (timing register)"
"n49@src/xcordic_core.v@s/oh <= 20'd1 << in_op;/oh <= 20'd1 << op;/@f3_core@b_op8_g4@one-hot decode taken from the previous instruction"
"n50@src/xcordic_engine.v@s/n2_3  <= 8'd3 \* /n2_3  <= 8'd2 * /@f2_engine@prove_g4@lookahead 3s formed as 2s"
"n51@src/xc_frame.v@s/if (!cs_on \&\& !cs_q \&\& !frame_end \&\& ls == L_IDLE/if (!cs_on \&\& ls == L_IDLE/@n2_top@switch_g4@protocol taken over before the last frame is closed (found in review)"
"n52@src/xc_frame.v@s/ck <= 0; ccmd <= 0; cfv <= 1'b0;       /       /@n2_top@switch_g4@command frame state kept through a legacy session (found in review)"
)

if [ "${1:-}" = --check ]; then
    bad=0
    for m in "${MUTANTS[@]}"; do
        IFS='@' read -r id file expr sbyf task what <<< "$m"
        if ! m=$(sed "$expr" "$root/$file"); then echo "$id: bad sed expression"; bad=1
        elif [ "$m" = "$(cat "$root/$file")" ]; then echo "$id: does not apply"; bad=1; fi
    done
    [ $bad -eq 0 ] && echo "all ${#MUTANTS[@]} mutations apply"
    exit $bad
fi

pick=("$@")
survivors=0
for m in "${MUTANTS[@]}"; do
    IFS='@' read -r id file expr sbyf task what <<< "$m"
    if [ ${#pick[@]} -gt 0 ] && [[ ! " ${pick[*]} " =~ " $id " ]]; then continue; fi
    d="$work/$id"
    rm -rf "$d"; mkdir -p "$d"
    (cd "$root" && tar cf - --exclude=formal/build --exclude=build --exclude='formal/sby/*_*/*' --exclude='formal/equiv/build_*' --exclude=formal/exhaustive/build --exclude=formal/results src formal third_party) | (cd "$d" && tar xf -)
    sed -i "$expr" "$d/$file"
    if cmp -s "$d/$file" "$root/$file"; then echo "$id: mutation did not apply"; survivors=$((survivors + 1)); continue; fi
    # the exact unit's values are the exhaustive check's business, not a
    # proof's: "exact@smoke" runs formal/exhaustive/exact.cpp smoke (corners, every
    # sqrt input, 2M random pairs; seconds) on the mutant
    if [ "$sbyf" = exact ]; then
        H="$d/formal/exhaustive"; B="$H/build/exact"; mkdir -p "$B"
        if ! verilator --cc --exe --build -O2 --Mdir "$B" "$d/src/xc_exact.v" "$H/exact.cpp" -o exact > "$B/build.log" 2>&1; then
            echo "$id: ERROR     the mutant does not build"; survivors=$((survivors + 1)); continue
        fi
        if "$B/exact" "$task" > "$B/run.log" 2>&1; then
            printf '%s: SURVIVED  %-8s %-22s %s\n' "$id" "$sbyf" "$task" "$what"; survivors=$((survivors + 1))
        else
            printf '%s: killed    %-8s %-22s %s\n' "$id" "$sbyf" "$task" "$what"
        fi
        continue
    fi
    mkdir -p "$d/formal/build/gen"
    (cd "$d/formal" && bash -c 'source <(sed -n "/^prepare()/,/^}/p" run.sh); here=$PWD; root=$(cd .. && pwd); B=$here/build; prepare') > /dev/null 2>&1 ||
        { echo "$id: prepare failed"; survivors=$((survivors + 1)); continue; }
    if ! sed -n '/^\[tasks\]/,/^$/p' "$d/formal/sby/$sbyf.sby" | awk '{print $1}' | grep -qx "$task"; then
        echo "$id: ERROR     no task $task in $sbyf.sby"; survivors=$((survivors + 1)); continue
    fi
    res=$(cd "$d/formal/sby" && rm -rf "${sbyf}_$task" && timeout 7200 $SBY -f "$sbyf.sby" "$task" 2>&1 | grep -E "DONE \(" | tail -1)
    case "$res" in
        *"DONE (FAIL"*) printf '%s: killed    %-8s %-22s %s\n' "$id" "$sbyf" "$task" "$what" ;;
        *)              printf '%s: SURVIVED  %-8s %-22s %s  [%s]\n' "$id" "$sbyf" "$task" "$what" "$res"
                        survivors=$((survivors + 1)) ;;
    esac
    rm -rf "$d"
done
[ $survivors -eq 0 ] && echo "all mutants killed" || { echo "$survivors mutant(s) survived"; exit 1; }
