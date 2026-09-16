#!/bin/bash
# Is the wait a cost of capturing, or a deadline measured from browser launch?
#
# Only the pause between the launch command returning and the first capture
# changes. Each sample records how long it slept and when the capture finished,
# measured from launch, so an absolute deadline shows up as a constant in
# sinceLaunchMs rather than in shotMs.
set -u
ROUNDS=${ROUNDS:-8}
URL=${URL:-https://example.com/}
now_us() { local e=$EPOCHREALTIME; local f=${e#*.}; local s=${e%.*}; echo $(( s * 1000000 + 10#$f )); }
kill_all() {
  pkill -9 -f agent-browser-linux-x64 >/dev/null 2>&1
  pkill -9 -f '/chrome' >/dev/null 2>&1
  rm -f "$HOME"/.agent-browser/*.sock "$HOME"/.agent-browser/*.pid 2>/dev/null
  sleep 1
}

trial() {
  local delay="$1" round="$2"
  kill_all
  local s="delay$delay-$round"
  local t0 t1
  t0=$(now_us); agent-browser --session "$s" open >/dev/null 2>&1; t1=$(now_us)
  local launched_at=$t1

  [ "$delay" -gt 0 ] && sleep "$delay"
  local nav_start; nav_start=$(now_us)
  agent-browser --session "$s" open "${URL}?d=$delay-$round" >/dev/null 2>&1
  sleep 0.3

  t0=$(now_us); agent-browser --session "$s" screenshot "/tmp/$s.png" >/dev/null 2>&1; t1=$(now_us)
  printf '{"delaySeconds":%d,"round":%d,"shotMs":%d,"sleptMs":%d,"sinceLaunchMs":%d}\n' \
    "$delay" "$round" "$(( (t1-t0)/1000 ))" "$(( (nav_start-launched_at)/1000 ))" "$(( (t1-launched_at)/1000 ))"
  agent-browser --session "$s" close >/dev/null 2>&1
  rm -f "/tmp/$s.png"
}

for (( r=1; r<=ROUNDS; r++ )); do
  for d in 0 5 12; do trial "$d" "$r"; done
done
kill_all
