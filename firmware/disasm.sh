#!/bin/sh
# Regenerate a best-effort disassembly of a NIU KQi controller firmware image.
#
# The controllers run a 16-bit big-endian M-CORE-family core (see ANALYSIS.md
# for how that was determined).  radare2's `mcore` decoder is the closest one
# that ships in a package manager; it is not exact (a few pc-relative forms
# render odd operands), but branch targets resolve and the instruction mix is
# right.  For a faithful listing use a C-SKY/M-CORE binutils objdump instead.
#
# Usage: ./disasm.sh [image.bin] [out.asm]
set -eu
BIN="${1:-KAB2FV20.bin}"
OUT="${2:-${BIN%.bin}.asm}"
BASE=0xC0000000
command -v r2 >/dev/null 2>&1 || { echo "need radare2:  brew install radare2" >&2; exit 1; }
[ -f "$BIN" ] || { echo "no $BIN (run: ../bin/kqi firmware pull)" >&2; exit 1; }
SZ=$(wc -c < "$BIN")
r2 -e scr.color=0 -a mcore -b 32 -e cfg.bigendian=true -m "$BASE" \
   -qc "s $BASE; pD $SZ" "$BIN" > "$OUT"
echo "wrote $OUT ($(grep -c '^' "$OUT") lines) from $BIN @ $BASE"
