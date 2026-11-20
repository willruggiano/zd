# Streaming dictation

Native PipeWire capture feeds bounded windows to a resident whisper.cpp model
while recording continues. Audio storage is recycled; the clipboard changes only
after stop and successful finalization. [NixOS graphical-session installation](installation.md)
is available. Restart during finalization starts replacement capture while old
inference unwinds. Previous transcripts remain pasteable during new work,
including bounded slow/concurrent readers and external selection takeover.
Recoverable session failures allow a fresh toggle even while cancelled inference
unwinds. Reactive multi-monitor feedback remains a later milestone.
CPU integration tests do not establish target-GPU throughput or recognition quality.

## Run

On a supporting Wayland desktop with PipeWire, WirePlumber and an NVIDIA driver:

```sh
nix build                         # CUDA + hash-pinned large-v3-turbo
./result/bin/dictation daemon     # load once, then remain resident
# Wait for "model ready (GPU requested; CPU fallback allowed)". From another terminal/shortcut:
./result/bin/dictation toggle     # open the current default microphone
# Speak; decoding proceeds in the background.
./result/bin/dictation toggle     # close microphone, finalize, copy
# Paste manually into another application; optional independent reader:
wl-paste --no-newline
```

The default CUDA build accepts NVIDIA's unfree toolkit dependencies through the
flake's Nixpkgs configuration. GPU execution needs the host NVIDIA driver libraries
(`/run/opengl-driver/lib` on NixOS). Upstream may fall back to CPU when GPU
initialization is unavailable; a sanitized warning makes this visible. The
application itself is MIT licensed.
`nix build .#cpu` explicitly selects **CPU + tiny.en**, for integration testing or
experimentation, not a silent substitute for the default GPU/model. It performs
real capture and recognition and identifies itself as a CPU build in diagnostics.
For simulated audio/inference instead, use [the fixture mode](tracer.md).

