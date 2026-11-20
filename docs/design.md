# Voice dictation design discussion

Status: product design and test seam confirmed, including configurable static-storage sizing and the Nix test split. Native bounded streaming and [graphical-session installation](installation.md) are available; see [the runtime guide](runtime.md) for implemented behavior, verification and limitations. The remainder describes the complete planned product.

## Confirmed requirements

### Workflow and service

- Target Wayland desktops exposing layer-shell and ext-data-control, not Hyprland-specific APIs. The user's current desktop is NixOS with Hyprland; that must not become a runtime compositor dependency. Detect missing required protocols and report unsupported capabilities clearly instead of adding compositor-specific fallbacks. Stock GNOME/Mutter is outside this compatibility boundary.
- Build the application in Zig and use whisper.cpp for local transcription.
- Use one resident Zig user service with a loaded model and direct audio, inference, overlay, and clipboard integration. A small `dictation toggle` client signals the service from the user's compositor/desktop keybinding.
- Open the microphone only while recording.
- A toggle before the model is ready shows a loading indication without opening the microphone. The user presses again once ready; do not queue a delayed recording.
- First toggle starts recording. Transcribe bounded chunks in the background while capture continues, preferably splitting around pauses. Partial text remains internal. Second toggle stops recording, finishes the remaining transcription, and copies the complete current transcript on success.
- A toggle during finalization (after capture has stopped, before completion) discards that session and starts a new recording. A superseded session must never subsequently publish its transcript. This overrides the earlier suggestion to ignore toggles while processing. A toggle while recording still means stop, not restart, even if background inference is active.
- There is no separate cancel command or shortcut.
- No automatic pasting, live transcript, queued history of sessions, or voice-command language.
- Preserve the existing clipboard on obvious silence, an empty result, or failure. Show a brief unsuccessful/no-speech indication and do not copy error messages. Silence filtering reduces hallucinations but does not guarantee their elimination.

### Memory and privacy

- Lightweight means keeping everything surrounding the model lean. Model memory is not the optimization target; the model may use the RAM it needs.
- No dynamic allocation for our own application storage anywhere in the production Zig runtime, not merely in transcript storage or during recording. This covers the entire daemon, toggle client, other shipped Zig commands, startup, normal operation, and error/shutdown paths. The external-resource exceptions below do not relax this rule for application logic.
- Use statically sized application storage and bounded, fixed-size stack values. No application allocators, startup heap preallocation, arenas, allocator-backed containers, or allocating convenience functions. Merely bounding allocations or allocating only at startup does not meet this contract. Static tables/rings may reuse existing slots without allocating storage.
- Make whole-program static-storage sizing configurable through package build configuration and the NixOS module. Configuration feeds a Zig comptime layout calculation covering every application-owned storage requirement, not just the transcript buffer and not an independently guessed arena size. Account for audio windows/backlog, chunk and inference slots, queues, current and offered clipboard text, monitor/device records, control clients/messages, parsing/formatting/logging scratch, and other owned workspaces, including alignment, padding, concurrency, and multiple buffer instances.
- Derive the application storage layout and total from those requirements at comptime. Every owned workspace must appear in the accounting; document bounded stack requirements separately rather than claiming a data-layout sum proves total process memory. Statically declared fields or a compile-time-partitioned static backing region are both compatible; a runtime allocator over a fixed arena is not.
- Expose the sizing inputs, document units/defaults/relationships, and make the derived footprint inspectable. Changing settings rebuilds the program; it never triggers runtime application allocation. Reject invalid sizes, incompatible capacities, and arithmetic overflow before runtime. External-library allocations and approved Wayland backing remain explicitly separate from the application-storage total.
- Apply the rule to audio capture, chunk assembly, inference scheduling, transcript/clipboard handling, rendering state, monitor/device bookkeeping, IPC, configuration/argument parsing, formatting, and logging. Audit reachable Zig standard-library code for hidden allocations as well as our own code.
- Allocations internal to actual external dependencies, including whisper.cpp, GPU drivers, PipeWire, and libwayland, remain exempt; do not attempt to control those libraries. Calling C malloc or a custom C shim to obtain application-owned storage is not an exemption. This is not a requirement to bound total process RAM or VRAM.
- Wayland shared-memory backing is an allowed external-integration resource, even when Zig code issues the OS calls that create it. Prefer fixed-size, reused pools, but do not force a startup-only, never-remapped design if normal resource creation/recreation is substantially simpler. Keep this exception confined to the integration, document its storage/lifetime, validate sizes, and release resources when safe; do not repurpose it as an application heap or growing transcript store. Zig-side rendering state, monitor records, buffer bookkeeping, and queues still use static storage.
- No recording-duration cap or automatic timed cutoff. Use bounded audio windows and a fixed audio backlog rather than retaining the entire recording.
- Default to a 1 MiB capacity for a session's accumulated transcript; this is configurable at build time, not a hard-coded product limit. The active clipboard text also needs fixed-capacity storage consistent with the configured transcript capacity; do not let later recording or inference corrupt it while it is being served.
- If transcript capacity is exhausted or the fixed audio backlog fills because inference cannot keep up, fail the session visibly and preserve the previous clipboard. Do not silently truncate text or drop unprocessed speech. The user explicitly accepted these resource-exhaustion failures rather than a normal recording-time limit.
- Keep audio processing local. Do not save recordings, maintain transcript history, or log transcript contents. Captured audio is transient and discarded after processing or supersession once it is no longer in use.
- An external clipboard manager may retain copied text independently of this application.

