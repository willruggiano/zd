# Local verification evidence

These historical reports record past checks. They do not certify every consumer
on the current revision. Distinguish execution, evaluation, cache reuse and
hardware acceptance. Old backend policies, storage totals and scheduling notes
describe their original milestones.

Use the [test catalog](testing.md) for commands and substitutions.
The [design](design.md), [ADRs](adr/) and [runtime reference](runtime.md) define
current contracts. [Target validation](validation.md#results) records
physical-desktop results.

## Reports

- [Wayland binding migration](#wayland-binding-migration)
- [Zig research and devshell](#zig-research-and-devshell-verification)
- [08: multi-monitor feedback](#recorded-milestone-08-verification)
- [07: recovery](#recorded-milestone-07-verification)
- [06: clipboard serving](#recorded-milestone-06-verification)
- [nixpkgs Whisper migration](#recorded-nixpkgs-whisper-migration-verification)
- [05: restart](#recorded-milestone-05-verification)
- [04: streaming](#recorded-milestone-04-verification)
- [03: installed session](#recorded-milestone-03-verification)
- [02: native capture/inference](#recorded-milestone-02-verification)

## Wayland binding migration

These checks used Zig 0.17.1 on aarch64-linux, before the separate PipeWire wrapper cleanup.
The [binding decision](adr/0005-generated-zig-wayland-bindings.md) records the selected approach.

- The pinned `zig-wayland` generator built and processed all required protocol XML files.
  The package and development shell used the same generated output.
- Separate probes compiled protocol requests, typed listeners and translated logging callbacks for aarch64-linux and x86_64-linux.
  Neither probe exercised a desktop. The x86_64 result was compilation only, not a native package build or execution.
- The ReleaseSafe development build passed. All 38 standard Zig tests passed.
- Separate `native-smoke`, `indicator`, `clipboard`, `recovery-wayland`, `sizing` and `module-config` consumers passed.
  These consumers executed; their results were not only derivation evaluations.
  Native package `checkPhase` also ran the 38 Zig tests.
- `native-smoke` used fixture audio and inference.
  `clipboard` and `recovery-wayland` substituted decoding while keeping capture, model loading and Wayland real.
  `indicator` used synthetic PCM and headless Sway. It checked pixels, output capacity, repeated output changes and backing release.
- Source review traced generated requests and dispatchers through libwayland.
  Arguments and event payloads use bounded stack values. Listener userdata borrows records in `Storage`.
  Native proxy allocation remains inside libwayland. Wayland pixel backing remains the separate permitted mapping resource.
  The executable had no undefined `malloc`, `calloc` or `realloc` symbol; source review supplied the allocation evidence.
- Default development `static_bytes` remained 19,529,728 with alignment 65,536.
  The sizing consumer also checked non-default storage.
- The x86_64 CPU package and development hook evaluated successfully. The hook passed `bash -n` without execution.
- Zig/Nix formatting and separate documentation link, anchor and fence checks passed.

These checks did not run the session VM, CUDA, or physical-desktop acceptance.

## Zig research and devshell verification

These research and devshell checks ran on aarch64-linux with Zig 0.17.1:

- Shell entry succeeded. Inspection found the expected welcome text,
  standard-library files, language-reference files and existing generated bindings.
- `zig std --help` succeeded. This check did not start the local documentation server.
- `nixfmt --check flake.nix nix/*.nix` and
  `zig fmt --check build.zig src/*.zig` passed.
- `zig test src/tests.zig`: **38 tests passed**.
- Four separate Zig experiments passed. They tested bounded lists, fixed
  formatting, `errdefer` rollback and 0.17 backing integers with static bit sets.
  These API experiments did not add package fast checks.
- Evaluation succeeded for both supported devshells.
  Their generated hooks passed `bash -n`.
  Shell entry and execution occurred only on aarch64-linux.
  The x86_64-linux result was evaluation only.

This work did not change production Zig or native implementation code.
It did not rerun installed consumers or hardware tests.

## Recorded milestone-02 verification

These checks ran on **aarch64-linux** with Zig **0.17.1**:

- All **12 standard Zig tests** passed directly and through `zig build test`.
  The development ReleaseSafe build and Zig and Nix formatting checks passed.
- Installed default CUDA/large-v3-turbo and CPU/tiny.en packages built.
  Small sizing and deliberate GPU-required/CPU-library configurations also built.
  Their `checkPhase` ran the same twelve tests.
  Both pinned model downloads succeeded.
- All five named checks at that milestone passed: fixture desktop, real capture
  and inference, missing-model refusal, required-backend refusal, and sizing.
  Real recognition also passed after a change to release native state after each
  decode while retaining model weights.
- Model-path evaluation showed that a Nix path becomes a store dependency.
  Absolute strings remained host paths.
  The standard suite covered invalid and overflowing sizing.
  A separate check showed correct installed non-default sizing.
- Source and undefined-symbol review found no application allocator path.
  The storage guarantee did not apply to internal native dependency allocations.
  This was not a process-wide no-allocation result.
  An x86_64-target semantic compile also passed.
  It did **not** link a native x86_64 package or execute a wrapper test.

Milestone-02 installed CPU layouts, **before streaming**.
Values are bytes. Whole storage alignment is 65,536.

| Component | Default sizing | Small test sizing |
| --- | ---: | ---: |
| Whole `Storage` | 15,663,104 | 1,179,648 |
| Session | 2,968,616 | 744 |
| Wayland state | 3,146,240 | 384 |
| Capture state | 10,320 | 2,160 |
| Worker, including stack | 9,502,720 | 1,114,112 |

At milestone 02, the CUDA executable's `main.storage` ELF symbol measured
15,663,104 bytes. That inspection did not execute CUDA.
Wayland pixel backing added a separate 51,200 bytes.
The [storage accounting guide](runtime.md#static-storage-and-allocation-audit)
describes the separate main-stack budget.

Local self-review covered standards and the spec. No independent sub-agent
review was available. Review fixes addressed native decoder-state retention,
fail-closed GPU initialization, driver-aware linking and Nix-path provisioning.
**NVIDIA execution, physical-microphone use, desktop focus, click-through behavior,
and recognition quality and latency remained pending under milestone 09.**

This milestone-02 evidence did not cover streaming (04), asynchronous restart
(05), broader recovery (07) or reactive UI (08).
See the [milestone-03 report](#recorded-milestone-03-verification) for installation evidence.
The former `backend-required` checks and custom Whisper library describe historical builds.
The current policy permits upstream CPU fallback with a warning and uses nixpkgs packaging.

## Recorded milestone-03 verification

These checks used an **aarch64-linux** builder with Zig **0.17.1**:

- Nix and Zig formatting passed.
  Both standard Zig test commands passed **12 tests**.
- Default and CPU package builds succeeded.
  `module-config` and the five existing native and sizing consumers also succeeded:
  `native-smoke`, `capture-inference`, `model-failure`, `backend-required` and `sizing`.
  Unchanged native derivations reused their successful build results.
  Their real CPU recognition evidence is in the
  [milestone-02 report](#recorded-milestone-02-verification).
- **`session-vm-tcg` executed successfully**. This was not only evaluation.
  Its script took approximately 640 seconds without `/dev/kvm`.
  It showed these results:
  - The installed executable ran as UID 1000.
  - Missing environment skipped startup, and an environment import permitted it.
  - Missing models and missing default sources caused refusal.
  - All configured sizing values reached the executable.
  - Real virtual-input capture and visible indicator pixels worked.
  - Native clipboard delivery contained only the adapter's fixed final text.
  - Session shutdown released capture, clipboard and control resources.

  The result includes `screenshots/recording.png`.
- Evaluation created the KVM `session-vm` derivation, but the test **did not run**.
  This host had no `/dev/kvm`.
  An earlier TCG attempt with real decoding did not finish within 600 seconds.
  That attempt was not successful VM recognition evidence.
  The checked-in VM uses the explicit [VM decoder adapter](testing.md#installed-session-vms).

Self-review against milestone 02 covered standards, allocation and ticket-03
acceptance separately. No ticket-03 findings remained.
No independent reviewer was available.
Physical-microphone, NVIDIA, desktop quality, latency, focus and click-through
validation remained under milestone 09.

### Runtime allocation review

This change did not modify production Zig or C runtime code.
The package fileset excluded the test-only decoder interposer.
Production code did not link that interposer.
The unit ran the existing `dictation daemon` entry point directly.
It added no shell wrapper, runtime arguments, configuration-file parser or
environment-based sizing.

Model paths and capacities remained build-time `src/options.zig` constants.
The program computed and reported its actual `Storage` layout.
The findings in [runtime.md](runtime.md#static-storage-and-allocation-audit) still
applied to startup, toggle, signals, shutdown, native ownership and allocation.
Nix, systemd and test-driver allocations did not hide application storage behind
a runtime wrapper. This review was separate from the standard Zig test suite.

## Recorded milestone-04 verification

These checks ran on **aarch64-linux** with **Zig 0.17.1**:

- The first streaming regression failed against the short-reply implementation.
  During recording, `decode_count` was 0 instead of the expected 1.
  Pause, context and sizing cases then followed the same fail-then-pass process
  through the public interface.
  All **19 standard tests** passed directly and through `zig build test`.
  Coverage included:
  - A simulated 130 seconds of recording, ordered joins and a short trailing window.
  - Stop during background decoding and repeated words.
  - Exact and overflowing text and backlog capacity.
  - Late completion after failure and immutable borrowed PCM.
- ReleaseSafe development and installed default CUDA and CPU builds passed.
  Package `checkPhase` ran the same standard suite.
  Zig and Nix formatting passed.
- Separate `module-config`, `sizing`, `native-smoke`, `capture-inference`,
  `model-failure` and `backend-required` consumers passed.
  All twelve sizing inputs reached installed binaries, including non-default streaming settings.
- The new `streaming` consumer **ran real CPU tiny.en recognition**.
  It used native PipeWire capture and Wayland publication.
  Two sessions each completed a ten-second window while capture stayed open and
  the previous clipboard stayed intact.
  During finalization, inference decoded another window before one complete publication.
  This did not establish sustained target-GPU operation or complete boundary-quality acceptance.
- `session-vm-tcg` **executed successfully** in approximately **615 seconds**.
  It tested the installed user service, environment gating, model loading,
  virtual microphone, native indicator, clipboard and teardown.
  Its substituted decoder remained test-only.
  Expected output accounted for one result per decoded window.
  This was session integration evidence, not speech recognition.
  The KVM variant did not run because this host had no `/dev/kvm`.
- Source, lifetime and undefined-symbol review found no new application allocator path.
  Typed static fields held the audio ring, prompt, decoder result and short-tail padding.
  Error and unwind paths used those same fields.
  The guarantee did not apply to native Whisper prompt tokenization or other internal dependency allocations. The review did not use RSS as proof.
  The conservative main-thread stack budget remained 16 KiB.
- Standards and spec self-review used parent **`86fbdbc9`**.
  No blocking findings remained. No independent sub-agent reviewer was available.
  The work deferred cleanup.
  It added no C-adapter migration, compiler-pin change or automatic flake or CI check.

Measured installed layouts in bytes. Whole storage alignment is 65,536.

| Component | Default CPU sizing | Installation example sizing |
| --- | ---: | ---: |
| Whole `Storage` | 19,529,728 | 12,517,376 |
| Session windows, transcript and metadata | 6,808,704 | 10,244,248 |
| Worker, including stack, prompt and padding | 9,502,720 | 2,228,224 |

These totals included padding, alignment and the worker stack.
New fields can fit inside existing alignment padding.
Thus, a sum of rounded component totals cannot replace the whole `Storage` measurement.
Wayland pixel backing remained a separate 51,200 bytes.
Physical-microphone, NVIDIA, boundary quality, latency and target-desktop acceptance
remained under milestone 09.

## Recorded milestone-05 verification

These checks ran on **aarch64-linux** with **Zig 0.17.1**:

- The initial restart test failed against `4c9b411a`.
  A toggle during finalization left capture closed.
  After the change, the same public interface passed **23 standard tests**.
  These tests used no timers, GPU, model loading, audio server or desktop.
  They covered:
  - Replacement capture before old completion and immutable borrowed PCM.
  - 20 restarts with pending chunks.
  - Out-of-order and duplicate successes and failures.
  - Removal of old prompt context and default and non-default capacities.
  - Backlog exhaustion during delayed cancellation and replacement dependency failures.
- Direct tests, `zig build test`, ReleaseSafe development compilation and Zig
  and Nix formatting passed. Installed default CUDA and CPU package builds passed.
  Native package `checkPhase` still ran only the standard Zig suite.
  The compiler pin did not change.
- Separate `module-config`, `sizing`, `native-smoke`, `capture-inference`,
  `streaming`, `model-failure`, `backend-required` and **`restart`** consumers passed.
  Real CPU recognition and multi-window streaming ran independently of the restart adapter.
  The restart consumer observed the abort callback.
  It held the old operation through replacement capture and showed that the borrowed PCM stayed unchanged.
  It then decoded two replacement windows and published only their joined result.
  It used the [explicitly substituted decoder](testing.md#native-consumers), not real GPU work.
- The installed-session **TCG VM passed** in approximately **610 seconds**.
  It used its adapted decoder with real model loading, capture, Wayland and service lifecycle.
  This work did not run KVM or physical target-desktop or NVIDIA tests.
  The final aggregate reused successful consumer outputs.
  This report does not count cache reuse as additional execution.
- Allocation and lifetime review covered cancellation, matching and stale
  completions, repeated queue retirement, replacement failures and shutdown.
  Checked arithmetic, two-scalar `std.meta.eql`, identity copies and atomics did not allocate.
  The review found no application allocator import or symbol.
  The guarantee did not apply to native-library internals.
  Thread creation still used the supplied fixed worker stack.
  The separate main-thread stack budget remained 16 KiB, without compiler certification.

Measured installed layouts in bytes. Whole storage alignment is 65,536.

| Component | Default CPU sizing | Installation example sizing |
| --- | ---: | ---: |
| Whole `Storage` | 19,529,728 | 12,517,376 |
| Session, including identities and retained borrow | 6,808,744 | 10,244,288 |
| Worker, including cancellation identity/flag and stack | 9,502,720 | 2,228,224 |
| Replacement windows while one old borrow remains | 2 | 3 |

New records occupied previously counted alignment padding.
The whole-program totals stayed unchanged without excluding those records.
The small installed sizing consumer also showed one replacement window alongside
one retained borrow. Minimum-two-slot and overflow checks remained active.
Wayland pixel backing stayed a separate 51,200 bytes.

### Standards self-review

The review used **`4c9b411a`**, the contribution, storage and testing policies,
and the code-smell baseline. No blocking findings remained.
Production C adapters and dependency pins stayed unchanged.
The work extended the existing **test-only** C interposer.
Production did not include it or use it to hide application storage.
Cleanup remained deferred to 10.

### Spec self-review

Public-interface tests exercised ticket 05's restart, cancellation, ownership,
bounded-capacity, stale-event and privacy requirements.
No blocking findings remained.
The review did not establish real GPU preemption timing or physical-desktop restart latency.
Those checks remained under 09. Broader failure recovery remained under 07.

The two reviews were local self-reviews. No independent sub-agent tool was available.

## Recorded nixpkgs Whisper migration verification

These checks ran on **aarch64-linux** with **Zig 0.17.1**, CUDA 12.9 and architecture 86.
This migration replaced the former GPU fail-closed policy.

- Default CUDA and explicit CPU packages built.
  Their standard **23 tests** passed.
  Development binding regeneration, formatting checks, `zig build test` and the
  ReleaseSafe development build also passed.
- Separate `backend-fallback`, `capture-inference`, `streaming`, `restart`,
  `model-failure`, `native-smoke`, `module-config` and `sizing` consumers passed.
  The fallback consumer requested GPU use with the real CPU library.
  It observed the fixed warning and readiness diagnostic.
  It then recognized virtual-microphone speech without logging the text.
  Restart still used an explicit test-only decoder.
- The installed-session **TCG VM passed** in approximately **620 seconds**.
  It used real model loading and explicitly substituted decoding.
  This was session integration evidence, not CUDA execution or recognition-quality evidence.
- An initial aggregate build exhausted host memory in upstream llama.cpp's web-UI build.
  The already evaluated CUDA derivation then built separately with one job and one core.
  Dependency packaging stayed unchanged.
  CPU and VM checks ran separately afterward.
  Final aggregates reused successful outputs.
- Allocation, lifetime, standards and spec **self-review** found no new application
  allocation or storage. Backend loading initialized an external dependency.
  Logging only examined borrowed messages and wrote fixed literals.
  Worker userdata remained statically allocated.
  The backend preference stayed immutable after thread creation.
  Default static storage remained **19,529,728 bytes**.

  No independent reviewer was available.

These checks did not establish NVIDIA execution, physical-microphone behavior,
target-desktop quality or latency. That acceptance remained under milestone 09.

## Recorded milestone-06 verification

These checks ran on **aarch64-linux** with **Zig 0.17.1**:

- All **28 standard Zig tests** passed directly and through `zig build test`.
  They included the production clipboard server with controlled protocol and pipe I/O.
  Fast tests used no desktop, audio server, model, GPU, network or sleeps.
  A focused I/O test showed correct full transcript capacity and per-turn write budget behavior.
  Public-session coverage included:
  - Concurrent short reads during recording, background inference and finalization.
  - Unmixed old and new text, external takeover and publication failures.
  - Exact capacity, source exhaustion and transfer exhaustion.
  - Interruption, disconnect, expiry at the deadline, shutdown and repeated reuse.
- ReleaseSafe development compilation and Zig and Nix formatting passed.
  Installed default CUDA and CPU packages ran the same 28 tests in `checkPhase`.
  These builds included default, installation-example, small and integration sizing.
  `checkPhase` still used only the standard test runner.
  The CUDA build did not execute NVIDIA inference.
- Separate `module-config`, `sizing`, `native-smoke`, `capture-inference`,
  `streaming`, `restart` and **`clipboard`** checks passed.
  Real CPU recognition ran independently of substituted restart and clipboard decoders.
  The clipboard consumer passed twice.
  The second run also asserted exact-capacity results.

  Five sessions each produced two 128 KiB chunks.
  One publication failed safely while an old reader held the only spare source slot.
  Later publication succeeded after cleanup.

  Real readers received complete old and new bytes. They showed successful external takeover.
  They also showed rejection of excess requests and unsupported sinks,
  disconnected and stalled readers, timeout and reuse.
  The initial harness needed `pw-cat --raw` for raw PCM input.
  This correction did not add a production fallback or weaken an assertion.
- Allocation, lifetime and undefined-symbol review found no application allocator path.
  Clipboard service used typed arrays, slices, bounded scalar state and direct syscalls.
  Native source and proxy allocation stayed inside libwayland.
  Clipboard callbacks carried the stable Desktop pointer, not an extra application-data copy.
  Fixed `stat` syscall scratch stayed within the conservative **16 KiB** main-stack budget.

  Wayland pixel backing stayed at **51,200 bytes** with separate mapping and unmapping.
  It never held transcripts.

Measured installed layouts in bytes. Whole storage alignment is 65,536.

| Component | Default CPU sizing | Small sizing | Clipboard integration sizing |
| --- | ---: | ---: | ---: |
| Whole `Storage` | 19,529,728 | 1,179,648 | 10,092,544 |
| Clipboard aggregate | 3,146,056 | 208 | 524,448 |
| Offer table, including text and metadata | 3,145,800 | 176 | 524,352 |
| Transfer table | 256 | 32 | 96 |
| Wayland aggregate, including clipboard | 3,146,216 | 368 | 524,608 |

Existing `transcriptBytes`, `clipboardSlots` and `transfers` settings still configured
both package and module. The work added no sizing input, hidden reserve, queue,
growing copy or application heap.
The whole-program total included the clipboard subcomponents and padding.
These subcomponents were not additional memory totals.

Standards and spec **self-review** against parent `b665852e` found no blocking issues.
No independent reviewer was available.
The work extended only test-side C helpers and interposition.
It did not migrate or clean up production C glue, dependency pins, compiler pins
or the session state machine. The NixOS VM did not rerun for 06.

Physical-desktop focus and latency, real-microphone behavior, sustained target-GPU
throughput and recognition quality remained under **09**.
At that milestone, the remaining plan put broader recovery in **07** and reactive
multi-monitor feedback in **08**. Cleanup **10** was last in that historical plan.

## Recorded milestone-07 verification

These checks ran on **aarch64-linux** with **Zig 0.17.1**:

- The initial recovery regression failed against parent `dcd41b95`.
  A retry left capture closed until failed inference returned.
  After the change, all **32 standard Zig tests** passed directly and through
  `zig build test`. Existing loading, dependency, capacity, clipboard and restart
  cases still passed. New coverage included:
  - Pauses and silent or empty chunks within speech.
  - Immediate retry with a retained borrow.
  - Repeated failure and recovery in two audio slots.
  - Same-device stale PCM and errors.
  - Stale successes and failures after replacement publication.
  - Clean prompt context.
- ReleaseSafe development compilation and Zig and Nix formatting passed.
  Installed CPU and default CUDA builds passed the same 32 tests in `checkPhase`.
  The CUDA build did not execute NVIDIA inference.
  Package `checkPhase` still ran only the standard Zig suite.
  It added no source audit, script, native consumer or dependency download.
- All three new consumers passed, including a second full run:
  **`recovery-pipewire`**, **`recovery-wayland`** and **`recovery-capacity`**.
  They used real PipeWire, Wayland and model loading with explicitly substituted decoding.
  They exercised these cases:
  - Pinned-source removal during a held call.
  - Immediate retry before old PCM release.
  - Three recovery cycles for silence, empty output, inference errors and missing defaults.
  - Four device removal and addition cycles.
  - Fatal connection loss or table exhaustion.

  Native teardown and missing-dependency startup returned failure, never fixture output.
  External clipboard ownership survived daemon loss when Wayland stayed available.
  The first harness run found a test-fixture problem.
  A repeated assignment of the same configured default did not undo a direct metadata override.
  The corrected test restored the metadata that it changed.
  This correction did not add a production fallback.
- Separate **`capture-inference`**, **`streaming`**, **`restart`**, **`clipboard`**,
  **`native-smoke`**, **`model-failure`**, **`module-config`** and **`sizing`** passed.
  Real CPU recognition ran independently of adapted recovery, restart and clipboard decoding.
  These were consumer executions, not only evaluated attributes.
  Module evaluation also showed the configured on-failure restart policy and two-second delay.
  Those added assertions reused the executed module consumer output.
  They did not cause another execution.

  The NixOS VM, GPU fallback consumer and target hardware did not rerun for this change.
  This report does not count prior results as new executions.
- Allocation, lifetime and undefined-symbol review found no new application allocator path.
  Capture identities, stream and connection error slots, and session state remained typed static fields.
  Pinned PipeWire 1.6.9 `stream.c` confirmed the destruction order:
  disconnect, clean listeners, clear queued invokes, then free the stream.
  Identity reuse occurred only afterward, outside the process callback.

  Zig 0.17.1 scalar `std.meta.eql`, fixed `std.mem.print`, integer parsing, slices
  and error names added no application heap.
  Diagnostics never forwarded captured or recognized text.
  The guarantee did not apply to native-library allocations or Wayland backing.

Installed layout measurements in bytes. Whole storage alignment is 65,536.

| Component | Default CPU sizing | Small sizing | Recovery sizing |
| --- | ---: | ---: | ---: |
| Whole `Storage` | 19,529,728 | 1,179,648 | 13,959,168 |
| Session | 6,808,752 | 1,496 | 1,304,776 |
| Capture state | 10,312 | 2,152 | 2,152 |

Capture held a tagged identity instead of a source and pending removal record.
Bounded error slots replaced failure booleans.
The session also retained its active capture identity.
The aggregate included both copies and padding.
The change added no sizing input, queue, reserve or silence-analysis workspace.

The conservative separate main-stack budget remained **16 KiB**, without compiler certification.
Reused Wayland backing remained a separate **51,200 bytes**.
Standards and spec **self-review** against `dcd41b95` found no blocking issues.
No independent reviewer was available.
Production C glue, dependency pins and compiler pins stayed unchanged.
Only the existing test interposer gained empty and error outcomes.

This did not establish physical-microphone behavior, sustained CUDA performance,
recognition quality or desktop appearance.

## Recorded milestone-08 verification

These checks ran on **aarch64-linux** with **Zig 0.17.1**:

- The initial volume regression expected level 1 but observed 0.
  The native multi-output regression found only one layer surface.
  After the change, all **38 standard Zig tests** passed directly and through
  `zig build test`. Public session and feedback tests covered:
  - Real PCM-to-level handling, silence and stale capture.
  - Phases, deadline replacement, background decoding and restart.
  - Output addition, removal and change.
  - Backpressure, coalescing, exact capacity and reuse.
  - Invalid and overflowing sizing.
- ReleaseSafe development compilation and Zig and Nix formatting passed.
  Installed default CUDA and CPU packages passed the same 38 tests in `checkPhase`.
  These builds included one, two, three and eight output slots.
  `checkPhase` still used only the standard test runner.
  CUDA package builds and footprint inspection did **not** execute NVIDIA work.
- Separate **`indicator`**, **`native-smoke`**, **`capture-inference`**,
  **`recovery-wayland`**, **`module-config`** and **`sizing`** consumers passed.
  `capture-inference` independently exercised real CPU recognition.
  Fixture smoke and adapted recovery retained their documented substitutions.
  This change did **not rerun** the NixOS session VM or the other earlier consumers.
- The final `indicator` consumer passed repeatedly with real model loading,
  PipeWire and two headless Sway outputs.
  Screenshots showed bars that responded to synthetic 440 Hz PCM on both outputs.
  The bars returned to rest after silence.
  Placement remained correct after mode and 2× scale changes.
  Five disable/enable cycles reclaimed client mappings and descriptors.
  They restored current recording feedback and kept the clipboard unchanged.

  A third output produced `OutputCapacity` and ordered failure.
  Protocol traces showed explicit output binding, empty input regions,
  keyboard interactivity NONE and output `release` requests.
  The harness asserted source selection and readiness before PCM input.
  It did not depend on policy timing.
- Allocation, source and undefined-symbol self-review covered new callbacks,
  rendering, timers, initialization, errors and teardown.
  It found no application allocator path.
  RMS used a scalar accumulator and compiler square-root intrinsic.
  Rendering used scalar loops over the permitted backing.
  Logical and native output tables were typed fields in `Storage`, not a hidden heap.
  The separate conservative main-stack budget remained **16 KiB**.

Installed layouts in bytes. Whole storage alignment is 65,536.

| Component | Default CPU/CUDA | Small sizing | Installation example |
| --- | ---: | ---: | ---: |
| Whole `Storage` | 19,529,728 | 1,179,648 | 12,517,376 |
| Native monitor records | 704 | 88 | 264 |
| Logical feedback/volume/timer state | 88 | 32 | 48 |
| Whole Wayland aggregate | 3,146,936 | 416 | 8,704 |
| Output capacity | 8 | 1 | 3 |
| Maximum separate pixel backing | 1,638,400 | 204,800 | 614,400 |

New records occupied already-counted aggregate alignment padding.
Whole static totals therefore stayed unchanged.
The Wayland and whole totals included the monitor and feedback columns.
Those columns were not additional amounts.
Actual mapping size depended on active outputs.
It was separate from static application storage.

### Standards self-review

The review used saved parent **`cc38c824`**, contribution, domain, storage
and testing rules, and the code-smell baseline.
No blocking findings remained.
The review produced these fixes:

- Missing-protocol checks no longer hid initial callback errors.
- The implementation added v3 output release.
- It no longer sent a v3 shell-destroy request on the bound v1 shell.

Native binding dependencies, compiler dependencies and production C glue stayed unchanged.
No independent sub-agent reviewer was available.

### Spec self-review

The implementation met ticket 08's requirements for reactive per-output feedback,
stale-event handling, bounded storage, release lifecycle, configuration and separate native checks.
The fixed 2× raster delegated other scales to the compositor without resize pools or queues.
No blocking local findings remained.

Protocol traces and screenshots did not establish physical appearance, keyboard
focus, pointer delivery or mixed-scale hardware acceptance.
The [target validation checklist](validation.md) records acceptance status.
This was a local self-review, not an independent review or target-desktop acceptance.
