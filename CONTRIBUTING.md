# Contributing

Read before you write!

## Before changing code

- Follow the [domain documentation rules](docs/agents/domain.md): read the
  glossary, relevant ADRs and applicable spec/ticket before design or review.
- Use the [local tracker conventions](docs/agents/issue-tracker.md) for tracked
  work and the [canonical triage labels](docs/agents/triage-labels.md) for status.
- Consult the [runtime reference](docs/runtime.md#public-interface-and-ownership)
  for implementation contracts and the [Zig idiom research](docs/zig-idioms.md)
  when reviewing code style. The latter is research, not a binding-library
  adoption decision or permission to weaken the storage ADR.

## Development setup

Run commands from the repository root. Native aarch64-linux and x86_64-linux
builds are supported; use the flake's pinned toolchain.

```sh
nix develop .#default             # CPU toolchain; no model download needed
zig build -Doptimize=ReleaseSafe
zig fmt --check build.zig src/*.zig
nixfmt --check flake.nix nix/*.nix
```

Entering the shell generates protocol/C bindings and rewrites `src/options.zig`
to development defaults: explicit CPU backend and `/var/lib/dictation/model.bin`.
The welcome banner locates the pinned Zig sources and docs; `zig env` reports the
active paths, and `zig std` serves local API documentation. Use
`nix build .#cpu` for a provisioned runnable CPU package; a successful development
build does not imply that a model loaded.

The build graph downloads no dependencies. After native dependency changes,
remove `generated/c.zig` to regenerate bindings against the new headers. If the
workspace's `_gateway` proxy causes `InvalidHostName`, use
`env -u https_proxy -u HTTPS_PROXY zig build` for offline build-graph commands.

On a RAM-constrained host, keep CUDA builds separate from VM checks. To release
evaluator memory before compiling a fresh dependency stack:

```sh
drv=$(nix eval --raw .#default.drvPath)
nix build "$drv^out" --no-link -L --max-jobs 1 --cores 1
```

### Native build integration

Read [nix/package.nix](nix/package.nix) and [build.zig](build.zig) for binding
generation, libc and linker requirements. The reasons for these build choices
belong next to that code. Run the affected installed-consumer checks when changing
them.

### PR tooling

The shell includes `gh-stack`, `gh` and Git for PR maintenance only; they are not
installed-daemon dependencies. Invoke `gh-stack` directly, without a per-user
extension installation; authenticate with `gh auth login` if needed. For
jj-managed branches, `gh-stack link <stack-number> <pull-request-url>` appends an
existing PR without changing local stack tracking or checking out branches.

## Verification

When implementing behavior, changing tests or packaging checks, follow this
policy. Commands, policy and results have separate homes: use the
[named test catalog](docs/testing.md) to select integration checks, the
[local evidence](docs/verification.md) to see what actually ran, and
[target validation](docs/validation.md) for hardware acceptance.

### Fast checks and test seam

```sh
zig test src/tests.zig
zig build test                   # alternative invocation of the same suite
```

- Use the dictation module's public interface, also driven by the daemon, as the
  primary behavioral seam. Observe capture, indicator and clipboard outcomes,
  not private field layouts or helper-call order. Use deterministic adapters for
  external audio, decoding, Wayland and time; do not introduce a runtime
  allocation framework to support tests.
- Fast checks are **only Zig's standard test runner**. Native package
  `checkPhase` runs that suite with `doCheck` enabled. Keep tests independent of
  physical audio/GPU/desktop resources, model downloads and network access.
  Fail the build on test failure. Preserve normal pre/post hooks without using
  them to add scripts, audits, Nix evaluations or integration tests.
- Allocation/source audits and named `passthru.tests` consumers are separate
  verification. Keep them independently runnable, not automatic CI/flake checks
  or extra fast checks. Test installed packages/modules as consumers use them.
- State every substitution. Evaluating a derivation, building it, reusing cached
  results and executing a test are different evidence. Do not claim a cross
  build ran target tests it could not execute, or infer CUDA operation,
  recognition quality or physical-desktop behavior from a VM or fixture.

### Required coverage

- Audit all reachable application allocation paths, including initialization,
  the toggle client, threading, parsing, formatting, logging and failure/teardown.
  Stable RSS or a bounded heap does not prove the
  [storage contract](docs/adr/0002-fixed-application-storage.md); distinguish
  genuine dependency allocations and approved Wayland backing.
- Verify the comptime layout accounts for every application workspace,
  alignment/padding and simultaneous instance. Account for bounded stack use
  separately. Exercise default/non-default sizes, invalid/incompatible/overflowing
  settings, exact boundaries, exhaustion and slot reuse under inference,
  restart, clipboard-reader and monitor-event pressure. Verify safe Wayland
  backing release without accumulating stale mappings.
- Cover loading refusal, start/stop/finalization, background decoding, repeated
  restarts, stale completions and borrowed-buffer ownership. Test recording
  beyond two minutes, chunk joins, silence/empty output and audio/text exhaustion;
  failures must never publish partial/error text or silently drop speech.
- Exercise default-source selection/change/removal, capture/inference/publication
  failures, missing model/protocol dependencies and connection loss. Verify
  responsive previous-clipboard serving during new work and replacement.
- Check module configuration, graphical-session lifecycle and PipeWire ordering
  without Home Manager, UWSM or compositor-specific requirements.
- Validate CUDA loading, sustained throughput, finalization latency, recognition
  and noninteractive multi-monitor feedback on the actual target desktop using
  the linked acceptance procedure. Local checks cannot establish those results.

## Documentation maintenance

### Structure and ownership

- Keep [README](README.md) a concise, stable documentation map, not a feature
  ledger, task tracker or copy of contributor instructions.
- Code is the source of truth for APIs, constants and local behavior. Keep those
  explanations in code comments or doc comments. Do not copy code documentation
  into Markdown; link to the source instead.
- Use Markdown for what code cannot reasonably explain: setup, decisions and
  concepts that span modules or responsibilities. Prefer a related executable
  test or example where useful; it is not a prerequisite for documenting a concept.
- Give each remaining fact one home. This file owns development workflow and
  verification policy. Update the owning guide and link to it elsewhere; do not
  synchronize copies across the overview, runtime and installation guides.
- Keep current procedures/contracts separate from historical verification
  evidence. Preserve unique findings and qualification of results when moving
  material; do not turn old success into current acceptance.
- Leave execution progress and sequencing in the local tracker. Durable decisions
  belong in the relevant guide or ADR, not milestone chatter in every entry point.
- After reorganizing docs, check relative links and heading anchors. Documentation
  checks remain separate from package `checkPhase`.

### Prose and diagrams

Use ASD-STE100 as a guide for about 80% of prose, not as a strict compliance
claim. Use common words, short active sentences and one instruction per sentence.
Keep technical names exact. Leave `GLOSSARY.md` exempt from prose-style changes,
and use its canonical terms throughout the docs.

Prefer a small diagram to paragraphs for control flow and relationships. Label
arrows. Keep necessary conditions and failure cases next to the diagram. Use
plain text or Mermaid; choose the simpler form.

### Reproducible output blocks

Put the command after `!` in the opening fence. Put its captured output in the
body. The format is:

````markdown
```!command to reproduce
captured output
```
````

Run the command from the repository root. State any required environment, such as
the development shell. Record actual output; do not invent it or replace it with
an unexplained ellipsis. Update the command and output together. Review output
for private data before adding it to docs.

Use ordinary `sh` fences for commands to run, and `text` or `mermaid` fences for
hand-written diagrams. Do not label historical results as current reproducible
output. This fence format does not imply an automatic execution tool or CI check.
