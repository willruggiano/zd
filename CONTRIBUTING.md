# Contributing

Read before you write!

## Before changing code

- Obey the [domain documentation rules](docs/agents/domain.md) before design or
  review. Read the glossary, applicable ADRs and applicable spec or ticket.
- Use the [local tracker conventions](docs/agents/issue-tracker.md) for tracked
  work. Use the [canonical triage labels](docs/agents/triage-labels.md) for status.
- Read the [runtime reference](docs/runtime.md#public-interface-and-ownership)
  for implementation contracts.
- For code style, read the [Zig idiom research](docs/zig-idioms.md).
  This research does not select a binding library or change the storage ADR.

## Development setup

Run commands from the repository root. The project supports native aarch64-linux
and x86_64-linux builds. Use the flake's pinned toolchain.

```sh
nix develop .#default             # CPU toolchain; no model download needed
zig build -Doptimize=ReleaseSafe
zig fmt --check build.zig src/*.zig
nixfmt --check flake.nix nix/*.nix
```

The shell hook generates protocol and C bindings. It also writes development
defaults to `src/options.zig`: the CPU backend and `/var/lib/dictation/model.bin`.
The welcome message shows the pinned Zig source and documentation paths.
`zig env` reports the active paths. `zig std` serves local API documentation.

To build a CPU package with a model, use `nix build .#cpu`.
A successful development build does not prove that a model loaded.
The build graph downloads no dependencies.
After native dependency changes, remove `generated/c.zig` to regenerate bindings
against the new headers. If the `_gateway` proxy causes `InvalidHostName`, use
`env -u https_proxy -u HTTPS_PROXY zig build` for offline build-graph commands.

On a host with limited RAM, keep CUDA builds separate from VM checks.
To release evaluator memory before compilation, use separate evaluation and build
commands:

```sh
drv=$(nix eval --raw .#default.drvPath)
nix build "$drv^out" --no-link -L --max-jobs 1 --cores 1
```

### Native build integration

Read [nix/package.nix](nix/package.nix) and [build.zig](build.zig) for binding
generation, libc and linker requirements. Keep the reasons for build choices
next to that code. After a build change, run the applicable installed-consumer
checks.

### PR tooling

The shell includes `gh-stack`, `gh` and Git for PR maintenance.
The installed daemon does not depend on these tools.
Run `gh-stack` directly. It does not need a per-user extension installation.
If authentication is necessary, run `gh auth login`.

For jj-managed branches, use
`gh-stack link <stack-number> <pull-request-url>` to add an existing PR.
This command does not change local stack tracking or check out branches.

## Verification

When you change behavior, tests or package checks, obey this policy.
Use the [named test catalog](docs/testing.md) to select integration checks.
Use the [local evidence](docs/verification.md) to identify past test runs.
Use [target validation](docs/validation.md) for hardware acceptance.

### Fast checks and test seam

```sh
zig test src/tests.zig
zig build test                   # alternative invocation of the same suite
```

- Use the dictation module's public interface as the primary interface for
  behavioral tests. The daemon uses this same interface.
  Observe capture, indicator and clipboard results.
  Do not make private field layouts or helper-call order the subject of tests.
- Use deterministic adapters for external audio, decoding, Wayland and time.
  Do not add a runtime allocation framework to support tests.
- Fast checks use **only Zig's standard test runner**. Native package
  `checkPhase` runs that suite with `doCheck` enabled. Keep tests independent of
  physical audio, GPU and desktop resources. Do not require model downloads or
  network access. Fail the build if a test fails.
- Keep normal pre/post hooks. Do not use them to add scripts, audits, Nix
  evaluations or integration tests.
- Run allocation audits, source audits and named `passthru.tests` consumers
  separately. Do not make them automatic CI checks, flake checks or extra fast
  checks. Do tests of installed packages and modules as consumers use them.
- Describe every substitution. Distinguish derivation evaluation, builds, cache
  reuse and test execution. Do not report target-test execution from a cross
  build that could not run those tests. Do not use VM or fixture success as
  evidence of CUDA operation, recognition quality or physical-desktop behavior.

### Required coverage

- Audit all reachable application allocation paths. Include initialization, the
  toggle client, threading, parsing, formatting, logging, failure and teardown.
  Stable RSS or a bounded heap does not prove the
  [storage contract](docs/adr/0002-fixed-application-storage.md).
  Identify allocations inside external dependencies and permitted Wayland backing separately.
- Make sure that the comptime layout includes every application workspace,
  alignment, padding and simultaneous instance. Account for bounded stack use
  separately. Do tests with default and non-default sizes.
  Do tests with invalid, incompatible and overflowing settings.
- Do tests for exact capacity boundaries, exhaustion and slot reuse.
  Include pressure from inference, restart, clipboard readers and monitor events.
  Make sure that Wayland backing release is safe.
  Make sure that stale mappings do not accumulate.
- Do tests for loading refusal, start, stop, finalization and background decoding.
  Include repeated restarts, stale completions and borrowed-buffer ownership.
- Do tests for recording beyond two minutes, chunk joins, silence, empty output
  and audio or text exhaustion. Failures must never publish partial text or error
  text. Failures must never silently discard speech.
- Do tests for default-source selection, changes and removal.
  Include capture, inference and publication failures.
  Do tests for missing models, missing protocols and connection loss.
  Make sure that the previous clipboard stays responsive during new work and
  replacement.
- Do checks of module configuration, graphical-session lifetime and PipeWire ordering.
  Do not require Home Manager, UWSM or compositor-specific setup.
- Use the linked acceptance procedure on the actual target desktop.
  Validate CUDA loading, sustained throughput, finalization latency and recognition.
  Validate noninteractive feedback on multiple monitors.
  Local checks cannot establish those results.

## Documentation maintenance

### Structure and ownership

- Keep [README](README.md) a concise, stable documentation map.
  Do not add feature lists, task status or copies of contributor instructions.
- Code is the source of truth for APIs, constants and local behavior.
  Keep those explanations in code comments or doc comments.
  Do not copy code documentation into Markdown. Link to the source instead.
- Use Markdown for setup, decisions and concepts that cross module boundaries.
  Prefer a related executable test or example where useful.
  Such a test or example is not a requirement for documentation.
- Give each fact one location. This file defines development workflow and
  verification policy. Update the guide that owns the fact.
  Link to that guide. Do not keep copies in other guides.
- Keep current procedures and contracts separate from historical verification
  evidence. When you move material, keep unique findings and limits on the results.
  Do not treat past success as current acceptance.
- Keep execution progress and task order in the local tracker.
  Keep lasting decisions in the applicable guide or ADR.
  Do not add milestone progress to each guide.
- After documentation changes, do checks of relative links and heading anchors.
  Keep documentation checks separate from package `checkPhase`.

### Prose and diagrams

Use [ASD-STE100](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)
for all prose. Use its approved general vocabulary and active voice.
Limit procedural sentences to 20 words and descriptive sentences to 25 words.
Give one instruction per sentence. Keep technical names exact.
Use the canonical terms from `GLOSSARY.md` throughout the documentation.

Prefer a small diagram to paragraphs for control flow and relationships.
Label arrows. Keep necessary conditions and failure cases next to the diagram.
Use the simpler of plain text or Mermaid.

### Reproducible output blocks

Put the command after `!` in the opening fence. Put its captured output in the
body. The format is:

````markdown
```!command to reproduce
captured output
```
````

Run the command from the repository root.
Give the required environment, such as the development shell.
Record actual output. Do not invent output or replace it with an unexplained
ellipsis. Update the command and output together.
Before you add output to documentation, examine it for private data.

Use ordinary `sh` fences for commands to run.
Use `text` or `mermaid` fences for diagrams that you write by hand.
Do not label historical results as current reproducible output.
This fence format does not require an automatic execution tool or CI check.
