# Explicit fixture mode

Use this mode to try the workflow without a microphone or model.
[Normal operation](runtime.md#run) uses real capture and inference.

```sh
nix build .#cpu
./result/bin/dictation daemon --fixture
# From another terminal with the same uid:
./result/bin/dictation toggle
./result/bin/dictation toggle
wl-paste --no-newline
```

`--fixture` replaces microphone capture and inference with synthetic input and
a labelled fixed transcript after a short delay. The fixture is defined in
[main.zig](../src/main.zig).
It does not open a microphone or load a model. Wayland rendering, control IPC,
clipboard ownership and clipboard transfers are real. There is no silent fallback
to this mode on native/model failure. The CPU package avoids requiring an NVIDIA
driver to exercise it.

The [desktop protocol requirements](installation.md#desktop-and-driver-prerequisites)
still apply. One synthetic PCM event briefly moves the recording bars, then the
meter settles. This is not a live microphone-volume demo. Indicator behavior is
described in the [runtime guide](runtime.md#run).

The daemon uses the same `dictation-<uid>` control socket as normal mode, so stop
one daemon before starting another. SIGINT/SIGTERM shuts it down. A successful
toggle reply acknowledges the command, not successful copying. A toggle during
finalization starts replacement capture through the same public state machine.
The old completion stays pending to simulate delayed cancellation, but cannot
publish. This delay is not GPU latency evidence.

For the installed-consumer check and its limits, see `native-smoke` in the
[test catalog](testing.md#native-consumers). Past results live in
[local verification evidence](verification.md).
