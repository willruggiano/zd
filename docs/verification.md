# Local verification evidence

These are historical reports of checks actually run, not instructions or a claim
that every consumer has passed on the current revision. Preserve the distinction
between execution, evaluation, cache reuse and hardware acceptance. Old backend
policies, storage totals and scheduling notes describe their original milestones.

For commands and substitutions, use the [test catalog](testing.md). Current
contracts live in the [design](design.md), [ADRs](adr/) and
[runtime reference](runtime.md); physical-desktop results belong only in
[target validation](validation.md#results).

## Reports

- [Zig research and devshell](#zig-research-and-devshell-verification)
- [08: multi-monitor feedback](#recorded-milestone-08-verification)
- [07: recovery](#recorded-milestone-07-verification)
- [06: clipboard serving](#recorded-milestone-06-verification)
- [nixpkgs Whisper migration](#recorded-nixpkgs-whisper-migration-verification)
- [05: restart](#recorded-milestone-05-verification)
- [04: streaming](#recorded-milestone-04-verification)
- [03: installed session](#recorded-milestone-03-verification)
- [02: native capture/inference](#recorded-milestone-02-verification)

## Zig research and devshell verification

For this research/devshell change, executed on aarch64-linux with Zig 0.17.1:

- Entered the shell and checked the exact welcome text, standard-library and
  language-reference files, and existing generated bindings.
- `zig std --help` succeeded; the local documentation server was not launched.
- `nixfmt --check flake.nix nix/*.nix` and
  `zig fmt --check build.zig src/*.zig` passed.
- `zig test src/tests.zig`: **38 tests passed**.
- Four standalone exploratory Zig tests passed for bounded lists, fixed
  formatting, `errdefer` rollback and 0.17 backing integers/static bit sets.
  These were API experiments, not additions to the package's fast checks.
- Both supported devshells evaluated and their generated hooks passed `bash -n`.
  Only aarch64-linux was entered/executed; x86_64-linux was evaluation only.

No production Zig/native implementation was changed; installed consumers and
hardware tests were not rerun.

## Recorded milestone-02 verification

Executed on **aarch64-linux**, using Zig **0.17.1**:

- All **12 standard Zig tests** passed directly and through `zig build test`;
  the development ReleaseSafe build and Zig/Nix formatting checks passed.
- Installed default CUDA/large-v3-turbo and CPU/tiny.en packages built, as did
  the small and deliberately GPU-required/CPU-library configurations. Their
  `checkPhase` ran the same twelve tests. Both pinned model downloads succeeded.
- All five then-current named checks passed: fixture desktop, real capture/inference,
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
and the separately budgeted main stack is described in the [storage accounting guide](runtime.md#static-storage-and-allocation-audit).

The implementation received a local standards/spec self-review; no independent
sub-agent review was available. Review fixes included native decoder-state
retention, fail-closed GPU initialization, driver-aware linking and preserving
Nix-path provisioning. **NVIDIA execution, a physical microphone, target-desktop
focus/click-through and recognition quality/latency remain pending milestone 09.**
This historical milestone-02 evidence does not cover streaming (04), asynchronous
restart (05), broader recovery (07) or reactive UI (08). Milestone 03 installation evidence is recorded in the
[milestone-03 report](#recorded-milestone-03-verification).

The milestone records describe their original builds. Their former
`backend-required` checks and custom Whisper library are historical; the current
policy permits upstream CPU fallback with a warning and uses nixpkgs packaging.

## Recorded milestone-03 verification

Executed on an **aarch64-linux** builder with Zig **0.17.1**:

- Nix/Zig formatting and both standard Zig test invocations passed: **12 tests**.
- Default/CPU package builds, `module-config`, and the five existing native/sizing
  consumers (`native-smoke`, `capture-inference`, `model-failure`,
  `backend-required`, `sizing`) succeeded. Unchanged native derivations reused
  their successful build results; their real CPU recognition evidence is recorded
  in [milestone-02 report](#recorded-milestone-02-verification).
- **`session-vm-tcg` executed successfully**, not merely evaluated. Its test script
  took about 640 seconds without `/dev/kvm`. It verified the installed executable
  running as UID 1000, environment skip/import, missing model and default-source
  refusal, all configured sizing values, real virtual-input capture, visible
  indicator pixels, final-only native clipboard delivery of the adapter's fixed
  text, and clean session shutdown releasing capture, clipboard and control.
  The result includes `screenshots/recording.png`.
- The KVM `session-vm` derivation was successfully created, but **not executed**
  here because `/dev/kvm` is unavailable. An earlier real-decoding TCG attempt did
  not finish within 600 seconds; it is not successful VM recognition evidence.
  The checked-in VM explicitly uses the [VM decoder adapter](testing.md#installed-session-vms).

Self-review against milestone 02 covered standards/allocation and ticket-03
acceptance separately, with no remaining ticket-03 findings. No independent
reviewer was available. Physical microphone, NVIDIA execution and target-desktop
quality/latency/focus/click-through validation remain milestone 09.

### Runtime allocation review

This slice changes no production Zig or C runtime code. The test-only decoder
interposer is outside the package fileset and has no production linkage. The unit
executes the existing
`dictation daemon` entry point directly, without a shell wrapper, new runtime
arguments, a configuration-file parser or an environment-based sizing path.
Model paths and capacities still become build-time `src/options.zig` constants;
the built program computes and reports its actual `Storage` layout. The existing
startup, toggle, signal/shutdown, native ownership and allocation findings in
[runtime.md](runtime.md#static-storage-and-allocation-audit) still apply. Nix,
systemd and test-driver allocations are not application storage hidden behind a
runtime shim. This review is separate from the standard Zig test suite.

## Recorded milestone-04 verification

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

## Recorded milestone-05 verification

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
  It uses the [explicitly substituted decoder](testing.md#native-consumers), not real GPU work.
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

### Standards self-review

Reviewed against **`4c9b411a`**, the contribution/storage/testing policies and code
smell baseline. No blocking findings remain. Production C adapters and dependency
pins are unchanged; the existing **test-only** C interposer was extended, not
shipped or used to hide application storage. Cleanup remains deferred to 10.

### Spec self-review

Ticket 05's restart, cancellation, ownership, bounded capacity, stale-event and
privacy requirements are implemented and exercised through the public seam.
No blocking findings remain. Real GPU preemption timing, physical-desktop restart
latency and broader failure recovery are not claimed: they remain 09 and 07.
Both reviews were local self-reviews; no independent sub-agent tool was available.

## Recorded nixpkgs Whisper migration verification

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

## Recorded milestone-06 verification

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

## Recorded milestone-07 verification

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
This did not establish physical-microphone behavior, sustained CUDA performance,
recognition quality or desktop appearance.

## Recorded milestone-08 verification

Executed on **aarch64-linux**, retaining **Zig 0.17.1**:

- The initial volume regression failed with expected level 1, observed 0; the
  native multi-output regression found only one layer surface. All **38 standard
  Zig tests** now pass directly and through `zig build test`. Public session and
  feedback tests cover real PCM-to-level handling, silence/stale capture, phases,
  deadline replacement, background decoding/restart, output add/remove/change,
  backpressure/coalescing, exact capacity/reuse and invalid/overflowing sizing.
- ReleaseSafe development compilation and Zig/Nix formatting passed. Installed
  default CUDA and CPU packages, including one/two/three/eight-output sizing,
  passed the same 38 tests in their unchanged standard-runner-only `checkPhase`.
  CUDA package construction/footprint inspection did **not** execute NVIDIA work.
- Separate **`indicator`**, **`native-smoke`**, **`capture-inference`**,
  **`recovery-wayland`**, **`module-config`** and **`sizing`** consumers actually
  passed. Real CPU recognition remains independently exercised by
  `capture-inference`; fixture smoke and adapted recovery retain their explicitly
  documented substitutions. The NixOS session VM and the other earlier consumers
  were **not rerun** for this slice.
- The final `indicator` consumer passed repeatedly with real model loading,
  PipeWire and two headless Sway outputs. Screenshots observed bars responding to
  synthetic 440 Hz PCM on both outputs, settling after silence, and correct
  placement after mode/2× scale changes. Five disable/enable cycles reclaimed
  client mappings/descriptors, restored current recording feedback and preserved
  the clipboard. A third output produced `OutputCapacity` and ordered failure.
  Protocol traces verify explicit output binding, empty input regions, keyboard
  interactivity NONE and output `release` requests. Source selection/readiness
  is asserted before feeding PCM; the harness does not rely on policy timing.
- Allocation/source and undefined-symbol self-review covered new callback,
  rendering, timer, init/error and teardown paths. No application allocator path
  was found. RMS uses a scalar accumulator and compiler square-root intrinsic;
  rendering uses scalar loops over the permitted backing. Both logical and native
  output tables are typed fields in `Storage`, not a heap hidden behind bindings.
  The separate conservative main-stack budget remains **16 KiB**.

Installed layouts (bytes; whole storage aligned to 65,536):

| Component | Default CPU/CUDA | Small sizing | Installation example |
| --- | ---: | ---: | ---: |
| Whole `Storage` | 19,529,728 | 1,179,648 | 12,517,376 |
| Native monitor records | 704 | 88 | 264 |
| Logical feedback/volume/timer state | 88 | 32 | 48 |
| Whole Wayland aggregate | 3,146,936 | 416 | 8,704 |
| Output capacity | 8 | 1 | 3 |
| Maximum separate pixel backing | 1,638,400 | 204,800 | 614,400 |

New records consume already-accounted aggregate alignment padding, so whole
static totals remain unchanged. The monitor/feedback columns are included in the
Wayland and whole totals, not additional amounts. Actual mapping size depends
on active outputs; it is separate from static application storage.

### Standards self-review

Reviewed against preserved parent **`cc38c824`**, the contribution/domain/storage/
testing rules and code-smell baseline. No blocking findings remain. Review fixed
initial callback errors being masked by missing-protocol checks, added v3 output
release, and avoided sending a v3 shell-destroy request on the bound v1 shell.
Native binding/compiler dependencies and production C glue remain unchanged.
No independent sub-agent reviewer was available.

### Spec self-review

Ticket 08's reactive per-output feedback, stale-event handling, bounded storage,
release lifecycle, configuration and separate native checks are implemented.
The fixed 2× raster delegates other scales to the compositor rather than adding
resize pools/queues. No blocking local findings remain; physical appearance,
keyboard focus, pointer delivery and mixed-scale hardware acceptance were not
established by protocol traces/screenshots. The
[target validation checklist](validation.md) owns acceptance status. This was a
local self-review, not an independent or target-desktop acceptance review.
