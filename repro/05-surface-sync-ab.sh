#!/bin/bash
# The WebUI toolbar surface-sync deadline A/B, headed with the WebGPU preset (AGENT_BROWSER_WEBGPU=1).
# Arm names: control has no fix, nosync adds deadline_in_frames/0/renderer_commit_delay_ms/0, notrialcfg adds
# --disable-field-trial-config. Expects AGENT_BROWSER_ARGS to hold the README's list without the InitialWebUISurfaceSync entry.
# Run 1 used arms=(control nosync notrialcfg), run 2 arms=(control nosync).
set -u
VM=${VM:-v?}; ROUNDS=${ROUNDS:-12}; URL=${URL:-https://example.com/}
BASE_ARGS="$AGENT_BROWSER_ARGS"
now_us() { local e=$EPOCHREALTIME; echo $(( ${e%.*} * 1000000 + 10#${e#*.} )); }
kill_all() {
  pkill -9 -f agent-browser-linux >/dev/null 2>&1
  pkill -9 -f '/chrome' >/dev/null 2>&1
  pkill -9 Xvfb >/dev/null 2>&1
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
gpu_cmdline() {
  local p cl
  for p in $(pgrep -f -- '--type=gpu-process' 2>/dev/null); do
    cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) && { printf '%s' "$cl"; return; }
  done
}
trial() {
  local arm="$1" round="$2" s="sy-$1-$2"
  kill_all
  case "$arm" in
    control)   export AGENT_BROWSER_ARGS="$BASE_ARGS" ;;
    nosync)    export AGENT_BROWSER_ARGS="$BASE_ARGS,--enable-features=InitialWebUISurfaceSync:deadline_in_frames/0/renderer_commit_delay_ms/0" ;;
    notrialcfg) export AGENT_BROWSER_ARGS="$BASE_ARGS,--disable-field-trial-config" ;;
  esac
  agent-browser --headed --session "$s" open "${URL}?a=$arm-$round" >/dev/null 2>&1
  sleep 0.3
  local t0 t1; t0=$(now_us)
  agent-browser --headed --session "$s" screenshot "/tmp/$s.png" >/dev/null 2>&1; local rc=$?
  t1=$(now_us)
  local size; size=$(stat -c %s "/tmp/$s.png" 2>/dev/null || echo 0)
  local cl gcl; cl=$(chrome_cmdline); gcl=$(gpu_cmdline)
  f() { case "$cl" in *"$1"*) printf yes ;; *) printf no ;; esac; }
  local webgl
  webgl=$(agent-browser --headed --session "$s" eval "(()=>{const g=document.createElement('canvas').getContext('webgl');if(!g)return 'none';const d=g.getExtension('WEBGL_debug_renderer_info');return d?g.getParameter(d.UNMASKED_RENDERER_WEBGL):'noinfo'})()" 2>/dev/null | tr -d '"\n' | cut -c1-90)
  printf '{"vm":"%s","arm":"%s","round":%d,"shotMs":%d,"rc":%d,"png":%s,"syncParam":"%s","noTrialCfg":"%s","angleVulkan":"%s","headed":"%s","gpuProc":"%s","webgl":"%s"}\n' \
    "$VM" "$arm" "$round" "$(( (t1-t0)/1000 ))" "$rc" "$size" \
    "$(f "InitialWebUISurfaceSync:deadline_in_frames/0/renderer_commit_delay_ms/0")" "$(f "--disable-field-trial-config")" "$(f --use-angle=vulkan)" \
    "$(case "$cl" in *--headless*) printf no ;; *) printf yes ;; esac)" \
    "$([ -n "$gcl" ] && echo yes || echo no)" "$webgl"
  agent-browser --session "$s" close >/dev/null 2>&1
  rm -f "/tmp/$s.png"
}
arms=(control nosync)
for (( r=1; r<=ROUNDS; r++ )); do
  # rotate order each round so no arm always runs first after a VM event
  for k in 0 1; do trial "${arms[$(( (r+k) % 2 ))]}" "$r"; done
done
kill_all