### Dictation and model

- Optimize v1 for English dictation, especially prose replies to a coding agent in an interactive discussion. Short replies are the primary quality target, not an imposed duration limit. Multilingual optimization and meeting-specific features are not required for v1.
- Produce straightforward prose with Whisper's punctuation. Do not add a rewriting model, automatic code formatting, or editing voice commands. Technical vocabulary hints are not required for v1.
- The target desktop has an NVIDIA GeForce RTX 3090 with 24,576 MiB VRAM. The user reports driver 615.78.08 and CUDA UMD version 13.4; those do not select the project's build-toolkit version.
- The user delegated choosing an initial model rather than conducting an extensive model comparison. Start with large-v3-turbo, configured to transcribe English, using the CUDA backend. Keep model selection configurable. Validate actual throughput and peak inference memory on the target machine rather than promising performance from the GPU specification alone.

### Audio and indicator

- Each session uses the current system-default microphone, keeping that device for the recording. If it disappears, fail visibly rather than silently switch microphones.
- Use a small dark bottom-center pill with light bars responding to microphone volume. It must not take keyboard focus or accept mouse input.
- Distinguish recording from processing, briefly indicate success or failure, and do not display transcript text in the overlay.
- Show the indicator on all monitors, avoiding compositor-specific focus queries. This resolves the earlier choice between the initially focused monitor and all monitors in favor of compositor independence.
- Prefer direct library/protocol integration over spawning programs. A small helper is acceptable where it substantially simplifies the implementation. Avoiding subprocesses is a preference, not an absolute requirement.
- Lock/suspend handling was delegated to whichever requires the least code. Selected v1 scope under that delegation: no bespoke lock/suspend integration. Ordinary capture/device/connection errors fail the session. Locking alone therefore does not automatically cancel recording; no guarantee of cancellation on suspend is made. Call out this behavior to the user rather than implying lock detection exists.

### Packaging

- Deliver a Nix flake with a `nixosModules.default` output.
- The user does not use Home Manager. Do not require it or build a Home Manager module as the initial integration.
- The NixOS module declares a systemd user service, not a system-level/root microphone service. Bind the service to the generic `graphical-session.target`, not `hyprland-session.target` or UWSM.
- The user launches Hyprland on tty1 from login-shell initialization with `[[ "$(tty)" == /dev/tty1 ]] && start-hyprland`. Their Lua `hyprland.start` hook already runs `systemctl --user start hyprland-session.target`.
- Use generic unit relationships: `WantedBy=graphical-session.target`, `PartOf=graphical-session.target`, and `Wants=`/`After=pipewire.service`. Require `WAYLAND_DISPLAY` to be present in the user manager environment with `ConditionEnvironment=WAYLAND_DISPLAY`. NixOS's enabled WirePlumber module already makes WirePlumber wanted by PipeWire. Service ordering is not proof that a microphone is available; check source availability when capture starts.
- The containing desktop session must manage the lifetime of `graphical-session.target` and provide the Wayland environment to the systemd user manager before starting session services. Starting a named target alone does not import the compositor's environment. The user's existing session target can perform this integration; the application must not need a Hyprland-specific startup helper.
- Default model provisioning is a hash-pinned large-v3-turbo model fetched by Nix. Expose an override for an existing local model path. The running service never downloads models.
- Enable `doCheck` and run only Zig's standard test runner in the package derivation's `checkPhase`. These are the fast checks; keep them deterministic and runnable in an ordinary build sandbox without a GPU, desktop session, audio server, or network access.
- Expose separate Nix/module and heavier integration checks as named derivations under `passthru.tests`, including NixOS VM tests. They are not part of the fast checks or normal `checkPhase`. Document their explicit invocation; attaching `passthru.tests` alone does not cause those tests to run.