The daemon needs `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, a usable default source in
PipeWire's `default` metadata, and a compositor providing **layer-shell** and
**ext-data-control-v1**. There is no compositor-specific API or clipboard fallback.
Missing protocols produce `MissingLayerShell` / `MissingDataControl`; absent
Wayland produces `WaylandConnection`. A missing microphone fails visibly rather
than selecting an arbitrary source. Audio-server/compositor loss requires a daemon
restart; see [failure and recovery](#failure-and-recovery).

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

- There is **no recording timer**. Decoding must keep pace with capture and the
  accumulated transcript must fit. Backlog exhaustion (`AudioCapacity`) or text
  exhaustion (`TranscriptCapacity`) closes capture and preserves the previous
  clipboard; no samples or text are silently dropped to keep a session running.
- Forced cuts in continuous speech can affect word recognition and punctuation.
  Bounded text context helps continuity but is not a full-session decoder or a
  guarantee of correct boundary words; see the streaming algorithm below.
- Cancellation is cooperative, not GPU preemption. Replacement capture starts
  without waiting, but its bounded backlog can fill while the old decoder unwinds.
  Such exhaustion fails visibly and never revives the superseded transcript.
  A fresh toggle after a recoverable failure also starts capture without waiting
  for an outstanding borrow; it has the same bounded headroom as a restart.
- No multi-monitor/reactive bars yet (08).
  No lock/suspend integration: locking does not cancel recording. Shutdown closes
  capture first and requests decoder abort, but waits for outstanding native work
  before releasing buffers; model initialization itself is not cancellable.
- This is not recognition-quality, sustained-streaming or RTX 3090 acceptance.
  Those measurements require the target desktop in milestone 09.

## Dependencies and provisioning

`flake.lock` retains **Zig 0.17.1**, explicitly selected from Mitchell Hashimoto's
overlay, and Nixpkgs `d3b13ad75cc492690728f9307e443dec9ef9a20e`.
Pinned APIs used here are PipeWire **1.6.9**, whisper.cpp **1.9.5** (ggml supplied by
nixpkgs' llama-cpp **0.7.0**),
Wayland **1.26.0**, wayland-protocols **1.49**, and wlr-protocols **2022-09-05**.
The CUDA build deliberately selects `cudaPackages_12_9` (nvcc **12.9.86**) and
compute capability **8.6** (CMake architecture **86**), suitable for the RTX 3090. This is a build-toolkit
choice, not the user's reported driver/UMD version.

`nix/whisper.nix` is a small override of nixpkgs' **`whisper-cpp`**, not a separate
build recipe. It adds no local Whisper source patches, selects CUDA support/toolkit
and disables the optional SDL/FFmpeg integrations. Nixpkgs owns the shared-library packaging,
examples, compiler settings and its system llama.cpp/ggml dependency. The flake's
`cudaCapabilities = [ "8.6" ]` selects the target architecture through nixpkgs.
The daemon calls ggml's normal backend loader before initializing Whisper, as
required by nixpkgs' dynamically loaded backends. Its current `whisper.pc` omits
ggml's library directory, so the consumer also uses `llama.pc` for the system
ggml include/link paths and records that library directory in the installed RPATH.

GPU use is a **preference**, not a fail-closed policy. Pinned upstream's “no GPU
found” or GPU initialization failure diagnostics produce the fixed warning
`GPU backend unavailable; allowing CPU fallback`. Other library strings stay
suppressed to avoid leaking dictated content or paths. Warnings can repeat when
native decoder state is recreated. Readiness reports a GPU *request*, never proof
of CUDA execution. Upstream initialization errors still fail normally if no usable
backend/model can be initialized. The model is not silently changed, and fixture
mode is never an automatic fallback. An explicit CPU build passes `use_gpu=false`.

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

`Session(transcript_capacity, Windows)` in `src/dictation.zig` remains the
primary seam used by both the daemon and deterministic tests. It handles protocol
readiness, `modelLoaded`, toggles, `audio`, source loss/capture failure, decoder
completion/failure and final-only publication. Tests control external effects,
not a duplicate state machine or private buffer layout.

Effects provide `defaultSource()`, `recording(?capture_identity)`, `decode(operation, samples, context)`,
`show`, `problem` and `publish`. Recording with `null` closes capture.
`decode(operation, samples, context)` may retain the PCM borrow; the context is call-scoped
and the worker copies it into fixed storage before returning. Samples remain
immutable until inference relinquishes them and the caller delivers `complete`
or `inferenceFailed`. The caller then releases the external result slot and calls
`advance`, allowing the next queued window to start. This ordering avoids submitting
to a still-busy worker or clearing its result before the session has consumed it.
Publication must copy into its own bounded slot before returning. `shutdown` is called only after capture is
closed and inference joined.

Capture identities contain the session generation and selected source serial.
`audio(identity, samples)`, `captureFailed(identity, reason)` and
`sourceRemoved(identity)` only affect that active recording. A source serial alone
is insufficient: the same device may be reused by the next session. Stop clears
the active identity before finalization, so late capture events cannot invalidate
a completed recording. Decoder terminal events keep their separate window identity.

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
  The session, not the worker, owns the fixed FIFO. There is no expanding job queue
  or concurrent use of the context. The worker concatenates recognizer segments into bounded storage; overflow rejects all
  output. Audio and application result bytes are cleared after their last use.
  The model uses whisper's `no_state` API; backend initialization is verified before
  readiness. Decoder state is freed after each decode (including native
  spectrogram/result storage), then recreated for the next decode. Model weights
  stay resident; old decoder results are not retained merely to reuse scratch.
- Obvious silence (mean-square amplitude below `1e-6`) avoids inference. This
  reduces silence hallucinations but cannot guarantee recognizer correctness.
  Empty/whitespace results, capture/inference errors and capacity/publication
  failures preserve the clipboard.

### Failure and recovery

- Wholly silent sessions skip inference; empty/whitespace-only recognition gives
  brief no-speech feedback without publishing. Pauses, silent windows and empty
  chunks within valid speech do **not** end capture or erase committed text.
  Trailing silence does not prevent copying an otherwise valid transcript.
  The simple energy filter mitigates hallucinations, not a guarantee of no
  hallucinations or correct recognition in noise.
- Missing default microphone, failed stream start/negotiation, removal of the
  pinned microphone, invalid PCM, inference/publication failure and storage
  exhaustion fail the session and preserve the existing clipboard. Stream
  diagnostics identify `MicrophoneRemoved`, `CaptureDisconnected`, `CaptureFormat`,
  `CaptureBuffer` or `CaptureTimeout`; they never forward device/library strings.
  Default changes never retarget a recording. A fresh toggle resolves the current
  default again; no microphone is opened automatically when a device returns.
- Retry after failure starts fresh capture even while cancelled inference unwinds.
  It uses only the other audio slots, never reclaims the outstanding borrow early,
  and never carries failed-session text into the new prompt. An obsolete capture
  callback or decoder success/failure cannot stop, publish, report an error for,
  or change the indicator of the replacement session. This also holds after the
  replacement has succeeded. Ordinary stop does not turn a subsequent late
  capture error into an inference failure.
- Native callbacks are serialized on the main loop. Stream destruction occurs
  only outside process callbacks, after returning the borrowed PipeWire buffer.
  The old stream is destroyed before its identity/error slot is reused. No
  asynchronous stream callback queue or extra session queue is introduced.
- Lost PipeWire/Wayland connections, registry failures and exhausted device tables
  are **daemon-fatal**, not transparent reconnects. Diagnostics report the failure
  and ordered teardown closes capture, requests inference abort, joins the worker,
  clears application samples/text and releases native resources. Foreground use
  requires relaunch; the NixOS user service's existing `Restart=on-failure` retries
  after two seconds (subject to systemd start limits). Restore dependencies first;
  enlarge `deviceSlots` and rebuild if necessary. A restarted daemon reloads the
  model and stays idle: it does not resume an interrupted recording.
- Model/backend initialization failure leaves the daemon unavailable for recording
  until restart with a usable model/backend. There is no model/fixture substitution.
  GPU-requested readiness still allows the documented upstream CPU fallback.
- Failure preserves the clipboard **while its owner/connection survives**. A fatal
  daemon/compositor disconnect necessarily releases our old selection and active
  transfers; without a clipboard manager it may no longer be pasteable. Do not
  interpret this as publishing partial/error text, or a promise to persist the
  clipboard across daemon/compositor restarts. An independent external selection
  is not proactively replaced by a failure.
- No lock/suspend hooks exist. Locking alone does not cancel capture, and suspend
  cancellation is not guaranteed; ordinary resulting dependency errors follow
  the same rules above. If Wayland is missing, diagnostics/exit are the feedback,
  not a claim that an on-screen error was displayed.

### Window boundaries and transcript assembly

- `audioSamples` is now the maximum **per-window** length, not a whole-session
  bank. `audioWindows` slots cover the borrowed window, sealed FIFO backlog and
  current capture window together. Defaults are three slots of 480,000 samples
  each (30 seconds/window at 16 kHz). No extra hidden whole-session PCM copy exists.
- Prefer a boundary after `windowMinSamples` (default 48,000 / three seconds)
  when `pauseSamples` consecutive samples (8,000 / half a second) each have
  squared amplitude below `1e-6`. Otherwise seal at the maximum window size.
  This simple quiet detector is not a general VAD; background noise can prevent
  a pause boundary. Stop seals even a shorter trailing window immediately.
- Every captured sample belongs to exactly one ordered window. There is **no
  audio overlap or text de-duplication heuristic** that might erase intentional
  repetitions. Bounded *text* context is the selected continuity mechanism:
  the most recent `contextBytes` of committed current-session text (default 256),
  shortened to a whitespace boundary so no partial word/UTF-8 sequence is passed.
  Zero disables context. The native decoder receives this as `initial_prompt`,
  with `no_context=true` and fresh native state for each window. This behavior was
  checked against pinned whisper.cpp 1.9.5 source, not assumed from the field name.
- Decode results are whitespace-trimmed, then appended in order with one space
  between nonempty results. Empty windows do not erase earlier committed text.
  Internal results never change the indicator to finalizing while capture is
  active, display transcript text, or replace the clipboard. Only after stop and
  draining every queued window may the complete accumulated text be published.
- The worker pads inputs shorter than one second with silence using one fixed
  16,000-sample (64,000-byte) scratch buffer. In particular, whisper.cpp otherwise
  returns success without processing inputs shorter than 100 ms. Padding avoids
  that API shortcut, but cannot guarantee recognition of an isolated word fragment.
  Full windows are borrowed without this extra copy; padding is cleared after use.
- Slots are cleared/recycled only after the decoder relinquishes them. Capture
  errors or capacity failures discard unborrowed audio and accumulated text
  immediately, but preserve the outstanding immutable borrow until its late
  completion/failure, which cannot publish or schedule discarded work. Restart
  follows the same retention rule but uses the other slots for new capture.
- Text prompting is not acoustic overlap: a forced boundary may split a word,
  the recognizer may repeat/omit speech or hallucinate, and punctuation can vary.
  Pause-aligned and continuous joins are exercised deterministically; real
  boundary quality and sustained throughput remain target-desktop acceptance in
  09. There is no later whole-session second pass after old audio is recycled.

### Restart and operation ownership

A toggle **while recording** stops capture, even during background inference.
The next toggle **during finalization** supersedes that session and starts a new
recording on the current default microphone. Accumulated old text and unborrowed
queued audio are cleared immediately; the previous clipboard is untouched. This
is replacement, not a queue of user sessions or a separate cancel command.

- The ring retains at most **one** old inference borrow at its head. Its samples
  remain immutable until the native call actually returns. All other slots are
  immediately reusable by replacement capture. Repeated restarts discard that
  replacement's backlog rather than retaining another generation of queued work.
- The existing `audioWindows >= 2` constraint gives at least one replacement
  window alongside the retained borrow. Defaults give two replacement windows;
  all three slots are usable by the current session when no old borrow remains.
  No second full-session bank, new sizing input or hidden reserve is introduced.
  Capacity failures still reject the session rather than silently dropping speech.
- Each decoder operation carries a **session generation and window number**,
  two `u64` values. They are never reused within a daemon lifetime: checked
  increments fail closed on identity exhaustion rather than wrapping. Only a
  matching terminal event retires the current borrow. A matching obsolete event
  retires its own audio but cannot append text, report an error or change the
  current capture/indicator. Duplicate or out-of-order identities retire nothing.
- `decode(operation, pcm, context)` borrows PCM and copies call-scoped context.
  `cancel(operation)` requests cancellation; it does **not** release that borrow.
  Adapters deliver `complete(operation, text)` or
  `inferenceFailed(operation, reason)` only after relinquishing PCM. The daemon
  releases the worker's result slot before `advance` or further capture/control
  events can schedule another job. There are no incremental text callbacks.
- One worker and one native context remain serialized. Cancellation sets an atomic
  per-operation flag, read alongside shutdown by whisper's abort callback. A new
  job resets it only after the old operation has returned and its result slot is
  released. A race can still yield an old successful/partial result; session
  eligibility, not the native return code, is authoritative. No replacement call
  overwrites an old prompt, result buffer, padding buffer or PCM borrow.
- Old prompt/result bytes survive only their outstanding use and are cleared on
  release; current transcript storage is reused immediately. Model initialization
  and decoder-state initialization do not offer immediate cancellation. Pinned
  whisper.cpp checks abort at computation boundaries, not guaranteed instantaneous
  GPU preemption. Target-desktop restart latency remains milestone 09.

The control socket is abstract Unix `SOCK_SEQPACKET`, named `dictation-<uid>`.
One instance per UID/network namespace, same-UID peers only; multiple graphical
sessions for one UID are not separated yet. Commands are exactly `toggle`, with
16-byte request scratch, one-second idle-peer deadlines and a 1.5-second client
response deadline. Saturation best-effort replies `busy` or disconnects; it never
reports copy success. A successful client reply means **toggle accepted**, not
successful publication (including a loading refusal or a restart).

### Clipboard ownership and concurrent readers

The session's accumulated transcript, worker result and each offered transcript
have **separate fixed-capacity storage**. `clipboard.zig` owns the bounded serving
state used by native Wayland and by the deterministic test I/O adapter. Starting,
restarting, preparing or failing a session never proactively clears the previous
selection. Only successful finalization offers a complete new transcript.

- Each publication creates a fresh ext-data-control source, used in exactly one
  `set_selection` request. Its bytes stay immutable while source-owned **or**
  reader-pinned. Replacement/external takeover delivers `cancelled`: destroy the
  source then, but retain any bytes still needed by already requested transfers.
  Clear/reuse a slot only after both ownership and its last reader are gone.
  No transcript history, recovery copy, or incremental publication is retained.
- Every accepted `send` owns one descriptor, offset and idle deadline in the
  fixed transfer table. One event-loop turn attempts **at most one 65,536-byte
  write per reader**, without a draining loop. Short writes advance only that
  reader; EAGAIN/EINTR and zero writes do not extend its deadline. Positive write
  progress renews the five-second idle deadline. Check expiration **before**
  trying another write, so a late writable event cannot resurrect an expired
  request. A reader that keeps making progress can live longer; storage and work
  per turn remain bounded, not the total time of a progressing transfer.
- Only pipes and sockets are accepted as transfer sinks: `O_NONBLOCK` cannot
  prevent regular-file/device writes from blocking. Preserve existing fd flags
  when setting it. Unsupported MIME/sinks, preparation errors and full transfer
  tables close the new fd without affecting the source, other readers or capture.
  Fatal write errors (including disconnected readers), timeout and shutdown close
  the transfer and drop its pin. SIGPIPE is ignored by the daemon.
- A failed/expired reader may receive a prefix already written into its pipe,
  then EOF: this is an unsuccessful **transfer**, not publication of a truncated
  transcript. The current offer remains complete and another reader may retry.
  Wayland has no transfer-success or publication acknowledgement; session success
  means a valid selection request was queued without a known failure, not that
  another application pasted. A transport failure is fatal, not recoverable proof
  that the compositor still owns the previous selection.
- A full source table (including cancelled but reader-pinned offers, or sources
  still awaiting cancellation) rejects publication with failure feedback. Do not
  evict an old reader/selection, grow storage, truncate, or claim copy success.
  Source-creation/known selection errors also fail publication and release the
  candidate slot. Request cleanup permits later sessions to publish normally.

External clipboard managers may retain text independently; the application does
not provide or control their history. Native protocol lifetimes were checked
against pinned wayland-protocols 1.49's ext-data-control XML.

## Static storage and allocation audit

`Storage` in `src/main.zig` is the actual typed aggregate, not a guessed arena.
`@sizeOf(Storage)` includes alignment/padding and every simultaneously live copy:
session window slots/FIFO metadata and accumulated transcript, clipboard slots/readers/transfers, control client and
server scratch, poll state, diagnostics, device records/names, metadata and SPA
parameter scratch, tagged capture identity, bounded connection/stream error slots,
inference configuration, job/result slot, session/window identities,
atomic cancellation flag, fixture completion identity/deadline, bounded prompt and
short-tail padding, pthread attributes
and an explicitly supplied worker stack. Read-only literals/protocol tables and
executable code are not mutable workspaces.

Run the **built binary** with `footprint` to inspect the total and components.
`clipboard_bytes`, `clipboard_offer_bytes` and `clipboard_transfer_bytes` expose
the actual serving aggregate and its tables (including padding), all already
included in `wayland_bytes` and `static_bytes`; do not add them again.
`retained_inference_windows=1`, `replacement_audio_windows=audioWindows-1` and
`operation_bytes=16` expose restart headroom and identity size. The typed aggregate
counts all instances: session counters and optional in-flight identity, the
worker's single completion identity/flag and the fixture event identity, even
when fixture mode is unused. No additional event queue or worker is created.
The worker stack is already included in `static_bytes`; do not add it twice.
Main-thread application stack is separately budgeted conservatively at **16 KiB**,
not compiler-certified: fixed integer formatting (65 bytes plus a 32-byte writer),
C SPA format/parser structs, socket credentials, a fixed `stat` for clipboard
sink validation, syscall temporaries and the
4,111-byte `std.debug.FullPanic` buffer dominate our reachable paths. Worker-side
application frames are bounded similarly; the configured stack also accommodates
native inference call frames. Native libraries' own threads/stacks remain external.

| Package argument | Unit/default | Constraints |
| --- | --- | --- |
| `transcriptBytes` | bytes, 1,048,576 | 1–67,108,864; session + worker + each clipboard slot |
| `audioSamples` | mono F32 samples/window, 480,000 | 1–9,600,000; four bytes each, multiplied by `audioWindows` |
| `audioWindows` | slots, 3 | 2–16; one possibly obsolete borrow plus current queued/filling windows |
| `windowMinSamples` | samples, 48,000 | 1–`audioSamples`; stop may seal a shorter tail |
| `pauseSamples` | quiet samples, 8,000 | 1–`windowMinSamples` |
| `contextBytes` | prompt bytes, 256 | 0–4096; worker also owns one NUL byte |
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

Audit scope includes startup, errors, capture teardown, worker setup, cancellation,
queue retirement, stale completion, shutdown, formatting and forwarded logging:

- Streaming uses array slots, bounded index/length arithmetic, scalar energy and
  quiet counters, slices and fixed copies. No new application allocator or
  unbounded stack scratch is used. Prompt tokenization allocates inside the genuine
  whisper library; our prompt and short-tail buffers remain in `Storage`.
- libc `main` borrows argv. `std.mem` slices/copies/trim/print, integer `parseInt`,
  checked math, scalar-struct `std.meta.eql` and atomics do not allocate on the used paths. `std.mem.print` uses the
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

The backend loader and upstream plugin/registry allocation are genuine dependency
internals, not application storage moved behind a wrapper. Backend-warning
classification uses only borrowed strings and fixed diagnostic literals.

## Development and checks

The development shell includes `gh-stack`, `gh` and Git from pinned Nixpkgs for
PR maintenance only; they are not dependencies of the installed daemon. Invoke
`gh-stack` directly without a per-user extension installation, and authenticate
with `gh auth login` if needed. For jj-managed branches, use
`gh-stack link <stack-number> <pull-request-url>` to append an existing PR without
changing local stack tracking or checking out branches.

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
nix build .#cpu.passthru.tests.streaming --no-link -L
nix build .#cpu.passthru.tests.restart --no-link -L  # explicit test-only decoder substitution
nix build .#cpu.passthru.tests.clipboard --no-link -L # real controlled Wayland readers; adapted decoder
nix build .#cpu.passthru.tests.recovery-pipewire --no-link -L # adapted decoder; real audio-server loss
nix build .#cpu.passthru.tests.recovery-wayland --no-link -L # adapted decoder; real compositor loss
nix build .#cpu.passthru.tests.recovery-capacity --no-link -L # two-device table and exhaustion
nix build .#cpu.passthru.tests.sizing --no-link -L
nix build .#cpu.passthru.tests.model-failure --no-link -L
nix build .#cpu.passthru.tests.backend-fallback --no-link -L
```

