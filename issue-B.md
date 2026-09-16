### Summary

On a Linux container with no GPU, the first `screenshot` of a browser session
blocks for about 9.5 seconds on roughly half of sessions, then returns a correct
image. Every later screenshot in the same session takes 25 to 50 ms.

Two measurements narrow it down.

The wait is not a cost of capturing. The capture finishes about 10 seconds after
the browser launched, whenever you ask for it. Ask 0.6 s after launch and it
blocks 9.6 s. Ask 5.6 s after launch and it blocks 4.7 s. Ask 12.6 s after
launch and it does not block.

The daemon is not the one waiting. `Page.captureScreenshot` goes out on the wire
immediately and Chrome does not answer for 9.1 s.

This reads as Chrome needing about 10 seconds before it can serve a
`fromSurface` capture here, with the first capture waiting on that. We open one
page per browser, so every capture we take is a first capture.

### Reproduce

No environment variables, no flags.

```bash
#!/bin/bash
set -u
N=${N:-14}
ms() { local e=$EPOCHREALTIME; echo $(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }

printf '%-6s %12s %12s\n' trial first_ms second_ms
for i in $(seq 1 "$N"); do
  s="repro-$i-$$"
  agent-browser --session "$s" open "https://example.com/?i=$i" >/dev/null 2>&1
  a=$(ms); agent-browser --session "$s" screenshot "/tmp/$s-1.png" >/dev/null 2>&1; b=$(ms)
  c=$(ms); agent-browser --session "$s" screenshot "/tmp/$s-2.png" >/dev/null 2>&1; d=$(ms)
  printf '%-6s %12s %12s\n' "$i" "$((b-a))" "$((d-c))"
  agent-browser --session "$s" close >/dev/null 2>&1
  rm -f "/tmp/$s-1.png" "/tmp/$s-2.png"
done
```

One unedited run:

```
trial      first_ms    second_ms
1              9668           42
2              9651           45
3                42           31
4                50           35
5              9641           47
6              9633           32
7              9642           32
8              9643           46
9              9611           48
10               35           30
11               60           49
12             9672           45
13             9659           33
14               45           33
```

9 of 14 first captures blocked between 9611 and 9672 ms. All 14 second captures
took 30 to 49 ms. I expected the first capture to cost about what the second
costs.

### The wait is anchored to browser launch

Only the delay between launch and the first capture changes. 24 samples per arm,
3 VMs, arms interleaved inside each VM:

| delay from launch to capture | stalls | stalled duration | capture finished, from launch |
|---|---|---|---|
| 0.6 s | 7/24 | 9647-9700 ms | 10611-10715 ms |
| 5.6 s | 10/24 | 4671-4726 ms | 10596-10721 ms |
| 12.6 s | 0/24 | none | none |

The stall shrinks by exactly the delay added, while the moment the capture
finishes stays fixed. In a barer sequence, with no `set viewport` and headless,
that constant was 9944 to 10005 ms from launch.

### Chrome is the one not answering

`strace` of the daemon's sockets during a stalled capture. These are all 21
socket operations in the whole 9.1 seconds:

```
01:28:54.166326 recvfrom(13, "{\"action\":\"screenshot\",...}", ...) = 125   # CLI to daemon
01:28:54.166491 sendto(11, <45 bytes>)                                      # Browser.getVersion
01:28:54.166822 recvfrom(11, "{\"id\":17,\"result\":{\"protocolVersion\":\"1.3\"...")
01:28:54.166931 sendto(11, <143 bytes>)                                     # Page.captureScreenshot, id 18
        ... 9.1 s, no socket activity at all ...
01:29:03.285847 recvfrom(11, "{\"id\":18,\"result\":{\"data\":\"iVBORw0KGgo...")
01:29:03.286670 write(12, <PNG, 16119 bytes>)
```

The daemon issues the call 0.6 ms after the request reaches it. The reply comes
9.1 s later.

Tracing changes the result, which is worth knowing before you try it. Attaching
`strace` to the daemon at startup slows it enough that the capture lands past
the deadline, and the stall disappears: 0 stalls in 10 runs. Attach just before
the capture instead.

### The WebGPU preset moves the rate

`AGENT_BROWSER_WEBGPU=1` is the only setting that changed anything. Its flags
carry the comment "produces real pixels in GPU-less containers and CI".

| configuration | stalls | rate |
|---|---|---|
| stock, headless | 18/36 | 50% |
| stock plus `AGENT_BROWSER_WEBGPU=1` | 6/36 | 17% |

Pooled over 384 captures sorted by what was on the live Chrome command line, the
preset was effective in 39/168 stalls (23%) and absent or cancelled in 78/216
(36%), z = 2.72, p = 0.0065. It lowers the rate and does not remove it.

A user `--use-angle` cancels the preset without saying so. I filed that
separately.

### What this rules out

Each candidate got its own arm, interleaved per VM, with every sample checked
against the live Chrome `/proc/<pid>/cmdline`:

| candidate | result |
|---|---|
| only the first capture? | yes, 0 stalls in 144 captures at ordinals 2 and 3, and all 34 stalls at ordinal 1 |
| custom launch flags and environment | stock stalls the same, 12/24 against 12/24 |
| headed under Xvfb against headless | 12/24 against 10/24 |
| HAR recording, video recording, JPEG against PNG, `set viewport` | no difference |
| the always-on stream subsystem, with `stream disable` | 10/24 against 11/24 |
| `AGENT_BROWSER_HIDE_SCROLLBARS=false` | 13/24 |
| `AGENT_BROWSER_NO_WEBMCP=1` | 14/24 |
| a warm-up capture on `about:blank` at launch | no help, the warm-up stalls instead, 12/24 at about 10.2 s |
| `snapshot` in the same position | never stalls, 0/24, and does not satisfy the deadline, since the capture after it still stalled 12/24 |
| `--disable-dev-shm-usage`, with `/dev/shm` at 64 MB | 13/36 against 12/36 |
| a second target, wikipedia.org | reproduces, 11/24 |
| CPU starvation | 4 vCPU on an idle VM, and the stalled durations span 60 ms |
| a hard-coded deadline in the binary | `strings` finds no `8000` or `9000`. The six `10000`s are a request-timeout default and WebGPU probe timeouts, and `navigator.gpu.requestAdapter()` returns `null` in 4 ms here |

`--debug` and `AGENT_BROWSER_DEBUG=1` did not localise it. The session log at
`~/.agent-browser/<session>.log` holds only browser-discovery lines and nothing
about the blocked call.

### Scripts and data

Repro scripts and the raw measurements: REPO_URL

`repro/01-first-capture.sh` is the script above. `repro/02-launch-delay-sweep.sh`
produces the delay table. `repro/04-trace-the-call.sh` produces the strace.

### Environment

- agent-browser 0.37.1 from npm, which is the latest published
- Chrome for Testing 153.0.8010.36
- Ubuntu 26.04.1, Linux 6.18.49 x86_64, 4 vCPU, 8 GB, `/dev/shm` 64 MB
- Vercel Sandbox Firecracker microVM, region `iad1`, no GPU
- WebGL renderer `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)`
- `agent-browser doctor --json` reports 10 pass, 0 warn, 0 fail, and its own
  launch test reports `Headless launch + about:blank in 0.66s`

### Possibly related

- #1437, screenshot hangs at `Page.captureScreenshot` on macOS arm64 with Chrome
  149. Same call. That one hangs indefinitely, while this one always releases at
  the 10 second mark and returns a correct image. Both mechanisms discussed in
  that thread, an idle compositor and SwiftShader raster starvation, are in the
  table above.
- #1743, headless daemon never starts a CDP screencast.
