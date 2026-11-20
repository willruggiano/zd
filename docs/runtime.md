# Runtime guide

Run the foreground daemon and understand the contracts between its parts.
Use [NixOS installation](installation.md) for an installed user service.

- [Run](#run)
- [Failure and recovery](#failure-and-recovery)
- [Privacy and shutdown](#privacy-and-shutdown)
- [Model provisioning](#dependencies-and-provisioning)
- [Ownership across modules](#public-interface-and-ownership)
- [Storage accounting](#static-storage-and-allocation-audit)

For development commands and verification, start at
[CONTRIBUTING](../CONTRIBUTING.md). Code owns API details, constants and local
algorithms. This guide links to those sources rather than repeating them.

## Run

First check the [desktop prerequisites](installation.md#desktop-and-driver-prerequisites).

```sh
nix build                         # CUDA + large-v3-turbo
./result/bin/dictation daemon
```

Wait for the model-ready diagnostic. Then use another terminal or shortcut:

```sh
./result/bin/dictation toggle     # start recording
# Speak.
./result/bin/dictation toggle     # stop recording and finalize
# After success, paste manually. To read the clipboard from a terminal:
wl-paste --no-newline
```

Normal workflow after model readiness:

```text
ready --toggle--> recording --toggle--> finalization --success/copy--> ready
                    ^                       |
                    +----toggle/restart-----+
```

Restart discards the old session, not the previous clipboard. Capture starts
while old inference finishes cancelling. A toggle during recording always means
stop, even when background inference is active. A successful toggle reply means
that the command was accepted, not that text was copied.

A toggle during loading shows loading but does not open the microphone or queue
a recording. Toggle again after readiness. A systemd `active` state alone does
not prove model readiness or CUDA execution.

The indicator appears at the bottom center of each available monitor. Bars
respond to microphone volume. It shows loading, recording, finalization and
brief result feedback without taking focus or accepting pointer input. It never
shows transcript text or pastes into another application.

Use `nix build .#cpu` to select CPU inference and tiny.en explicitly. This is real
recognition, not a silent substitute for the default model. Use
[fixture mode](tracer.md) to simulate audio and inference instead.

### Limits

- There is no recording timer. The transcript must fit, and inference must keep
  pace with capture. Capacity failure stops the session; it does not silently
  drop audio or truncate text.
- Window boundaries can affect words and punctuation. Text context helps, but
  there is no full-session second pass after old audio is released.
- Cancellation is cooperative. It does not preempt GPU work. A replacement
  recording can exhaust its backlog while old inference still holds an audio
  window.
- The daemon is shared by one UID in a network namespace. Simultaneous graphical
  sessions for that UID are not isolated.

Throughput, recognition quality and physical-desktop behavior require
[target validation](validation.md). A successful build or headless test is not
that evidence.

## Failure and recovery

| Failure | Next action | Clipboard effect |
| --- | --- | --- |
| Silence or empty recognition | Toggle for a new session. | No replacement. |
| Missing/removed microphone, capture/inference/publication error, audio/text capacity | Fix the cause if needed, then toggle. | No partial/error transcript. |
| Model initialization | Fix the model/backend, then restart the daemon. | No model or fixture substitution. |
| PipeWire/Wayland connection loss, device/output table exhaustion | Restore the dependency or increase capacity; restart. | The daemon releases its selection and transfers. |

A new session selects the current default microphone. A running session stays
on its selected source; a default change does not retarget it. Missing protocols
are errors, not a request to use a compositor-specific fallback.

A recoverable failure permits new capture while cancelled inference still
unwinds. Late results from that old session cannot publish or alter the new
session. A daemon restart instead reloads the model and stays idle; it does not
resume recording. See [service recovery](installation.md#the-desktop-owns-the-session)
for systemd retries and start limits.

Clipboard preservation requires a surviving owner and connection. After daemon
or compositor loss, its old transcript may no longer be pasteable without an
external clipboard manager. This is not publication of partial/error text.
If Wayland is unavailable, diagnostics and exit status provide feedback; an
on-screen error cannot be assumed.

## Privacy and shutdown

Audio stays transient. The application creates no recording files, transcript
history or logs of dictated contents. Clearing application storage is a
retention policy, not a promise to erase every copy inside dependencies.
External clipboard managers can keep copied text independently.

Orderly shutdown follows this ownership order:

```text
close capture
  -> request decoder abort
  -> join worker
  -> clear session
  -> release native resources
```

Model initialization cannot be cancelled. The installed service's forced-stop
timeout is separate; see [shutdown](installation.md#shutdown).

**Locking alone does not cancel recording. Cancellation on suspend is not
promised.** Stop recording before locking or suspending if that is your intent.
There are no bespoke lock/suspend hooks.

## Dependencies and provisioning

The default package requests CUDA with large-v3-turbo. GPU initialization may
fall back to CPU with a sanitized warning. Readiness is not proof of CUDA work.
A missing or incompatible model still fails; the daemon does not switch models
or enter fixture mode automatically.

Nix supplies the model before runtime. The daemon never downloads it. To use an
existing local model with a package override:

```nix
inputs.zd.packages.${system}.default.override {
  modelPath = "/var/lib/dictation/model.bin";
}
```

An absolute string remains a host path. A Nix path or model derivation is copied
into the store. For service configuration, use the
[installation example](installation.md#model-and-whole-program-storage-configuration).

Use the source for current pins and build choices:

- [flake.nix](../flake.nix) and [flake.lock](../flake.lock): compiler and package inputs.
- [nix/whisper.nix](../nix/whisper.nix): nixpkgs Whisper backend/toolkit selection.
- [nix/models.nix](../nix/models.nix): model revisions and hashes.

## Public interface and ownership

The daemon coordinates the parts; the session owns publication eligibility.
The main relationships are:

```text
toggle client --command--> daemon loop --event--> session
PipeWire --------PCM-----> daemon loop --audio--> session
session --decode--> worker --result--> daemon loop
session --phase/level--> feedback --draw--> Wayland
session --publish--> clipboard --serve--> Wayland readers
```

Read [main.zig](../src/main.zig) for coordination and
[dictation.zig](../src/dictation.zig) for the session interface. The same session
interface drives [behavioral tests](../src/tests.zig); tests do not implement a
second state machine.

### Window boundaries and transcript assembly

Capture continues while the worker decodes bounded windows. Completed text stays
internal until stop and successful finalization. Audio can be reused only after
inference releases it. This is why the backlog can fail even with unused
transcript capacity: the two resources have separate owners and limits.

The session owns window boundaries and transcript assembly. The worker owns
native decoder state. Their algorithms and API contracts live in
[dictation.zig](../src/dictation.zig) and [inference.zig](../src/inference.zig).
Real boundary quality is part of target acceptance, not just deterministic tests.

### Restart and operation ownership

Restart makes old results ineligible immediately, but cancellation does not
release borrowed audio. New capture uses the other slots. The old result must
return before that window can be reused. Repeated restarts replace work; they do
not add queued user sessions.

The result handoff across the worker, daemon and session has this order:

```text
worker returns
  -> session consumes or rejects result
  -> daemon releases worker result
  -> session can schedule next decode
```

Publication eligibility comes from session identity, not from the decoder's
success/cancellation return code. This protects the clipboard if cancellation
finishes late. Capture teardown also waits until the current native callback
returns its buffer. See [audio.zig](../src/audio.zig),
[inference.zig](../src/inference.zig) and the daemon loop for those local contracts.

### Reactive multi-monitor feedback

The session supplies phase and volume. [feedback.zig](../src/feedback.zig) keeps
the latest requested display state. [wayland.zig](../src/wayland.zig) owns native
surfaces and buffers. A busy compositor must not block capture or create an
unbounded queue of old frames. Output changes redraw the current state, not a
history of events.

The [Wayland storage exception](adr/0002-fixed-application-storage.md) permits
pixel backing, not dynamic application bookkeeping. Buffer release, output
removal and compositor ownership span both sides of the protocol. Their local
lifetime rules are documented next to the backing and surface code.

### Clipboard ownership and concurrent readers

Finalization and clipboard serving have separate lifetimes. New recording must
not modify text still needed by an old paste request. Replacing a selection also
does not cancel transfers already requested from it.

[clipboard.zig](../src/clipboard.zig) owns bounded offers and readers;
[wayland.zig](../src/wayland.zig) supplies native protocol and nonblocking I/O.
A failed reader can receive a prefix before EOF. That is a failed transfer, not a
truncated successful publication. The complete offer remains available for retry.

There is no Wayland paste acknowledgement. Success means publication was queued
without a known error, not that another application received or pasted the text.

## Static storage and allocation audit

The [storage ADR](adr/0002-fixed-application-storage.md) defines the contract.
Configuration reaches the executable through this path:

```text
NixOS module / package arguments
  --generate--> options.zig --validate at comptime--> typed Storage
                                                     --measure--> footprint
```

Use [nix/storage.nix](../nix/storage.nix) for option descriptions, defaults and
ranges; [config.zig](../src/config.zig) checks layout constraints.
[main.zig](../src/main.zig) owns the aggregate and footprint output. Refer to
those sources instead of maintaining a second option or field table here.

```sh
./result/bin/dictation footprint
```

The aggregate includes alignment, padding and the supplied worker stack.
Component totals overlap: do not add them to the whole-program total. Main-thread
application stack is budgeted separately in the source. Native library/driver
allocations and Wayland pixel backing are outside that static total. It is not a
total process RAM/VRAM limit.

An allocation audit must follow calls across modules, startup and teardown. A
constant RSS or a process-wide allocation trap cannot prove the contract: genuine
native-library allocations are permitted. Use the
[verification policy](../CONTRIBUTING.md#verification) and
[recorded audit evidence](verification.md), not a copied field list, as the review
starting point.