On a RAM-constrained host, keep CUDA builds separate from VM checks. To release
evaluator memory before compiling a fresh dependency stack:

```sh
drv=$(nix eval --raw .#default.drvPath)
nix build "$drv^out" --no-link -L --max-jobs 1 --cores 1
```

Native builds alone are supported on aarch64-linux and x86_64-linux. The package's
`checkPhase` contains **only `zig test src/tests.zig` and standard hooks**. Fast
tests do not open PipeWire/Wayland, load models, use a GPU or access the network.
Nix provisions selected model data for installed packages, outside those tests.

The development shell generates protocol/C bindings and rewrites `src/options.zig`
to development defaults: explicit CPU backend and `/var/lib/dictation/model.bin`.
For a readily provisioned runnable CPU package use `nix build .#cpu`; do not infer
that a successful development build loaded a model. The build graph downloads no
dependencies. After changing native dependencies, remove `generated/c.zig` to
regenerate development bindings against their headers. If this workspace's
`_gateway` proxy causes Zig's build runner to report `InvalidHostName`, use `env -u https_proxy -u HTTPS_PROXY zig build` for the
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
GPU, NixOS VM, or target-desktop quality test. `streaming` uses the same real
native consumer with ten-second windows, eight audio slots and bounded prompt
context. It waits for actual CPU completion while capture remains open, verifies
that the clipboard is unchanged, then drains multiple windows after stop. Its
recognition assertions are regression checks, not a comprehensive boundary-quality
assessment. `restart` uses the same installed windowed CPU package and real
PipeWire/Wayland, but **explicitly interposes decoding** via test-only
`LD_PRELOAD`. It holds the old native call after observing the real abort callback;
replacement PCM is captured before a test-owned gate lets that call return. It
checks retained PCM, fresh default-source selection, cancellation-flag reset,
serialized replacement decoding and one final publication. Model loading/state
allocation remain real, but this establishes neither recognition nor real
whisper/GPU cancellation latency. The interposer/gate are absent from production
packages and module settings. `clipboard` likewise uses real model loading,
native PipeWire capture and headless Sway, with **explicitly interposed decoding**
that supplies distinct 128 KiB results behind a test-owned completion gate. Real
ext-data-control readers request into 4 KiB pipes: the test controls slow progress,
concurrency, disconnect and complete stalls while recording/decoding continue.
It also uses ordinary `wl-paste`/`wl-copy`, exercises external takeover, full
source/transfer tables and reuse, and checks that old readers receive unmixed old
text. The helper, synthetic audio, large result generator and gate are test-only;
this is neither real recognition nor target-desktop/GPU latency evidence.
`recovery-pipewire`, `recovery-wayland` and `recovery-capacity` run real native
capture and headless Sway with **explicitly interposed decoding** and synthetic
non-sensitive PCM. With only two device slots they verify default pinning, source
removal during a held decode, immediate retry on a different source, intact old
PCM, cancellation, silence/empty/failure preservation, repeated successful retries
and device-record reuse. Each ends with actual PipeWire loss, compositor loss or
device-table exhaustion respectively, requiring diagnostic failure/exit and safe
capture teardown, not a fictitious reconnect. Real model/state initialization
remains active; gate files and helpers are test-only. These native consumers need
a sandbox supporting private Unix sockets, headless Sway and PipeWire, not a GPU,
host microphone, desktop session or `/dev/kvm`. They are not recognition tests.
`sizing` compares actual default and
small installed binaries. `model-failure` verifies an intentionally missing model
with real native startup: no capture, no fixture fallback, no clipboard replacement.
`backend-fallback` deliberately pairs the real CPU-only library with a daemon
requesting GPU use: it must warn, become ready and actually transcribe the virtual
microphone input using CPU. This validates upstream fallback and sanitized logging,
not a CUDA device. It replaces the historical `backend-required` consumer.
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

