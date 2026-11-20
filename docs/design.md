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
- The first toggle starts recording. The second toggle stops capture and starts finalization.
  Publish one complete transcript after success. Keep partial text internal.
- A toggle during finalization discards that session and starts new capture.
  Late old results must never replace the clipboard. During recording, a toggle
  still means stop, even when background inference is active.
- A toggle during model loading shows loading. It does not record or queue a
  later recording. The user must toggle again after readiness.
- Keep the clipboard unchanged on silence, empty recognition or failure. Do not publish
  error messages. Keep the previous transcript usable during new work.
- Use the recognizer's punctuation. Do not add automatic pasting, live transcript
  display, rewriting or voice commands. Do not add automatic code formatting, a
  separate cancel shortcut or a queue of user sessions.
  Multilingual optimization, vocabulary management and meeting features are outside v1.

## Memory and privacy

Obey the [static-storage decision](adr/0002-fixed-application-storage.md) for
all shipped runtime paths. It defines comptime sizing, stack accounting,
configuration checks and the narrow native-resource exceptions. This is not a
limit on total native-library or GPU memory.

Obey the [streaming decision](adr/0003-stream-audio-with-bounded-transcript-storage.md).
Recycle audio windows. Prefer pauses as boundaries.
If the backlog or transcript capacity is exhausted, fail explicitly.

Do not add a duration cutoff. Do not silently discard speech or truncate
successful output. Do not write audio or text to disk. Keep
borrowed audio valid until inference releases it.

Process audio locally. Do not save recordings, transcript history or dictated
contents in logs. Keep data only while active work or clipboard serving needs
it. External clipboard managers can keep copied text independently.

## Model and target

Use CUDA with large-v3-turbo by default, with a model-path override. The target
GPU is an RTX 3090 with 24 GiB VRAM. Measure actual throughput, latency and memory
use. Do not infer these values from the GPU model.
The requirements do not include a separate model-comparison project.

Allow upstream CPU fallback when GPU initialization fails. Emit a sanitized
warning. A GPU request or ready state must not claim actual CUDA execution.
Missing or incompatible models still cause failure. Do not silently switch models or use fixture output. Use nixpkgs' `whisper-cpp`, not a parallel build recipe.

## Audio, indicator and compatibility

- Select the current default microphone at recording start. Keep it for that
  recording. If it disappears, fail rather than switch sources.
- Show a small dark bottom-center pill on every monitor. Light bars respond to
  microphone volume. Distinguish recording, finalization, loading and brief
  result feedback. Do not show transcript text, take focus or accept pointer input.
- Obey the [protocol compatibility decision](adr/0004-require-wayland-protocols-not-a-specific-compositor.md).
  Report missing capabilities. Do not add compositor-specific fallbacks.
- Obey the [native service decision](adr/0001-native-resident-service.md).
  A small helper is acceptable when it makes a specific integration much simpler.
- v1 has no special lock or suspend integration. A screen lock alone does not
  cancel recording. Suspend does not guarantee cancellation. Explain these limits.

## Packaging

Provide a reproducible Nix package and `nixosModules.default`. The module must
use a graphical-session user service, not a root daemon. Do not require Home
Manager, UWSM or a compositor-specific startup helper. The desktop owns session
lifetime and imports its Wayland environment. See [installation](installation.md).

Nix provisions the default model with pinned hashes. Also accept an existing
local model path. The running daemon must not download models. Expose storage
sizing through both package and module configuration.

## Integration references

Before an integration change, compare these references with the chosen dependency sources. They explain external constraints, not our current API:

- [Whisper interface](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/include/whisper.h),
  [implementation](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/src/whisper.cpp),
  [streaming example](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/examples/stream/README.md),
  [example implementation](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/examples/stream/stream.cpp)
  and [models](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/models/README.md).
  Windowing is not an unlimited stateful decoder. Cooperative abort is not GPU
  preemption. Model-file size is not peak RAM or VRAM use.
- [PipeWire capture example](https://docs.pipewire.org/audio-capture_8c-example.html).
  Online documentation can describe a different release. Use the pinned headers.
- [Core Wayland](https://wayland.app/protocols/wayland),
  [layer-shell](https://wayland.app/protocols/wlr-layer-shell-unstable-v1) and
  [ext-data-control](https://wayland.app/protocols/ext-data-control-v1).
  [wlr-data-control](https://wayland.app/protocols/wlr-data-control-unstable-v1) is
  deprecated. The application does not use it as a fallback.
- Pinned `systemd.special(7)` and the NixOS PipeWire and WirePlumber modules for
  session lifetime and service activation.

## Implementation verification

The policy and required coverage live in
[CONTRIBUTING](../CONTRIBUTING.md#verification). Use the
[test catalog](testing.md) for commands.
Use [target validation](validation.md) for hardware acceptance.
