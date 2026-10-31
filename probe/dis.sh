#!/bin/zsh
# dis.sh <symbol> [bytes] — дизассемблировать функцию из dyld-кэша
D=~/Developer/Lumen/probe
sym=$1; n=${2:-88}
hex=$("$D/dump" "$sym" "$n") || exit 1
{ echo ".text"; echo ".byte ${hex// /,}" } > "$D/.tmp.s"
env -u SDKROOT xcrun --sdk macosx clang -c -target arm64-apple-macos26 "$D/.tmp.s" -o "$D/.tmp.o" 2>/dev/null || exit 1
echo "### $sym"
env -u SDKROOT xcrun llvm-objdump -d --no-leading-addr --no-show-raw-insn "$D/.tmp.o" | tail -n +5