Milestone-02 installed CPU layouts, **before streaming** (bytes; aligned to 65,536):

| Component | Default sizing | Small test sizing |
| --- | ---: | ---: |
| Whole `Storage` | 15,663,104 | 1,179,648 |
| Session | 2,968,616 | 744 |
| Wayland state | 3,146,240 | 384 |
| Capture state | 10,320 | 2,160 |
| Worker, including stack | 9,502,720 | 1,114,112 |

At milestone 02 the CUDA executable's `main.storage` ELF symbol measured 15,663,104 bytes;
that inspection did not execute CUDA. Wayland pixel backing adds 51,200 bytes,
and the separately budgeted main stack remains as described above.

The implementation received a local standards/spec self-review; no independent
sub-agent review was available. Review fixes included native decoder-state
retention, fail-closed GPU initialization, driver-aware linking and preserving
Nix-path provisioning. **NVIDIA execution, a physical microphone, target-desktop
focus/click-through and recognition quality/latency remain pending milestone 09.**
This historical milestone-02 evidence does not cover streaming (04), asynchronous
restart (05), broader recovery (07) or reactive UI (08). Milestone 03 installation evidence is recorded in the
[installation guide](installation.md).

The milestone records describe their original builds. Their former
`backend-required` checks and custom Whisper library are historical; the current
policy permits upstream CPU fallback with a warning and uses nixpkgs packaging.

