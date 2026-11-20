# Product design

This document defines product behavior and scope. The [ADRs](adr/) record
architecture decisions. The [runtime guide](runtime.md) explains operation and
contracts between modules. Code owns API and algorithm details.

## Workflow and service

- Use local English dictation to produce prose for other applications, especially
  replies to coding agents. Short replies are the main quality target, not a
  recording-duration limit.
- Use a resident Zig service with whisper.cpp. Keep the model loaded between
  sessions. Open the microphone only during recording.
- First toggle starts recording. Second toggle stops capture and finalizes.
  Publish one complete transcript after success. Keep partial text internal.
- A toggle during finalization discards that session and starts new capture.
  Late old results must never replace the clipboard. During recording, a toggle
  still means stop, even when background inference is active.
- A toggle during model loading shows loading but does not record or queue a
  later recording. The user must toggle again after readiness.
- Preserve the clipboard on silence, empty recognition or failure. Do not publish
  error messages. Keep the previous transcript usable during new work.
- Use the recognizer's punctuation. Do not add automatic pasting, live transcript
  display, rewriting, voice commands, automatic code formatting, a separate
  cancel shortcut or a queue of user sessions. Multilingual optimization,
  vocabulary management and meeting features are outside v1.

## Memory and privacy

Follow the [static-storage decision](adr/0002-fixed-application-storage.md) for
all shipped runtime paths. It defines comptime sizing, stack accounting,
configuration checks and the narrow native-resource exceptions. This is not a
limit on total native-library/GPU memory.

Follow the [streaming decision](adr/0003-stream-audio-with-bounded-transcript-storage.md):
recycle audio windows, prefer pauses as boundaries, and fail explicitly if the
backlog or transcript capacity is exhausted. Do not add a duration cutoff,
silently drop speech, truncate successful output or spill data to disk. Keep
borrowed audio valid until inference releases it.

Process audio locally. Do not save recordings, transcript history or dictated
contents in logs. Retain data only while active work or clipboard serving needs
it. External clipboard managers can retain copied text independently.

## Model and target

Use CUDA with large-v3-turbo by default, with a model-path override. The target
GPU is an RTX 3090 with 24 GiB VRAM. Measure actual throughput, latency and memory
use; do not infer them from the GPU model. No separate model-comparison project
is required.

Allow upstream CPU fallback when GPU initialization fails. Emit a sanitized
warning. A GPU request or ready state must not claim actual CUDA execution.
Missing or incompatible models still fail. Never switch models or use fixture
output silently. Use nixpkgs' `whisper-cpp`, not a parallel build recipe.

## Audio, indicator and compatibility

- Select the current default microphone at recording start. Keep it for that
  recording. If it disappears, fail rather than switch sources.
- Show a small dark bottom-center pill on every monitor. Light bars respond to
  microphone volume. Distinguish recording, finalization, loading and brief
  result feedback. Do not show transcript text, take focus or accept pointer input.
- Follow the [protocol compatibility decision](adr/0004-require-wayland-protocols-not-a-specific-compositor.md).
  Report missing capabilities. Do not add compositor-specific fallbacks.
- Follow the [native service decision](adr/0001-native-resident-service.md).
  A small helper is acceptable when it makes a specific integration much simpler.
- v1 has no bespoke lock/suspend integration. Locking alone does not cancel
  recording; suspend cancellation is not guaranteed. Make these limits clear.

## Packaging

Provide a reproducible Nix package and `nixosModules.default`. The module must
use a graphical-session user service, not a root daemon. Do not require Home
Manager, UWSM or a compositor-specific startup helper. The desktop owns session
lifetime and imports its Wayland environment; see [installation](installation.md).

Nix provisions the default model with pinned hashes. Also accept an existing
local model path. The running daemon must not download models. Expose storage
sizing through both package and module configuration.

## Integration references

Check these references against the chosen dependency sources before changing an
integration. They explain external constraints, not our current API:

- [Whisper interface](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/include/whisper.h),
  [implementation](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/src/whisper.cpp),
  [streaming example](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/examples/stream/README.md),
  [example implementation](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/examples/stream/stream.cpp)
  and [models](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/models/README.md).
  Windowing is not an unlimited stateful decoder. Cooperative abort is not GPU
  preemption. Model-file size is not peak RAM/VRAM use.
- [PipeWire capture example](https://docs.pipewire.org/audio-capture_8c-example.html).
  Online docs can describe a different release; use the pinned headers.
- [Core Wayland](https://wayland.app/protocols/wayland),
  [layer-shell](https://wayland.app/protocols/wlr-layer-shell-unstable-v1) and
  [ext-data-control](https://wayland.app/protocols/ext-data-control-v1).
  [wlr-data-control](https://wayland.app/protocols/wlr-data-control-unstable-v1) is
  deprecated; it is not a fallback promise.
- Pinned `systemd.special(7)` and the NixOS PipeWire/WirePlumber modules for
  session lifetime and service activation.

## Implementation verification

The policy and required coverage live in
[CONTRIBUTING](../CONTRIBUTING.md#verification). Use the
[test catalog](testing.md) for commands and [target validation](validation.md)
for hardware acceptance.
