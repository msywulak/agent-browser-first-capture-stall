# agent-browser first-capture stall

The first `screenshot` of an agent-browser session blocks for about 9.5 seconds on roughly half of sessions, on a Linux container with no GPU. Every later screenshot in the same session takes 25 to 50 ms.

This repo holds the scripts and the raw measurements behind two issues filed against vercel-labs/agent-browser:

- [#1859](https://github.com/vercel-labs/agent-browser/issues/1859), the first screenshot of a session blocks until about 10 seconds after browser launch.
- [#1860](https://github.com/vercel-labs/agent-browser/issues/1860), a user `--use-angle` cancels the `--webgpu` preset that reduces it.

Measured on agent-browser 0.37.1 with Chrome for Testing 153.0.8010.36, on Ubuntu 26.04.1 (Linux 6.18.49 x86_64), 4 vCPU, 8 GB, `/dev/shm` 64 MB, inside a Vercel Sandbox Firecracker microVM with no GPU.

## What the measurements show

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
```

Summarise any result file, or the data already in this repo:

```sh
node analyse.mjs data/shipped-vs-previous.jsonl arm
node analyse.mjs data/capture-ordinal.jsonl arm ordinal
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
