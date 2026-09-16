### Summary

A user-supplied `--use-angle=<backend>` cancels the `--webgpu` preset's own
`--use-angle=vulkan`, without reporting anything. User args are appended after
the preset's, and Chrome honours the last `--use-angle` on the command line.

The preset still looks active. `--enable-unsafe-webgpu`, `--use-vulkan=swiftshader`,
`--use-webgpu-adapter=swiftshader`, `--disable-vulkan-surface` and
`--enable-features=Vulkan` all remain on the command line. Only the ANGLE
backend the preset chose is gone.

`--enable-features` is already protected against this, a few lines above, with a
comment saying why. `--use-angle` is not.

### Where

`cli/src/native/cdp/chrome.rs` at `8f58d0a`:

- L441-443 adds the `Vulkan` feature for the preset.
- L445-449 explains that user `--enable-features` values must be merged, because
  "appending them as a second switch would silently clobber the preset's
  features (e.g. drop the WebGPU preset's Vulkan)".
- L480-495 pushes `--use-angle=vulkan` and the other Vulkan switches.
- L571 runs `args.extend(user_args)`, so anything the user passed lands last.

### Reproduce

```bash
# Preset alone. Chrome runs on ANGLE/Vulkan.
AGENT_BROWSER_WEBGPU=1 agent-browser --session a open https://example.com/

# Preset plus an unrelated-looking flag. The preset's backend is gone.
AGENT_BROWSER_WEBGPU=1 \
AGENT_BROWSER_ARGS='--disable-quic,--use-angle=swiftshader,--enable-unsafe-swiftshader' \
  agent-browser --session b open https://example.com/
```

Read the flags back off the running process. Both command lines still carry
`--enable-unsafe-webgpu` and `--disable-vulkan-surface`. Only the last
`--use-angle` differs:

```bash
pid=$(pgrep -f 'chrome.*--user-data-dir' | head -1)
tr '\0' '\n' < /proc/$pid/cmdline | grep -- --use-angle
```

### Why this matters in practice

On a Linux container with no GPU, the first `screenshot` of a session blocks
about 9.5 seconds. I filed that separately. Turning on the WebGPU preset is what
reduces it, but only when no `--use-angle` of ours is also present.

Measured on one image, arms interleaved per VM, each sample checked against the
live Chrome `/proc/<pid>/cmdline`:

| configuration | first-capture stalls |
|---|---|
| our flags, no preset | 10/36 |
| our flags without `--use-angle=swiftshader`, preset on | 6/36 |
| our flags with `--use-angle=swiftshader`, preset on | 12/24 |

The third row is the bug. The preset is requested, configured, and does nothing.
Pooled over 384 captures sorted by what was on the live command line, the preset
was effective in 39/168 stalls (23%) and cancelled or absent in 78/216 (36%),
z = 2.72, p = 0.0065.

Finding this took a `/proc/<pid>/cmdline` diff across arms. The CLI output,
`doctor`, and the session JSON all report the same thing either way.

### Suggested fix

Any of these would have saved the time:

1. Treat `--use-angle` the way `--enable-features` is treated. Keep the user's
   value, and warn that the preset's backend was replaced.
2. Reject the combination, as `--webgpu` already rejects `--cdp`, `-p/--provider`
   and `--auto-connect` in `cli/src/main.rs` L191-205. Those produce a clear
   error. This one is silent.
3. Append the preset's switches after user args so the preset wins, and document
   that `--webgpu` pins the ANGLE backend.

Option 1 matches the existing intent, since the `--enable-features` comment
already says a user value must not drop a preset feature.

### Scripts and data

Repro scripts and the raw measurements: https://github.com/msywulak/agent-browser-first-capture-stall

`repro/03-webgpu-preset-ab.sh` is the A/B above, including the arm where the
preset is cancelled. Its `data/webgpu-preset-ab.jsonl` has one line per capture
with the flags read off the live process.

### Environment

agent-browser 0.37.1 from npm, which is the latest published, and `main` at
`8f58d0a`. Chrome for Testing 153.0.8010.36. Ubuntu 26.04.1, Linux 6.18.49
x86_64. Vercel Sandbox Firecracker microVM, 4 vCPU, no GPU.