### Recorded milestone-04 verification

Executed on **aarch64-linux**, retaining **Zig 0.17.1**:

- The first streaming regression failed against the short-reply implementation
  (`decode_count`: expected 1 during recording, found 0). Pause/context and sizing
  cases were then added through red/green cycles at the same public seam.
  All **19 standard tests** pass, directly and through `zig build test`, including
  a simulated 130 seconds of recording, ordered joins, a short trailing window,
  stop during background decoding, repeated words, exact/overflowing text and
  backlog capacity, late completion after failure and immutable borrowed PCM.
- ReleaseSafe development and installed default CUDA/CPU builds passed, including
  the same standard suite in package `checkPhase`. Zig/Nix formatting passed.
- Separate `module-config`, `sizing`, `native-smoke`, `capture-inference`,
  `model-failure` and `backend-required` consumers passed. All twelve sizing inputs
  reached installed binaries, including non-default streaming settings.
- The new `streaming` consumer **actually ran real CPU tiny.en recognition** with
  native PipeWire capture and Wayland publication. In each of two sessions, a
  ten-second window completed while capture remained open and the previous
  clipboard stayed intact; a further window was decoded during finalization,
  followed by one complete publication. This is not sustained target-GPU or
  comprehensive boundary-quality acceptance.
- `session-vm-tcg` **actually executed successfully**, about **615 seconds**:
  installed user service, environment gating, model loading, virtual microphone,
  native indicator/clipboard and teardown. Its explicitly substituted decoder
  remains test-only; expected output now accounts for one result per decoded
  window. This is session integration, not speech recognition. The KVM variant
  was not executed: this host has no `/dev/kvm`.
