#!/usr/bin/env bash
# inject.sh <source.v> <module> <props.vh> <out.v>
# Copy a third-party Verilog file and add  `include "<props.vh>"  just before
# the endmodule of <module>, so properties can see the module's internals.
# Fails unless the copy differs from the source by exactly that one line.
set -euo pipefail
src=$1; mod=$2; inc=$3; out=$4
awk -v mod="$mod" -v inc="$inc" '
    $0 ~ "^[ \t]*module[ \t]+" mod "([ \t(#]|$)" { inmod = 1 }
    inmod && $0 ~ /^[ \t]*endmodule/ { print "`include \"" inc "\""; inmod = 0; done++ }
    { print }
    END { if (done != 1) { print "inject: module " mod " not found exactly once" > "/dev/stderr"; exit 1 } }
' "$src" > "$out"
# compare against the source with a final newline (awk always writes one)
norm=$(mktemp); trap 'rm -f "$norm"' EXIT
cat "$src" > "$norm"; [ -n "$(tail -c1 "$src")" ] && echo >> "$norm"
added=$(diff "$norm" "$out" | grep -c '^>' || true)
removed=$(diff "$norm" "$out" | grep -c '^<' || true)
if [ "$added" != 1 ] || [ "$removed" != 0 ]; then
    echo "inject: unexpected diff for $src ($added added, $removed removed)" >&2; exit 1
fi
