#!/bin/bash
# Headed, no WebGPU preset: no fix, both surface-sync parameters, deadline_in_frames/0 alone,
# --disable-field-trial-config, and --disable-features=InitialWebUI (which replaces the HTTPS-First switch).
# Expects AGENT_BROWSER_ARGS to hold the production list from the README, which already includes
# --enable-features=InitialWebUISurfaceSync:deadline_in_frames/0/renderer_commit_delay_ms/0. The script strips it for the
# arms that run without it.
set -u
VM=${VM:-v?}; ROUNDS=${ROUNDS:-10}; URL=http://127.0.0.1:8123/
FIX="--enable-features=InitialWebUISurfaceSync:deadline_in_frames/0/renderer_commit_delay_ms/0"
# production args without the fix (the arms add it back) and without the preset (stalls are rarer with it)
BASE_ARGS=$(printf '%s' "$AGENT_BROWSER_ARGS" | tr ',' '\n' | grep -v '^--enable-features=InitialWebUISurfaceSync' | paste -sd, -)
NOHTTPS_ARGS=$(printf '%s' "$AGENT_BROWSER_ARGS" | tr ',' '\n' | grep -v '^--disable-features=HttpsFirstBalancedModeAutoEnable' | paste -sd, -)
PROD_ARGS="$AGENT_BROWSER_ARGS"
now_us() { local e=$EPOCHREALTIME; echo $(( ${e%.*} * 1000000 + 10#${e#*.} )); }
kill_all() {
  pkill -9 -f agent-browser-linux >/dev/null 2>&1; pkill -9 -f '/chrome' >/dev/null 2>&1; pkill -9 Xvfb >/dev/null 2>&1
  rm -f "$HOME"/.agent-browser/*.sock "$HOME"/.agent-browser/*.pid 2>/dev/null; sleep 1
}
browser_cmdline() {
  local p exe cl
  for p in $(pgrep -f '/chrome' 2>/dev/null); do
    exe=$(readlink /proc/$p/exe 2>/dev/null); case "$exe" in */chrome|*/chrome-headless-shell) ;; *) continue ;; esac
    cl=$(tr '\0' '\n' < /proc/$p/cmdline); case "$cl" in *--type=*) continue ;; esac
    printf '%s' "$cl"; return
  done
}
child_cmdline() { # $1 = process type
  local p
  for p in $(pgrep -f -- "--type=$1" 2>/dev/null); do tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null && return; done
}
# every --disable-features / --enable-features value on a command line, joined with |
switches() { grep -E "^--$1=" | cut -d= -f2- | paste -sd'|' - | tr -d '"\\' ; }
trial() {
  local arm="$1" round="$2" s="vis-$1-$2" mode args preset=0
  case "$arm" in
    headed-nofix)      mode=--headed; args="$BASE_ARGS" ;;
    headed-both)       mode=--headed; args="$BASE_ARGS,$FIX" ;;
    headed-deadline)   mode=--headed; args="$BASE_ARGS,--enable-features=InitialWebUISurfaceSync:deadline_in_frames/0" ;;
    headed-notrialcfg) mode=--headed; args="$BASE_ARGS,--disable-field-trial-config" ;;
    headed-noinitial)  mode=--headed; args="$(printf '%s' "$BASE_ARGS" | tr ',' '\n' | grep -v '^--disable-features=' | paste -sd, -),--disable-features=InitialWebUI" ;;
  esac
  kill_all
  export AGENT_BROWSER_ARGS="$args"
  if [ $preset = 1 ]; then export AGENT_BROWSER_WEBGPU=1; else unset AGENT_BROWSER_WEBGPU; fi
  local tl t0 t1
  tl=$(now_us)
  agent-browser $mode --session "$s" open "${URL}?a=$arm-$round" >/dev/null 2>&1
  sleep 0.3
  t0=$(now_us)
  agent-browser $mode --session "$s" screenshot "/tmp/$s.png" >/dev/null 2>&1; local rc=$?
  t1=$(now_us)
  # let the page run past the 10 s deadline before reading what it saw
  local left=$(( 14000000 - ($(now_us) - tl) )); [ $left -gt 0 ] && sleep "$(awk "BEGIN{print $left/1000000}")"
  local v; v=$(agent-browser $mode --session "$s" eval "JSON.stringify(window.__v||null)" 2>/dev/null | tail -1)
  case "$v" in \"*) v=$(printf '%s' "$v" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s)))') ;; esac
  [ -z "$v" ] && v=null
  local bcl gcl rcl; bcl=$(browser_cmdline); gcl=$(child_cmdline gpu-process); rcl=$(child_cmdline renderer)
  printf '{"vm":"%s","arm":"%s","round":%d,"launchUs":%s,"shotStartUs":%s,"shotMs":%d,"rc":%d,"headed":"%s","fixOnCmdline":"%s","preset":"%s","browserDisable":"%s","gpuDisable":"%s","rendererDisable":"%s","rendererEnableHasSync":"%s","argsTail":"%s","page":%s}\n' \
    "$VM" "$arm" "$round" "$tl" "$t0" "$(( (t1-t0)/1000 ))" "$rc" \
    "$(case "$bcl" in *--headless*) printf no ;; '') printf unknown ;; *) printf yes ;; esac)" \
    "$(case "$bcl" in *deadline_in_frames/0*) printf yes ;; *) printf no ;; esac)" \
    "$(case "$bcl" in *--use-angle=vulkan*) printf yes ;; *) printf no ;; esac)" \
    "$(printf '%s' "$bcl" | switches disable-features)" "$(printf '%s' "$gcl" | switches disable-features)" "$(printf '%s' "$rcl" | switches disable-features)" \
    "$(case "$rcl" in *InitialWebUISurfaceSync*) printf yes ;; *) printf no ;; esac)" "$(printf '%s' "$bcl" | grep -E '^--(disable-field-trial-config|(en|dis)able-features=)' | paste -sd' ' - | tr -d '"')" "$v"
  agent-browser --session "$s" close >/dev/null 2>&1
  rm -f "/tmp/$s.png"
}
node "$(dirname "$0")/probe/server.mjs" & SERVER=$!
sleep 1
curl -s -o /dev/null -w 'server %{http_code}\n' http://127.0.0.1:8123/ >&2
arms=(headed-nofix headed-both headed-deadline headed-notrialcfg headed-noinitial)
for (( r=1; r<=ROUNDS; r++ )); do
  for (( k=0; k<5; k++ )); do trial "${arms[$(( (k + r) % 5 ))]}" "$r"; done
done
kill_all; kill $SERVER
