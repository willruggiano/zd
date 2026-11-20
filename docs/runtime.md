# Short-reply dictation

The second milestone adds **real native PipeWire capture and resident whisper.cpp
inference** to the Wayland tracer. This is still an incremental implementation:
streaming, restart while inference unwinds and reactive multi-monitor feedback
remain later milestones. [NixOS graphical-session installation](installation.md)
is provided by milestone 03. Hardware validation is
not implied by the CPU integration tests.

## Run

On a supporting Wayland desktop with PipeWire, WirePlumber and an NVIDIA driver:

```sh
nix build                         # CUDA + hash-pinned large-v3-turbo
./result/bin/dictation daemon     # load once, then remain resident
# Wait for "model ready (CUDA required)". From another terminal/shortcut:
./result/bin/dictation toggle     # open the current default microphone
# Speak a short English reply.
./result/bin/dictation toggle     # close microphone, finalize, copy
# Paste manually into another application; optional independent reader:
wl-paste --no-newline
```

The default CUDA build accepts NVIDIA's unfree toolkit dependencies through the
flake's Nixpkgs configuration. It requires the host NVIDIA driver libraries
(`/run/opengl-driver/lib` on NixOS). The application itself is MIT licensed.
`nix build .#cpu` explicitly selects **CPU + tiny.en**, for integration testing or
experimentation, not a silent substitute for the default GPU/model. It performs
real capture and recognition and identifies itself as a CPU build in diagnostics.
For simulated audio/inference instead, use [the fixture mode](tracer.md).

