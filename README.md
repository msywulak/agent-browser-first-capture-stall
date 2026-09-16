# agent-browser first-capture stall

The first `screenshot` of an agent-browser session blocks for about 9.5 seconds on roughly half of sessions, on a Linux container with no GPU. Every later screenshot in the same session takes 25 to 50 ms. The cause is Chrome for Testing's WebUI toolbar, and one Chrome feature parameter removes it. See [Cause](#cause).

This repo holds the scripts and the raw measurements behind two issues filed against vercel-labs/agent-browser:

- [#1859](https://github.com/vercel-labs/agent-browser/issues/1859), the first screenshot of a session blocks until about 10 seconds after browser launch.
- [#1860](https://github.com/vercel-labs/agent-browser/issues/1860), a user `--use-angle` cancels the `--webgpu` preset that reduces it.

Measured on agent-browser 0.37.1 with Chrome for Testing 153.0.8010.36, on Ubuntu 26.04.1 (Linux 6.18.49 x86_64), 4 vCPU, 8 GB, `/dev/shm` 64 MB, inside a Vercel Sandbox Firecracker microVM with no GPU.

## Cause

Chrome for Testing holds the browser window for up to 10 seconds while its WebUI toolbar paints. The `WebUIToolbarWebView` sets a surface-sync deadline of `deadline_in_frames` frames, 600 by default, on the toolbar and the active tab. Viz does not present the window until the toolbar's renderer paints or the deadline passes, and a `fromSurface` screenshot waits with it. agent-browser does not cause this.

The feature is off in Chromium's source. Chrome for Testing is not Chrome-branded, so it applies Chromium's field-trial testing config, which puts it in `WebUIReloadButtonStudy`, group `EnabledWithSurfaceSync_20260609`. [`data/resolved-features.txt`](data/resolved-features.txt) shows the study in `chrome://version/?show-variations-cmd`, and [`data/trace-stalled-capture.txt`](data/trace-stalled-capture.txt) shows the 10,000 ms surface synchronization in a trace of a stalled capture.

One parameter removes the stall:

```sh
AGENT_BROWSER_ARGS='--enable-features=InitialWebUISurfaceSync:deadline_in_frames/0'
```

| configuration | stalls without | stalls with | Fisher exact, two-sided |
|---|---|---|---|
| headless, no preset | 16/30 | 0/30 | p = 2e-6 |
| headed under Xvfb, no preset | 8/54 | 0/78 | p = 6e-4 |
| headed under Xvfb, `AGENT_BROWSER_WEBGPU=1` | 12/144 | 0/144 | p = 4e-4 |

The "with" arms also passed `renderer_commit_delay_ms/0`, except 24 headed no-preset captures that used `deadline_in_frames/0` alone and stalled 0/24. Headed, `--disable-field-trial-config` stalled 0/72 and `--disable-features=InitialWebUI` 0/24.

During a stall the page itself runs normally. In all 20 stalled launches of `06-page-state-probe.sh`, the page stayed `visible`, `requestAnimationFrame` ran at 60 Hz, and timers and `load` fired on time. Only `first-contentful-paint` moved, to 9892-9988 ms, 13-25 ms before the capture returned.

The WebGPU preset and the `--use-angle` override below only changed how often a launch lost this race. The override is still a bug (#1860), and so is the same problem with `--disable-features`, which drops agent-browser's own `--disable-features=Translate`.

## What the measurements showed before the cause was found

The wait is not a cost of capturing. The capture finishes about 10 seconds after the browser launched, whenever you ask for it. Ask 0.6 s after launch and it blocks 9.6 s. Ask 5.6 s after launch and it blocks 4.7 s. Ask 12.6 s after launch and it does not block at all.

Chrome is the one not answering. An `strace` of the daemon's sockets during a stalled capture contains 21 operations in total. `Page.captureScreenshot` goes out 0.6 ms after the request reaches the daemon, and the reply arrives 9.1 s later with no other socket traffic in between. See [`data/strace-stalled-capture.txt`](data/strace-stalled-capture.txt).

Only the first capture in a browser's life pays it. Captures 2 and 3 in the same session did not stall once in 144 attempts.

Setting `AGENT_BROWSER_WEBGPU=1` cuts how often it happens, from 44% to 11% in a direct A/B. That flag turns on agent-browser's software-Vulkan preset, whose own source comment says those flags "produce real pixels in GPU-less containers and CI". It reduces the rate. It does not remove it.

A user `--use-angle` silently cancels that preset. agent-browser appends user args after its own and Chrome honours the last `--use-angle`, so passing `--use-angle=swiftshader` overrides the preset's `--use-angle=vulkan` while the preset's other five flags stay on the command line. The stall rate goes back to 50% and nothing reports that the preset was cancelled.

## Running the scripts

Each script needs `agent-browser` on `PATH` and writes JSON lines to stdout. `04-trace-the-call.sh` also needs `strace`.

```sh
repro/01-first-capture.sh                       # the stall, in the fewest parts
repro/02-launch-delay-sweep.sh                  # the wait is anchored to launch
repro/03-webgpu-preset-ab.sh > out.jsonl        # the preset, and a user override
repro/04-trace-the-call.sh                      # name the call that blocks
repro/05-surface-sync-ab.sh > out.jsonl         # the surface-sync deadline, with the WebGPU preset
repro/06-page-state-probe.sh > out.jsonl        # what the page sees during a stall, headed and headless
repro/07-toolbar-flags-headed.sh > out.jsonl    # each flag that removes it, headed, no preset
repro/08-resolved-features.sh                   # the feature state Chrome resolved
```

Scripts 05 to 08 ran with `AGENT_BROWSER_ARGS` set to the list below and strip or add entries per arm. 06 and 07 serve the probe page from `repro/probe/` on 127.0.0.1:8123, which needs `node`.

```
--disable-quic,--disable-blink-features=AutomationControlled,--no-first-run,--no-default-browser-check,--password-store=basic,--lang=en-US,--enable-unsafe-swiftshader,--ignore-gpu-blocklist,--disable-features=HttpsFirstBalancedModeAutoEnable,--enable-features=InitialWebUISurfaceSync:deadline_in_frames/0/renderer_commit_delay_ms/0
```

Summarise any result file, or the data already in this repo:

```sh
node analyse.mjs data/shipped-vs-previous.jsonl arm
node analyse.mjs data/capture-ordinal.jsonl arm ordinal
node page-state.mjs data/page-state-during-stall.jsonl
```

`pool.mjs` pools every run that recorded the ANGLE backend and sorts each capture by what was on the live Chrome command line, not by the arm it was meant to be. It prints the rate with the preset effective, the rate with it cancelled, and a two-proportion z-test:

```sh
node pool.mjs
```

## Data

Every file is one JSON object per line, one line per timed capture. `shotMs` is the wall-clock duration of the `screenshot` command. A sample counts as stalled at 3000 ms, which is far from either mode: captures land near 30 ms or near 9500 ms and almost nothing falls between.

| file | n | what it varies |
|---|---|---|
| `capture-ordinal.jsonl` | 216 | capture 1, 2 and 3 in one browser, across three configurations |
| `launch-delay-sweep.jsonl` | 96 | the pause between launch and the first capture |
| `raw-cdp-control.jsonl` | 144 | the same Chrome driven over raw CDP instead of agent-browser |
| `webgpu-preset-ab.jsonl` | 144 | the software-Vulkan preset, with and without a user `--use-angle` |
| `preset-overridden.jsonl` | 96 | the preset with a user `--use-angle=swiftshader` cancelling it |
| `shipped-vs-previous.jsonl` | 72 | the two configurations we run in production |
| `knob-sweep.jsonl` | 120 | streaming disabled, WebGPU, scrollbars, WebMCP |
| `dev-shm-and-preset.jsonl` | 144 | `--disable-dev-shm-usage`, alone and with the preset |
| `snapshot-and-second-target.jsonl` | 48 | `snapshot` before the capture, and a second target |
| `strace-stalled-capture.txt` | 21 lines | every socket operation during one stalled capture |
| `surface-sync-ab-1.jsonl` | 144 | no fix (`control`), the zero deadline (`nosync`), `--disable-field-trial-config`, headed with the preset |
| `surface-sync-ab-2.jsonl` | 192 | no fix (`control`) and the zero deadline (`nosync`), headed with the preset |
| `gpu-compositing-flags.jsonl` | 144 | `--disable-gpu-compositing` and `--disable-software-rasterizer`, headed with the preset |
| `page-state-during-stall.jsonl` | 132 | headed and headless, with and without the zero deadline, each with the page's own log in `page` |
| `surface-sync-headed-no-preset.jsonl` | 120 | each flag that removes the stall, headed without the preset |
| `trace-stalled-capture.txt` | excerpt | Viz and compositor events from a Chrome trace of one stalled capture |
| `resolved-features.txt` | excerpt | `chrome://version/?show-variations-cmd`: the toolbar study, and Translate dropped by a second `--disable-features` |

## Method

Arms run interleaved inside each VM, so variance between VMs cannot favour one arm. Three VMs run at once, every capture gets a fresh browser, and each arm has at least 24 samples.

Every sample carries a check of the thing its arm claims to vary, read from the live Chrome process through `/proc/<pid>/cmdline` rather than assumed. This caught two mistakes. A user `--use-angle` was cancelling the WebGPU preset while both arms looked correctly configured. Separately, one of these harnesses had a bug that made every flag column read `yes`, which the uniform output exposed.

Attaching `strace` to the daemon at startup hides the bug. The tracing overhead delays the capture past the deadline, and the stall disappears. Attach it just before the capture instead.

## What the measurements rule out

Each of these got its own arm, with a per-sample check:

| candidate | result |
|---|---|
| custom launch flags and environment | stock stalls at the same rate, 12/24 against 12/24 |
| headed under Xvfb against headless | 12/24 against 10/24 |
| HAR recording, video recording, JPEG against PNG, `set viewport` | no difference |
| the always-on stream subsystem, with `stream disable` | 10/24 against 11/24 |
| `AGENT_BROWSER_HIDE_SCROLLBARS=false` | 13/24 |
| `AGENT_BROWSER_NO_WEBMCP=1` | 14/24 |
| a warm-up capture on `about:blank` | no help, the warm-up stalls instead, 12/24 |
| `snapshot` before the capture | never stalls, and the capture after it still stalled 12/24 |
| `--disable-dev-shm-usage` | 13/36 against 12/36 |
| a second target, wikipedia.org | reproduces, 11/24 |
| CPU starvation | 4 vCPU on an idle VM, and the stalled durations span 60 ms |

`--debug` and `AGENT_BROWSER_DEBUG=1` did not help. The session log holds only browser-discovery lines and nothing about the blocked call.
