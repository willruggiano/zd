# Explicit fixture mode

The first milestone's simulated path is retained for debugging. Real streaming
capture and inference are available; see [the runtime guide](runtime.md) for
current architecture, configuration, storage accounting, checks and limitations.

```sh
nix build .#cpu
./result/bin/dictation daemon --fixture
# From another terminal with the same uid:
./result/bin/dictation toggle
./result/bin/dictation toggle
wl-paste --no-newline
```

`--fixture` explicitly replaces microphone capture and inference with synthetic
input and the text **`Fixture dictation result.`**, completed 350 ms after stop.
It does not open a microphone or load a model. Wayland rendering, control IPC,
clipboard ownership and clipboard transfers are real. There is no silent fallback
to this mode on native/model failure. The CPU package avoids requiring an NVIDIA
driver to exercise it.

A supporting compositor must expose layer-shell and ext-data-control-v1. The
current indicator is a click-through, keyboard-noninteractive bottom-center pill
on one compositor-selected output. Static bars distinguish recording/finalization
and brief result feedback; no transcript is drawn or automatically pasted.

The daemon uses the same `dictation-<uid>` control socket as normal mode, so stop
one daemon before starting another. SIGINT/SIGTERM shuts it down. A successful
toggle reply acknowledges the command, not successful copying. Current
finalization refuses additional capture until completion; safe restart is a later
milestone, not a promise made by this fixture timer.

Run its installed-consumer check separately:

```sh
nix build .#cpu.passthru.tests.native-smoke --no-link -L
```

This starts private headless Sway, drives the installed client, retrieves the
clipboard with wl-paste, and exercises preservation, source reuse, malformed
requests, control exhaustion/timeout recovery and shutdown. It never belongs in
`checkPhase` and does not establish audio, recognition, GPU, physical appearance,
keyboard-focus or click-through acceptance. The original tracer was verified on
aarch64-linux with Zig 0.17.1; current verification is recorded in the runtime guide.