The daemon needs `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, a usable default source in
PipeWire's `default` metadata, and a compositor providing **layer-shell** and
**ext-data-control-v1**. There is no compositor-specific API or clipboard fallback.
Missing protocols produce `MissingLayerShell` / `MissingDataControl`; absent
Wayland produces `WaylandConnection`. A missing microphone fails visibly rather
than selecting an arbitrary source. Audio-server loss requires a daemon restart.

The native pill remains on one compositor-selected output. It is click-through,
keyboard-noninteractive and bottom-center. Static bars distinguish loading
(purple), recording (white), finalization (blue), success (green), no speech
(amber) and failure (red). Result feedback lasts 900 ms. No transcript is shown,
and publication never automatically pastes.

A toggle during loading only shows loading: no microphone, no deferred recording.
The user toggles again after readiness. Model/backend load failure stays failed
until daemon restart. Model loading and inference run off the Wayland/control
thread, so clipboard serving and toggles remain responsive.

### Deliberate current limitations

- This slice buffers a short reply until stop. It has **no recording timer**;
  filling the configured audio storage fails explicitly with `AudioCapacity`,
  closes capture and preserves the clipboard. With defaults this storage holds
  480,000 mono samples (30 seconds at 16 kHz). This is not the final no-duration-
  cutoff product: milestone 04 must recycle audio during recording instead of
  treating a larger whole-session buffer as the streaming solution.
- A toggle during finalization currently refuses replacement recording. It does
  not queue another session or reuse borrowed samples. Safe asynchronous restart
  belongs to milestone 05. This applies to fixture mode too.
- No multi-monitor/reactive bars yet (08).
  No lock/suspend integration: locking does not cancel recording. Shutdown closes
  capture first and requests decoder abort, but waits for outstanding native work
  before releasing buffers; model initialization itself is not cancellable.
- This is not recognition-quality, sustained-streaming or RTX 3090 acceptance.
  Those measurements require the target desktop in milestone 09.

## Dependencies and provisioning

`flake.lock` retains **Zig 0.17.1**, explicitly selected from Mitchell Hashimoto's
overlay, and Nixpkgs `d3b13ad75cc492690728f9307e443dec9ef9a20e`.
Pinned APIs used here are PipeWire **1.6.9**, whisper.cpp **1.9.5** (bundled ggml),
Wayland **1.26.0**, wayland-protocols **1.49**, and wlr-protocols **2022-09-05**.
The CUDA build deliberately selects `cudaPackages_12_9` (nvcc **12.9.86**) and
compute capability **86**, suitable for the RTX 3090. This is a build-toolkit
choice, not the user's reported driver/UMD version.

`nix/whisper.nix` builds the native shared libraries without example applications,
SDL or FFmpeg. GPU architecture detection at build time is disabled. A small
fail-closed patch makes `use_gpu=true` return initialization failure if the GPU
backend cannot initialize: upstream otherwise permits CPU fallback. It uses the
existing empty-backend failure path and does not alter library allocation.
An explicit CPU build passes `use_gpu=false`; it is never selected automatically.

`nix/models.nix` fetches immutable Hugging Face revision
`5359861c739e955e79d9a303bcbc70fb988958b1` of
[ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp).
SHA-256 hashes (verified by Nix on download):

| Model | SHA-256 |
| --- | --- |
| large-v3-turbo | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| tiny.en (explicit CPU test package) | `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f` |

The running service never downloads a model. Package overrides support another
compatible model derivation/Nix path, or an absolute **string** for an existing
local model (not copied into the store):

```nix
inputs.zd.packages.${system}.default.override {
  modelPath = "/var/lib/dictation/model.bin";
  audioSamples = 640000;
  deviceSlots = 16;
  inferenceThreads = 4;
}
```

A missing/unreadable/incompatible model produces `ModelBackendInitialization`,
not fixture output. English transcription, no translation, no previous-session
prompt context, recognizer punctuation and non-speech token suppression are set
explicitly. No rewriting model or command grammar is added.

## Public interface and ownership

`Session(transcript_capacity, audio_capacity)` in `src/dictation.zig` remains the
primary seam used by both the daemon and deterministic tests. It handles protocol
readiness, `modelLoaded`, toggles, `audio`, source loss/capture failure, decoder
completion/failure and final-only publication. Tests control external effects,
not a duplicate state machine or private buffer layout.

Effects provide `defaultSource()`, `recording(?source_id)`, `decode(samples)`,
`show`, `problem` and `publish`. Recording with `null` closes capture. Only
`decode` may retain a borrow: samples remain immutable until inference relinquishes
them and the caller delivers completion/failure. Publication must copy into its
own bounded slot before returning. `shutdown` is called only after capture is
closed and inference joined.

- PipeWire registry and metadata events are serviced on the daemon loop. A bounded
  node table resolves `default.audio.source` to an object serial. The session
  selects that serial once; `target.object`, `node.dont-reconnect` and
  `node.dont-fallback` pin the native stream. Registry removal fails that recording.
- Native negotiation/conversion supplies mono 16 kHz F32. Format, buffer extent,
  stride, corruption and finite-sample checks reject unusable data. No recorder
  subprocess or intermediate audio file participates in production.
- Stream callbacks deliberately omit `RT_PROCESS`; they run on the same loop as
  session commands. An error inside a process callback defers stream destruction
  until the callback returns and its native buffer is queued back. A three-second
  connection/negotiation timeout is separate from recording length.
- One pthread owns the resident whisper context. A single audio borrow and a
  single result slot pass ownership using release/acquire state transitions.
  There is no expanding job queue or concurrent use of the context. The worker
  concatenates recognizer segments into bounded storage; overflow rejects all
  output. Audio and application result bytes are cleared after their last use.
  The model uses whisper's `no_state` API; backend initialization is verified before
  readiness. Decoder state is freed after each decode (including native
  spectrogram/result storage), then recreated for the next decode. Model weights
  stay resident; old decoder results are not retained merely to reuse scratch.
- Obvious silence (mean-square amplitude below `1e-6`) avoids inference. This
  reduces silence hallucinations but cannot guarantee recognizer correctness.
  Empty/whitespace results, capture/inference errors and capacity/publication
  failures preserve the clipboard.

The control socket is abstract Unix `SOCK_SEQPACKET`, named `dictation-<uid>`.
One instance per UID/network namespace, same-UID peers only; multiple graphical
sessions for one UID are not separated yet. Commands are exactly `toggle`, with
16-byte request scratch, one-second idle-peer deadlines and a 1.5-second client
response deadline. Saturation best-effort replies `busy` or disconnects; it never
reports copy success. A successful client reply means **toggle accepted**, not
successful publication (including loading/finalization refusal).

Clipboard source bytes stay immutable while source-owned or reader-pinned.
A source cancellation plus no remaining readers permits clearing/reuse. New work
does not clear the old selection. Transfers are nonblocking, progress in chunks
up to 65,536 bytes, and expire after five seconds without write progress. Full
source/transfer tables reject rather than allocate or block. Wayland has no
publication acknowledgement: success means a valid selection request was queued
without a known failure, not proof that another application pasted.

## Static storage and allocation audit

`Storage` in `src/main.zig` is the actual typed aggregate, not a guessed arena.
`@sizeOf(Storage)` includes alignment/padding and every simultaneously live copy:
session PCM and transcript, clipboard slots/readers/transfers, control client and
server scratch, poll state, diagnostics, device records/names, metadata and SPA
parameter scratch, inference configuration, job/result slot, pthread attributes
and an explicitly supplied worker stack. Read-only literals/protocol tables and
executable code are not mutable workspaces.

Run the **built binary** with `footprint` to inspect the total and components.
The worker stack is already included in `static_bytes`; do not add it twice.
Main-thread application stack is separately budgeted conservatively at **16 KiB**,
not compiler-certified: fixed integer formatting (65 bytes plus a 32-byte writer),
C SPA format/parser structs, socket credentials, syscall temporaries and the
4,111-byte `std.debug.FullPanic` buffer dominate our reachable paths. Worker-side
application frames are bounded similarly; the configured stack also accommodates
native inference call frames. Native libraries' own threads/stacks remain external.

| Package argument | Unit/default | Constraints |
| --- | --- | --- |
| `transcriptBytes` | bytes, 1,048,576 | 1–67,108,864; session + worker + each clipboard slot |
| `audioSamples` | mono F32 samples, 480,000 | 1–9,600,000; four bytes each; explicit exhaustion |
| `deviceSlots` | source records, 32 | 1–256; 256-byte name slots |
| `workerStackBytes` | bytes, 8,388,608 | 1–64 MiB, multiple of 65,536 |
| `inferenceThreads` | external decoder threads, 4 | 1–64; does not multiply application job slots |
| `controlClients` | peers, 8 | 1–64 |
| `clipboardSlots` | full transcript copies, 3 | 2–8 |
| `transfers` | concurrent readers, 8 | 1–64 |

`config.zig` rejects invalid and overflowing configurations at comptime. Changes
rebuild the executable; no runtime allocator or fixed arena is involved. The
[NixOS module](installation.md) routes these same package arguments; future
storage additions must retain this shared contract.

Audit scope includes startup, errors, capture teardown, worker setup, completion,
shutdown, formatting and forwarded logging:

- libc `main` borrows argv. `std.mem` slices/copies/trim/print, integer `parseInt`,
  math and atomics do not allocate on the used paths. `std.mem.print` uses the
  fixed writer, not an allocating writer. No `std.Thread.spawn` is used.
- The pthread receives the statically declared, 65,536-aligned stack through
  `pthread_attr_setstack`. libc's thread/TLS metadata is external runtime storage,
  not an application buffer hidden behind malloc. Native libraries may create
  their own threads and workspaces; those are not counted as static application RAM.
- `native.c` only bridges header-inline PipeWire/SPA APIs. Its parser/builders use
  fixed structs and the caller's POD buffer. It contains no allocation routine,
  generic storage shim, retained application state or application policy.
- whisper/ggml callbacks discard library message strings, realtime/progress/text
  printing is disabled, and Wayland diagnostics are sanitized. Our diagnostics
  contain phase/error names, never dictated text, audio, or model-path contents.
- Panic uses a constant diagnostic and `_exit`, not stack-trace/symbolization or
  default logging. Build tools, generators and Zig's standard test runner are not
  part of the shipped allocation guarantee.

Genuine PipeWire object/property/converter allocations, whisper/ggml/model/GPU
allocations, libwayland objects and libc runtime internals remain **exempt**. They
are neither bounded by this layout nor patched to pretend they are static.
Wayland's reused two-frame shared-memory backing is separately **51,200 bytes**,
unmapped on teardown; it is never used for samples/transcripts or as a heap.
No RSS measurement or process-wide malloc trap proves this contract.

Captured audio is transient; no recordings, transcript history, or content logs
are created. Application clearing is a retention policy, not forensic erasure
of every copy in dependencies or external clipboard managers.

## Development and checks

```sh
nix develop                       # CPU toolchain; no model download needed
zig test src/tests.zig             # fast checks: Zig standard runner only
zig build test                    # same suite through the optional build graph
zig build -Doptimize=ReleaseSafe
zig fmt --check build.zig src/*.zig
nixfmt --check flake.nix nix/*.nix

# Separate installed-consumer checks, never part of checkPhase:
nix build .#cpu.passthru.tests.native-smoke --no-link -L
nix build .#cpu.passthru.tests.capture-inference --no-link -L
nix build .#cpu.passthru.tests.sizing --no-link -L
nix build .#cpu.passthru.tests.model-failure --no-link -L
nix build .#cpu.passthru.tests.backend-required --no-link -L
```

Native builds alone are supported on aarch64-linux and x86_64-linux. The package's
`checkPhase` contains **only `zig test src/tests.zig` and standard hooks**. Fast
tests do not open PipeWire/Wayland, load models, use a GPU or access the network.
Nix provisions selected model data for installed packages, outside those tests.

The development shell generates protocol/C bindings and rewrites `src/options.zig`
to development defaults: explicit CPU backend and `/var/lib/dictation/model.bin`.
For a readily provisioned runnable CPU package use `nix build .#cpu`; do not infer
that a successful development build loaded a model. The build graph downloads no
dependencies. If this workspace's `_gateway` proxy causes Zig's build runner to
report `InvalidHostName`, use `env -u https_proxy -u HTTPS_PROXY zig build` for the
offline build-graph commands.

The package deliberately obtains the Nix libc configuration with `zig libc`,
passes it to compilation, and specifies the GNU target, dynamic interpreter and
library paths. Otherwise explicit-target Zig compilation may select an old libc
symbol baseline incompatible with the pinned PipeWire. CUDA builds permit
unresolved **shared-library** symbols at link time: the real `libcuda.so.1` is
supplied by the host driver, not the build sandbox. Direct application symbols
must still resolve, and CPU builds retain strict shared-library resolution.
C binding generation uses
`pkg-config --cflags-only-I`: PipeWire also advertises flags unsupported by
`zig translate-c`. Keep the installed-consumer tests when changing these details.

Named tests are independently runnable; merely exposing `passthru.tests` does not
execute them. `native-smoke` uses real headless Sway/clipboard with explicit
fixture audio/inference. `capture-inference` adds a private real PipeWire server,
WirePlumber, two virtual microphones, upstream's pinned JFK sample, and actual
CPU tiny.en recognition. It checks source pinning across default changes,
microphone teardown, resident readiness across sessions, final-only clipboard
retrieval, silence and missing-default failure. This is not a physical microphone,
GPU, NixOS VM, or target-desktop quality test. `sizing` compares actual default and
small installed binaries. `model-failure` verifies an intentionally missing model
with real native startup: no capture, no fixture fallback, no clipboard replacement.
`backend-required` deliberately pairs the real CPU-only library with a daemon
configured to require GPU initialization: readiness/capture must be refused, not
silently switched to CPU. This validates the failure policy, not a CUDA device.
Allocation/source review is separate from all fast tests.


### Recorded milestone-02 verification

Executed on **aarch64-linux**, using Zig **0.17.1**:

- All **12 standard Zig tests** passed directly and through `zig build test`;
  the development ReleaseSafe build and Zig/Nix formatting checks passed.
- Installed default CUDA/large-v3-turbo and CPU/tiny.en packages built, as did
  the small and deliberately GPU-required/CPU-library configurations. Their
  `checkPhase` ran the same twelve tests. Both pinned model downloads succeeded.
- All five named checks above passed: fixture desktop, real capture/inference,
  missing-model refusal, required-backend refusal, and sizing. The real
  recognition test also passed after switching to per-decode native state
  release while retaining model weights.
- Model-path evaluation verified that a Nix path becomes a store dependency;
  absolute strings remain host paths. Invalid/overflowing sizing is covered by
  the standard suite; installed non-default sizing was checked separately.
- Source and undefined-symbol review found no application allocator path.
  Native dependency allocations remain exempt; this is not a process-wide
  no-allocation claim. An x86_64-target semantic compile also passed, but was
  **not** a linked/native x86_64 package or wrapper execution test.

Measured installed CPU layouts (bytes; both aligned to 65,536):

| Component | Default sizing | Small test sizing |
| --- | ---: | ---: |
| Whole `Storage` | 15,663,104 | 1,179,648 |
| Session | 2,968,616 | 744 |
| Wayland state | 3,146,240 | 384 |
| Capture state | 10,320 | 2,160 |
| Worker, including stack | 9,502,720 | 1,114,112 |

The CUDA executable's `main.storage` ELF symbol also measures 15,663,104 bytes;
that inspection did not execute CUDA. Wayland pixel backing adds 51,200 bytes,
and the separately budgeted main stack remains as described above.

The implementation received a local standards/spec self-review; no independent
sub-agent review was available. Review fixes included native decoder-state
retention, fail-closed GPU initialization, driver-aware linking and preserving
Nix-path provisioning. **NVIDIA execution, a physical microphone, target-desktop
focus/click-through and recognition quality/latency remain pending milestone 09.**
Streaming (04), asynchronous restart (05), broader recovery (07) and reactive UI
(08) are not claimed here. Milestone 03 installation evidence is recorded in the
[installation guide](installation.md).