- Source/lifetime and undefined-symbol review found no new application allocator
  path. The audio ring, prompt, decoder result and short-tail padding are typed
  static fields, including error/unwind paths. Native whisper prompt tokenization
  and other genuine dependency allocations remain exempt. No RSS-based proof is
  claimed. The conservative main-thread stack budget remains 16 KiB.
- Standards/spec self-review used parent **`86fbdbc9`**; no blocking findings
  remain. No independent sub-agent reviewer was available. Cleanup is deferred;
  no C-adapter migration, compiler-pin change or automatic flake/CI check was added.

Measured installed layouts (bytes, alignment 65,536):

| Component | Default CPU sizing | Installation example sizing |
| --- | ---: | ---: |
| Whole `Storage` | 19,529,728 | 12,517,376 |
| Session windows, transcript and metadata | 6,808,704 | 10,244,248 |
| Worker, including stack, prompt and padding | 9,502,720 | 2,228,224 |

These totals already include padding/alignment and the worker stack. Typed layout
can absorb new fields into existing alignment padding; do not sum rounded
component totals as a substitute for the whole `Storage` measurement. Wayland
pixel backing remains separately 51,200 bytes. Physical microphone, NVIDIA,
boundary quality/latency and target-desktop acceptance remain milestone 09.

### Recorded milestone-05 verification

Executed on **aarch64-linux** with **Zig 0.17.1**:

- The initial restart test failed against `4c9b411a`: capture was still closed
  after toggling during finalization. The same public seam now passes **23
  standard tests**, including replacement capture before old completion, immutable
  borrowed PCM, 20 restarts with pending chunks, out-of-order/duplicate successes
  and failures, clearing old prompt context, default/non-default capacities,
  delayed-cancellation backlog exhaustion and replacement dependency failures.
  No timers, GPU, model loading, audio server or desktop are used by these tests.
- Direct tests, `zig build test`, ReleaseSafe development compilation, Zig/Nix
  formatting, and installed default CUDA/CPU package builds passed. Native package
  `checkPhase` still runs only the standard Zig suite. No compiler pin changed.
- Separate `module-config`, `sizing`, `native-smoke`, `capture-inference`,
  `streaming`, `model-failure`, `backend-required` and **`restart`** consumers passed.
  Real CPU recognition and multi-window streaming were executed independently of
  the restart adapter. The restart consumer actually observed the abort callback,
  held the old operation through replacement capture, verified its retained PCM,
  then decoded two replacement windows and published only their joined result.
  It uses the explicitly substituted decoder described above, not real GPU work.
- The installed-session **TCG VM actually passed**, about **610 seconds**, with
  its explicitly adapted decoder and real model loading, capture, Wayland and
  service lifecycle. KVM and physical target-desktop/NVIDIA tests were not run.
  The final aggregate reused these successfully executed consumer outputs; it
  did not represent cache reuse as additional executions.
