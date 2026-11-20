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
a labeled fixed transcript after a short delay.
[main.zig](../src/main.zig) defines the fixture.
It does not open a microphone or load a model. Wayland rendering, control IPC,
clipboard ownership and clipboard transfers are real. There is no silent fallback
to this mode after a native or model failure. With the CPU package,
this mode does not require an NVIDIA driver.

The [desktop protocol requirements](installation.md#desktop-and-driver-prerequisites)
still apply. One synthetic PCM event briefly moves the recording bars.
The meter then returns to its rest position.
This is not a live microphone-volume demo.
The [runtime guide](runtime.md#run) describes indicator behavior.

The daemon uses the same `dictation-<uid>` control socket as normal mode.
Before you start another daemon, stop the current daemon.
SIGINT or SIGTERM shuts down the daemon. A successful
toggle reply confirms command acceptance, not successful publication.

A toggle during finalization starts replacement capture through the same public state machine.
The old completion stays pending to simulate delayed cancellation. It cannot
publish. This delay is not GPU latency evidence.

For the installed-consumer check and its limits, see `native-smoke` in the
[test catalog](testing.md#native-consumers). Past results live in
[local verification evidence](verification.md).
