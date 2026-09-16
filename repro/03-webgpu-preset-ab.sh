#!/bin/bash
# Does agent-browser's software-Vulkan preset change the stall rate, and does a
# user --use-angle override it?
#
# Every sample reads the flags off the live Chrome process rather than assuming
# the arm took effect, because a user --use-angle silently wins over the
# preset's --use-angle=vulkan and the two arms would otherwise be identical.
set -u
ROUNDS=${ROUNDS:-12}
URL=${URL:-https://example.com/}
now_us() { local e=$EPOCHREALTIME; local f=${e#*.}; local s=${e%.*}; echo $(( s * 1000000 + 10#$f )); }
kill_all() {
  pkill -9 -f agent-browser-linux-x64 >/dev/null 2>&1
  pkill -9 -f '/chrome' >/dev/null 2>&1
  rm -f "$HOME"/.agent-browser/*.sock "$HOME"/.agent-browser/*.pid 2>/dev/null
  sleep 1
}
chrome_cmdline() {
  local p cl
  for p in $(pgrep -f '/chrome' 2>/dev/null); do
    cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case "$cl" in *--type=*) continue ;; esac
    case "$cl" in *chrome*) printf '%s' "$cl"; return ;; esac
  done
}

trial() {
  local arm="$1" round="$2"
  kill_all
  local s="ab-$arm-$round"
  unset AGENT_BROWSER_WEBGPU AGENT_BROWSER_ARGS
  case "$arm" in
    stock)             ;;
    preset)            export AGENT_BROWSER_WEBGPU=1 ;;
    preset-overridden) export AGENT_BROWSER_WEBGPU=1 AGENT_BROWSER_ARGS='--use-angle=swiftshader' ;;
  esac

  agent-browser --session "$s" open "${URL}?a=$arm-$round" >/dev/null 2>&1
  sleep 0.3
  local t0 t1
  t0=$(now_us); agent-browser --session "$s" screenshot "/tmp/$s.png" >/dev/null 2>&1; t1=$(now_us)

  local cl; cl=$(chrome_cmdline)
  has() { case "$cl" in *"$1"*) printf yes ;; *) printf no ;; esac; }
  printf '{"arm":"%s","round":%d,"shotMs":%d,"angleVulkan":"%s","angleSwiftshader":"%s","unsafeWebgpu":"%s"}\n' \
    "$arm" "$round" "$(( (t1-t0)/1000 ))" \
    "$(has '--use-angle=vulkan')" "$(has '--use-angle=swiftshader')" "$(has '--enable-unsafe-webgpu')"
  agent-browser --session "$s" close >/dev/null 2>&1
  rm -f "/tmp/$s.png"
}

for (( r=1; r<=ROUNDS; r++ )); do
  for arm in stock preset preset-overridden; do trial "$arm" "$r"; done
done
kill_all