- Allocation/lifetime review covered cancellation, matching/stale completions,
  repeated queue retirement, replacement failures and shutdown. The new checked
  arithmetic, two-scalar `std.meta.eql`, identity copies and atomics do not
  allocate. No application allocator import/symbol was found; native-library
  internals remain exempt. Thread creation still supplies the fixed worker stack.
  The separately budgeted main-thread stack remains 16 KiB, not compiler-certified.

Measured installed layouts (bytes, alignment 65,536):

| Component | Default CPU sizing | Installation example sizing |
| --- | ---: | ---: |
| Whole `Storage` | 19,529,728 | 12,517,376 |
| Session, including identities and retained borrow | 6,808,744 | 10,244,288 |
| Worker, including cancellation identity/flag and stack | 9,502,720 | 2,228,224 |
| Replacement windows while one old borrow remains | 2 | 3 |

New bookkeeping consumes previously counted alignment padding, leaving these
whole-program totals unchanged; it is not omitted from the layout. The small
installed sizing consumer also verifies exactly one replacement window alongside
one retained borrow. Existing minimum-two-slot and overflow checks remain active.
Wayland pixel backing stays separately 51,200 bytes.

#### Standards self-review

Reviewed against **`4c9b411a`**, the contribution/storage/testing policies and code
smell baseline. No blocking findings remain. Production C adapters and dependency
pins are unchanged; the existing **test-only** C interposer was extended, not
shipped or used to hide application storage. Cleanup remains deferred to 10.

#### Spec self-review

Ticket 05's restart, cancellation, ownership, bounded capacity, stale-event and
privacy requirements are implemented and exercised through the public seam.
No blocking findings remain. Real GPU preemption timing, physical-desktop restart
latency and broader failure recovery are not claimed: they remain 09 and 07.
Both reviews were local self-reviews; no independent sub-agent tool was available.

### Recorded nixpkgs Whisper migration verification

Executed on **aarch64-linux**, retaining **Zig 0.17.1**, CUDA 12.9 and architecture
86; this supersedes the former GPU fail-closed policy:

- Default CUDA and explicit CPU packages built; their standard **23 tests** passed.
  Regenerated development bindings, formatting checks, `zig build test` and the
  ReleaseSafe development build also passed.
- Separate `backend-fallback`, `capture-inference`, `streaming`, `restart`,
  `model-failure`, `native-smoke`, `module-config` and `sizing` consumers passed.
  The fallback consumer requested GPU use with the real CPU library, observed the
  fixed warning and readiness diagnostic, then recognized actual virtual-microphone
  speech without logging its text. Restart still uses an explicit test-only decoder.
- The actual installed-session **TCG VM passed** (about **620 seconds**) with real
  model loading and explicitly substituted decode. This is session integration
  evidence, not CUDA execution or recognition-quality evidence.
- An initial aggregate build exhausted this host's memory in upstream llama.cpp's
  web-UI build. Building the already evaluated CUDA derivation in isolation with
  one job/core succeeded without changing dependency packaging; CPU/VM checks ran
  separately afterward. Final aggregates reused successful outputs.
- Allocation/lifetime and standards/spec **self-review** found no new application
  allocation or storage: backend loading is genuine dependency initialization;
  logging only examines borrowed messages and writes fixed literals. Its worker
  userdata remains statically allocated, and backend preference is immutable after
  thread creation. Default static storage remains **19,529,728 bytes**. There was
  no independent reviewer available.

No NVIDIA hardware, physical microphone, target-desktop quality or latency claim
is made. Those acceptance checks remain milestone 09.

### Recorded milestone-06 verification

Executed on **aarch64-linux** with **Zig 0.17.1**:

- All **28 standard Zig tests** passed directly and through `zig build test`,
  including the production clipboard server behind controlled protocol/pipe I/O.
  Public-session tests cover concurrent short reads through recording/background
  inference/finalization, unmixed old/new text, external takeover, publication
  failures, exact capacity, source/transfer exhaustion, interruption/disconnect,
  expiry at the deadline, shutdown and repeated reuse. A focused I/O test checks
  the configured full transcript capacity and per-turn write budget. Fast tests
  use no desktop, audio server, model, GPU, network or sleeps.
- ReleaseSafe development compilation and Zig/Nix formatting passed. Installed
  default CUDA and CPU packages (default, installation example, small and
  integration sizing) ran the same 28 tests in the unchanged
  standard-runner-only `checkPhase`. Building CUDA did not execute NVIDIA inference.
- Separate `module-config`, `sizing`, `native-smoke`, `capture-inference`,
  `streaming`, `restart` and **`clipboard`** checks actually passed. Real CPU
  recognition was executed independently of the explicitly substituted decoders
  in restart/clipboard tests. The clipboard consumer passed twice, with the
  second run additionally asserting exact-capacity results: five sessions each
  produced two 128 KiB chunks; one publication was safely rejected while an old
  reader pinned the only spare source slot. Later publication succeeded after
  cleanup. Real readers verified complete old/new bytes, external takeover,
  rejected excess requests/unsupported sinks, disconnected/stalled readers,
  timeout and reuse. The initial test harness needed `pw-cat --raw` for its raw
  PCM input; no production fallback or weakened assertion was used.
- Allocation/lifetime and undefined-symbol review found no application allocator
  path. Serving uses typed arrays, slices, bounded scalar state and direct
  syscalls; native source/proxy allocation remains inside genuine libwayland.
  Clipboard callbacks carry the stable Desktop pointer, not an additional copy
  of application data. The fixed `stat` syscall scratch stays within the existing
  conservative **16 KiB** main-stack budget; Wayland pixel backing is unchanged
  at **51,200 bytes**, separately mapped/unmapped, never used for transcripts.

