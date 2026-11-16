#!/usr/bin/env bash
# formal/tools/summary.sh — rebuilds build/summary.txt from the sby task folders as they are now
# (no solver runs). Same columns as run.sh. Usage: formal/tools/summary.sh [out-file]
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out=${1:-$here/build/summary.txt}
tasks_of() { sed -n '/^\[tasks\]/,/^$/p' "$here/sby/$1.sby" | awk 'NR > 1 && NF { print $1 }'; }
{
printf '%-4s %-40s %-8s %8s  %s\n' grp proof result time note
for gf in o1:o1_spi o2:o2_fsm f4:f4_silicon n1:n1_spi n1c:n1c_contract n1s:n1s_spi g1:g1_spi \
          n2:n2_top f2:f2_engine f3:f3_core f5:f5_bist f6:f6_exact; do
  g=${gf%%:*} f=${gf#*:}
  for t in $(tasks_of "$f"); do
    d="$here/sby/${f}_$t" st=MISSING secs= where=
    [ -f "$d/status" ] && st=$(awk '{print $1}' "$d/status")
    secs=$(grep -o 'Elapsed clock time \[H:MM:SS (secs)\]: [0-9:]* ([0-9]*)' "$d/logfile.txt" 2>/dev/null | grep -o '([0-9]*)' | tr -d '()' | tail -1)
    where=$(grep -o 'failed assertion.*' "$d/logfile.txt" 2>/dev/null | head -1 | sed 's/.*at \([^ ]*\) step \([0-9]*\)/\1 step \2/')
    printf '%-4s %-40s %-8s %8s  %s\n' "$g" "$f:$t" "$st" "${secs:-?}s" "$where"
  done
done
echo
echo "O1/N1/N1S/G1 sweeps are characterizations: FAIL marks a timing that does not work"
echo "(G1 names ending in _x are expected to FAIL). O2 recover FAILs by design: the original"
echo "ttsky25a FSM has no recovery (the lock-up N2 recover proves fixed)."
} > "$out"
