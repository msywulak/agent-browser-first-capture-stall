#!/bin/bash
# Show that Chrome is the one not answering.
#
# Attach strace to the daemon just before the capture and print every socket
# operation. Attaching earlier changes the result: strace slows startup enough
# that the capture lands after the deadline and the stall disappears.
set -u
URL=${URL:-https://example.com/}
now_us() { local e=$EPOCHREALTIME; local f=${e#*.}; local s=${e%.*}; echo $(( s * 1000000 + 10#$f )); }
kill_all() {
  pkill -9 -f agent-browser-linux-x64 >/dev/null 2>&1
  pkill -9 -f '/chrome' >/dev/null 2>&1
  pkill -9 -f strace >/dev/null 2>&1
  rm -f "$HOME"/.agent-browser/*.sock "$HOME"/.agent-browser/*.pid 2>/dev/null
  sleep 1
}

for i in $(seq 1 12); do
  kill_all
  s="trace-$i"
  agent-browser --session "$s" open >/dev/null 2>&1
  daemon=$(pgrep -f agent-browser-linux-x64 | head -1)
  [ -z "$daemon" ] && continue
  agent-browser --session "$s" open "${URL}?t=$i" >/dev/null 2>&1
  sleep 0.2

  rm -f /tmp/stall.trace
  strace -f -tt -T -s 120 \
    -e trace=sendto,recvfrom,write,read,writev,readv \
    -p "$daemon" -o /tmp/stall.trace >/dev/null 2>&1 &
  tracer=$!
  sleep 0.3

  t0=$(now_us)
  agent-browser --session "$s" screenshot "/tmp/$s.png" >/dev/null 2>&1
  t1=$(now_us)
  kill -INT "$tracer" 2>/dev/null; wait "$tracer" 2>/dev/null
  shot_ms=$(( (t1-t0)/1000 ))
  echo "iteration $i: screenshot took ${shot_ms} ms"

  if [ "$shot_ms" -gt 3000 ]; then
    echo "Stalled. Every socket operation during the capture:"
    cat /tmp/stall.trace
    break
  fi
done
kill_all