Measured installed layouts (bytes; whole storage aligned to 65,536):

| Component | Default CPU sizing | Small sizing | Clipboard integration sizing |
| --- | ---: | ---: | ---: |
| Whole `Storage` | 19,529,728 | 1,179,648 | 10,092,544 |
| Clipboard aggregate | 3,146,056 | 208 | 524,448 |
| Offer table, including text and metadata | 3,145,800 | 176 | 524,352 |
| Transfer table | 256 | 32 | 96 |
| Wayland aggregate, including clipboard | 3,146,216 | 368 | 524,608 |

Existing `transcriptBytes`, `clipboardSlots` and `transfers` settings still feed
both package and module; no new sizing knob, hidden reserve, queue, growing copy
or application heap was added. The whole-program total includes the clipboard
subcomponents above and padding; they are not additional memory totals.

Standards/spec **self-review** against parent `b665852e` found no blocking issues;
no independent reviewer was available. Only test-side C helpers/interposition
were extended: production C glue, dependency/compiler pins and the session state
machine were not migrated or cleaned up. The NixOS VM was not rerun for 06.
Physical-desktop focus/latency, real microphone, sustained target-GPU throughput
and recognition quality remain **09**; broader recovery is **07**, reactive
multi-monitor feedback **08**, and cleanup **10** last.

### Recorded milestone-07 verification

Executed on **aarch64-linux**, retaining **Zig 0.17.1**:

- The initial recovery regression failed against parent `dcd41b95`: retry left
  capture closed until failed inference returned. All **32 standard Zig tests**
  now pass directly and through `zig build test`. Coverage includes pauses and
  silent/empty chunks within speech, immediate retry with a retained borrow,
  repeated failure/recovery in two audio slots, same-device stale PCM/errors,
  stale successes/failures after replacement publication, and clean prompt context.
  Existing loading, dependency, capacity, clipboard and restart cases still pass.
- ReleaseSafe development compilation, Zig/Nix formatting and installed CPU and
  default CUDA package builds passed, including the same 32 tests in `checkPhase`.
  Building CUDA did not execute NVIDIA inference. Package `checkPhase` still runs
  only the standard Zig suite; no source audit, script, native consumer or
  dependency download was added there.
- All three new **`recovery-pipewire`**, **`recovery-wayland`** and
  **`recovery-capacity`** consumers actually passed, including a second full run.
  Real PipeWire/Wayland and model loading, explicitly substituted decode:
  pinned-source removal during a held call, immediate retry before old PCM is
  released, three silence/empty/inference-error/missing-default recovery cycles,
  four device remove/add cycles, then fatal connection or table exhaustion.
  Native teardown and missing-dependency startup returned failure, never fixture
  output; external clipboard ownership survived daemon loss where Wayland survived.
  The first harness run exposed a test-fixture issue: re-setting an unchanged
  configured default does not undo a direct metadata override. The test now
  explicitly restores the metadata it changed; no production fallback was added.
- Separate **`capture-inference`**, **`streaming`**, **`restart`**, **`clipboard`**,
  **`native-smoke`**, **`model-failure`**, **`module-config`** and **`sizing`** passed.
  Real CPU recognition was executed independently of adapted recovery/restart/
  clipboard decoding. These are actual consumer executions, not merely evaluated
  attributes. Module evaluation also verifies the existing on-failure/two-second
  restart policy; adding these evaluation assertions reused the already executed
  module consumer output, not another execution. The NixOS VM, GPU fallback
  consumer and target hardware were not rerun for this slice; prior results are
  not represented as new executions.
- Allocation/lifetime and undefined-symbol review found no new application
  allocator path. Capture identities, stream/connection error slots and session
  state remain typed static fields. Pinned PipeWire 1.6.9 `stream.c` confirms that
  destruction disconnects, cleans listeners and clears queued invokes before
  freeing the stream; identity reuse occurs only afterward, outside the process
  callback. Zig 0.17.1 scalar `std.meta.eql`, fixed `std.mem.print`, integer parsing,
  slices and error names introduce no application heap. Diagnostics never forward
  captured/recognized text. Native libraries and Wayland backing remain exempt.

Installed layout measurements (bytes; whole storage aligned to 65,536):

| Component | Default CPU sizing | Small sizing | Recovery sizing |
| --- | ---: | ---: | ---: |
| Whole `Storage` | 19,529,728 | 1,179,648 | 13,959,168 |
| Session | 6,808,752 | 1,496 | 1,304,776 |
| Capture state | 10,312 | 2,152 | 2,152 |

Capture now holds a tagged identity instead of a source plus a pending removal
record; bounded error slots replace failure booleans. The session also retains
its active capture identity. The aggregate accounts for both copies and padding;
no new sizing input, queue, reserve or silence-analysis workspace was introduced.
The conservative separate main-stack budget remains **16 KiB**, not compiler-
certified. Reused Wayland backing remains separately **51,200 bytes**.

Standards/spec **self-review** against `dcd41b95` found no blocking issues; no
independent reviewer was available. Production C glue and dependency/compiler pins
are unchanged; only the existing test interposer gained empty/error outcomes.
Physical microphone, sustained CUDA performance, recognition quality and desktop
appearance remain **09**. Reactive multi-monitor feedback is next (**08**), with
cleanup (**10**) after target validation, not folded into recovery.