## Integration research and constraints

The workspace's pinned Nixpkgs defines whisper-cpp 1.9.5, PipeWire 1.6.9, and wl-clipboard 2.3.0. These are references, not yet the chosen project pins.

- [whisper.cpp's C interface](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/include/whisper.h) accepts 16 kHz mono float PCM and exposes a reusable model context. A shared context must not be used concurrently by multiple threads.
- The interface provides abort callbacks. [The implementation](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/src/whisper.cpp) checks cancellation at computation boundaries; this does not guarantee immediate preemption of running GPU work. Restart must invalidate the old result immediately while allowing inference to unwind safely.
- The same source allocates storage during inference, including a padded sample vector and spectrogram storage. Static Zig buffers do not make whisper.cpp allocation-free or fix total process/GPU memory usage. Desktop libraries and GPU drivers also own memory outside the Zig allocator.
- Never overwrite an audio buffer still owned by inference. Use bounded storage and one inference worker; repeated restarts must not create a growing queue. The earlier two-whole-session-buffer proposal must be revised for streaming.
- [Upstream's streaming example](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/examples/stream/README.md) uses repeated inference over audio windows, not an unlimited stateful decoder. [Its implementation](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/examples/stream/stream.cpp) uses retained audio overlap to mitigate word-boundary issues. It is a reference, not a drop-in implementation of the desired static-storage contract.
- The accepted internal streaming pipeline transcribes bounded audio windows while capture continues, commits completed text internally, and discards audio after it is no longer needed. Copy only once the user stops and finalization succeeds. Chunk boundaries can affect recognition, punctuation, and duplicate/omitted words, so boundary quality must be tested.
- A finite text buffer cannot retain arbitrarily long transcripts. No duration cutoff is compatible with bounded audio storage, but not with an unlimited final transcript held exclusively in fixed memory. Do not evade the storage guarantee by moving growing application storage behind a C allocation or an unbounded memory-backed file.
- If sustained inference throughput falls behind capture, a fixed backlog eventually fills. The agreed policy is an explicit session failure, not silently dropping unprocessed audio.
- [Upstream's model list](https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/models/README.md) includes large-v3-turbo. Its listed model-file size is not its total inference RAM or VRAM requirement.
- [PipeWire's C capture example](https://docs.pipewire.org/audio-capture_8c-example.html) demonstrates audio capture without a recorder subprocess. The online example currently documents 1.6.11 rather than the pinned 1.6.9; exact integration must be checked against the chosen build headers.
- [Wayland layer-shell](https://wayland.app/protocols/wlr-layer-shell-unstable-v1) provides anchored surfaces and keyboard interaction controls suitable for the indicator. The app also needs an empty surface input region for click-through behavior.
- [Core Wayland shared-memory rendering](https://wayland.app/protocols/wayland) uses a client-supplied file descriptor and pool size; the compositor maps that backing storage. The user permits treating this necessary rendering resource as an external-integration exception, even if established through Zig OS calls. Prefer a fixed/reused pool where simple, without adding complexity solely to prohibit integration-specific resource recreation. This does not permit dynamic allocation of the surrounding Zig application state.
- [Wayland ext-data-control](https://wayland.app/protocols/ext-data-control-v1) provides native clipboard publication on supporting compositors. The owning client serves text on later paste requests, so a native implementation keeps the currently offered transcript available in memory while it owns the clipboard. This is current clipboard content, not transcript history.
- [wlr-data-control](https://wayland.app/protocols/wlr-data-control-unstable-v1) is deprecated in favor of ext-data-control. The accepted minimum compatibility is layer-shell plus ext-data-control; do not promise support for every Wayland compositor or automatically add compositor-specific fallbacks.
- The pinned `systemd.special(7)` describes `graphical-session.target` as the generic session-lifetime target and recommends `PartOf=` for graphical services. A containing session target can bind to it with `BindsTo=`. The pinned NixOS PipeWire module supplies user service/socket activation, and its WirePlumber module adds `WantedBy=pipewire.service` when enabled.

This workspace has no WAYLAND_DISPLAY connection. Its hardware and desktop capabilities must not be assumed to match the user's target machine.

## Approval gate

No product decisions remain open. Proceed through specification and ticket planning before implementation. Dependency pins, static buffer layout and sizing-option names, the simplest Wayland shared-memory resource lifecycle, chunk/overlap tuning, and other implementation choices remain engineering work within the agreed constraints. Do not weaken the no-dynamic-allocation rule for application storage when exercising the integration exception.

## Implementation verification

### Test seam and execution

- Use one primary automated test seam at the dictation module's public interface, used by the daemon. Exercise toggles and controlled audio/inference events; observe microphone activity, indicator output, and clipboard publication rather than private state or helper-call sequences.
- Use deterministic adapters for external audio, inference, Wayland effects, and time where necessary. The test seam must not require an allocating framework in production.
- Fast checks are precisely Zig's standard test runner, and nothing else. The package's `checkPhase` runs only that Zig test suite; no additional shell/Python check suite, alternate runner, Nix evaluation, source/allocation audit, or native integration check belongs there. Honor standard pre/post build hooks without using them to add other checks. Test failures fail native package builds; cross-compilation must not be reported as having executed tests that the build platform could not run.
- Keep allocation/source audits as separate verification evidence, not fast checks. Expose separately runnable, named `passthru.tests` derivations for Nix/module validation and involved integration checks, especially NixOS VMs. Verify the installed package/module and real session/audio/Wayland integration where practical; make any substituted inference backend explicit.
- Keep target-GPU validation distinct from VM success. A normal VM test does not establish CUDA operation, throughput, or transcript quality on the user's RTX 3090. Record those results from the actual desktop.
- There is no existing application code or test suite to reuse; this is the initial test structure, not a description of already implemented checks.

### Required coverage

- Verify the absence of dynamic allocation for application storage throughout the shipped Zig runtime, including initialization, the toggle client, and failure paths. Stable RSS or a bounded heap is not sufficient evidence. Audit allocator APIs and hidden allocations in Zig standard-library calls, including threading, parsing, formatting, and logging; keep permitted external-resource operations explicitly distinguished.
- Verify the comptime layout covers every application-owned storage requirement, not just selected buffers. Check alignment/padding and concurrent-buffer multiplicities, and document bounded stack requirements separately. Test default and non-default sizing configurations, the derived footprint, rejection of invalid or overflowing settings, exact capacity boundaries, and slot reuse under recording, inference backlog, restart, clipboard-request, and monitor-event stress. Document and test the approved Wayland shared-memory resource lifecycle separately, including safe release and absence of accumulated stale mappings. Do not impose the allocation contract on external dependency internals.
- Test toggle transitions, loading behavior, repeated restarts, stale result rejection, and buffer ownership while cooperative cancellation unwinds.
- Test recording beyond the rejected two-minute limit, chunk-boundary text quality, silence, transcript exhaustion, and audio-backlog exhaustion. Failures must not publish partial output or overwrite the clipboard.
- Test default-device selection, device removal, missing protocol/audio/model dependencies, compositor disconnect, and user-service session lifetime.
- Verify that clipboard serving remains responsive during capture and inference, including while a replacement transcript is being prepared.
- Validate NixOS module evaluation and generic session dependencies; no Home Manager, UWSM, or Hyprland package requirement.
- On the actual desktop, validate CUDA model loading, sustained faster-than-capture processing under ordinary load, finalization latency, and a noninteractive indicator. This workspace has no target GPU or compositor connection, so local checks cannot establish those results.

The user delegated simple implementation choices where noted. Do not reopen those as product questions unless investigation reveals a material trade-off.
