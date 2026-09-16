#!/bin/bash
# Reads chrome://version/?show-variations-cmd, which prints the feature state Chrome actually resolved, for
# a headed and a headless launch and for --disable-field-trial-config. Output: data/resolved-features.txt.
# Expects AGENT_BROWSER_ARGS to hold the production list from the README, which already includes
# --enable-features=InitialWebUISurfaceSync:deadline_in_frames/0/renderer_commit_delay_ms/0. The script strips it for the
# arms that run without it.
set -u
PROD="$AGENT_BROWSER_ARGS"
NOFIX=$(printf '%s' "$PROD" | tr ',' '\n' | grep -v '^--enable-features=InitialWebUISurfaceSync' | paste -sd, -)
kill_all() { pkill -9 -f agent-browser-linux; pkill -9 -f '/chrome'; pkill -9 Xvfb; rm -f "$HOME"/.agent-browser/*.sock "$HOME"/.agent-browser/*.pid; sleep 1; } >/dev/null 2>&1
for arm in headed-nofix headless-nofix headed-notrialcfg; do
  kill_all
  mode=--headed; [ $arm = headless-nofix ] && mode=""
  args="$NOFIX"; [ $arm = headed-notrialcfg ] && args="$NOFIX,--disable-field-trial-config"
  export AGENT_BROWSER_ARGS="$args"
  s=feat-$arm
  agent-browser $mode --session $s open "chrome://version/?show-variations-cmd" >/dev/null 2>&1
  echo "=== $arm"
  agent-browser $mode --session $s eval "document.body.innerText" > /tmp/v.txt 2>&1
  sed 's/\\n/\n/g' /tmp/v.txt | grep -E '^(Google Chrome|Variations|Command Line)' | cut -c1-120
  sed 's/\\n/\n/g' /tmp/v.txt | tr ',/' '\n\n' | grep -E 'InitialWebUI|WebUIToolbar|WebUIReload|WebUIHome|WebUIBack|WebUIForward|WebUILocation|WebUISplit|HttpsFirstBalanced|^Translate' | sort | uniq -c | cut -c1-160
  sed 's/\\n/\n/g' /tmp/v.txt | grep -o 'InitialWebUISurfaceSync[.:][^,"]*' | head
  agent-browser --session $s close >/dev/null 2>&1
done
kill_all
