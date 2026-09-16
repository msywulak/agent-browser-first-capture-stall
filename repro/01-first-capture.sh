#!/bin/bash
# The stall, in the fewest moving parts. No environment variables, no flags.
#
# Each trial opens a page in a fresh session, takes two screenshots, and prints
# how long each one took. The first is usually ~9.5 s. The second is ~30 ms.
set -u
N=${N:-14}
URL=${URL:-https://example.com/}
ms() { local e=$EPOCHREALTIME; echo $(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }

printf '%-6s %12s %12s\n' trial first_ms second_ms
for i in $(seq 1 "$N"); do
  s="repro-$i-$$"
  agent-browser --session "$s" open "${URL}?i=$i" >/dev/null 2>&1

  a=$(ms); agent-browser --session "$s" screenshot "/tmp/$s-1.png" >/dev/null 2>&1; b=$(ms)
  c=$(ms); agent-browser --session "$s" screenshot "/tmp/$s-2.png" >/dev/null 2>&1; d=$(ms)

  printf '%-6s %12s %12s\n' "$i" "$((b-a))" "$((d-c))"
  agent-browser --session "$s" close >/dev/null 2>&1
  rm -f "/tmp/$s-1.png" "/tmp/$s-2.png"
done
