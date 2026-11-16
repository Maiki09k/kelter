#!/bin/zsh

# Builds the Windows web helper shim (shim/webhelper-shim.c) into Resources/steamwebhelper-shim.exe.
# Needs the Zig toolchain in .toolchain/zig (downloaded once from ziglang.org, see README).

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ZIG="$PROJECT_DIR/.toolchain/zig/zig"

if [[ ! -x "$ZIG" ]]; then
  echo "Zig fehlt unter $ZIG (siehe README, Abschnitt Bauen)." >&2
  exit 1
fi

OUT="$PROJECT_DIR/Resources/steamwebhelper-shim.exe"
"$ZIG" cc -target x86_64-windows-gnu -O2 -s -Wl,--subsystem,windows \
  -o "$OUT" "$PROJECT_DIR/shim/webhelper-shim.c"
rm -f "${OUT%.exe}.pdb"
echo "$OUT"
