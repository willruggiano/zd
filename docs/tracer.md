# Packaged native Wayland tracer

This is the first implementation milestone, **not usable voice recognition**.
Only `dictation daemon --fixture` starts a daemon. It simulates recording and
finishes with `Fixture dictation result.` after a 350 ms finalization interval.
There is no microphone, audio fixture file, inference library, model download,
or silent fallback. Wayland and the control socket are real.

## Build and try

```sh
nix build                         # native package, including deterministic tests
./result/bin/dictation footprint
./result/bin/dictation daemon --fixture
# In another terminal, with the same uid:
./result/bin/dictation toggle      # recording
./result/bin/dictation toggle      # finalizing, then copy
wl-paste --no-newline             # optional independent clipboard reader
```

Use a Wayland compositor exposing **zwlr-layer-shell-v1** and
**ext-data-control-v1**, with a seat, wl_compositor, and wl_shm. The service needs
`XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`. It does not use Hyprland APIs or fall
back to deprecated clipboard protocols. Missing protocols are reported as
`MissingLayerShell` or `MissingDataControl`; failure to connect is
`WaylandConnection`. Library diagnostics are suppressed in favor of sanitized
messages. `toggle` returns nonzero if the daemon is absent, busy, or unresponsive.
A successful control reply means **toggle accepted**, not successful copying.

The transparent, click-through, keyboard-noninteractive surface is on one
compositor-selected output. Its bottom-center pill has white recording bars,
blue finalization bars, green success bars, amber no-speech bars, or red failure
bars. Feedback lasts 900 ms. The bars are not reactive in this milestone. Idle
renders transparent pixels without repeatedly remapping the layer surface.
No transcript is drawn and nothing is automatically pasted.

SIGINT/SIGTERM stops the daemon. An abstract Unix `SOCK_SEQPACKET` socket named
`dictation-fixture-<uid>` permits one instance per uid/network namespace; only
same-uid peers are accepted. It does not leave a stale filesystem socket. This
tracer does not yet distinguish simultaneous graphical sessions for one uid.
Commands are exactly the six bytes `toggle`, with one reply per connection.
Messages larger than 16 bytes, unknown requests, and empty/disconnected clients
cannot become toggles. Clients have a one-second idle deadline, the toggle
command has a 1.5-second response timeout, and a full client table rejects new peers (best-effort `busy` reply, or a
disconnect if the peer races teardown).
The listener's kernel backlog is not an application queue of dictation sessions.

## Toolchain and development

`flake.lock` pins Nixpkgs and Mitchell Hashimoto's zig-overlay. The compiler is
explicitly **Zig 0.17.1**, the latest stable release verified against
<https://ziglang.org/download/> on 2026-11-19, not the overlay's `master` alias.
The pinned desktop dependencies are Wayland 1.26.0, wayland-protocols 1.49 and
wlr-protocols' 2022-09-05 revision. The smoke compositor is Sway 1.12.

```sh
nix develop                     # generates protocol bindings and default options
zig fmt build.zig src/*.zig
zig test src/tests.zig           # Zig's standard runner, no desktop required
zig build test                  # same standard runner via the optional build graph
zig build -Doptimize=ReleaseSafe # executable in zig-out/bin
nix fmt                         # format Nix files
```

Generation uses wayland-scanner and `zig translate-c`; generated bindings are
not tracked. The development shell regenerates `src/options.zig` from the
package defaults. Nix builds use fresh generated bindings. The compiler tools,
Nix, generator and test runner may allocate; the shipped runtime may not.
An environment proxy with an invalid DNS hostname (e.g. `_gateway`) can make
Zig's build runner reject its configuration, even for an offline build. For
this workspace's offline `zig build` only, use
`env -u https_proxy -u HTTPS_PROXY zig build`. No dependencies are fetched by the
Zig build graph. `zig test` and the package build do not need that workaround.
Native x86_64-linux and aarch64-linux packages are exposed; cross builds are
explicitly rejected rather than silently building or claiming to test a host
binary.

## Public interface and ownership

`Session(capacity)` in `src/dictation.zig` is the primary behavioral test seam
and the state machine used by the daemon. `connect(capabilities)` validates the
required protocols. `command(request, effects)` validates a control request;
`toggle(effects)` starts/stops simulated capture; `complete(text, effects)` may
publish only while finalizing. Duplicate completions outside finalization,
empty/whitespace output, over-capacity output and rejected publication do not
replace the clipboard. A new toggle during fixture finalization cancels the
fixture timer and begins recording again.

Effects are a comptime-bound external adapter with `recording(bool)`,
`show(Indicator)` and `publish([]const u8) bool`. Arguments are borrowed only
for the call. Successful publication must retain an independent bounded copy.
Tests supply deterministic desktop effects; production drives native Wayland
with explicitly simulated capture and completion. There is no second session
state machine in the tests. The current completion API assumes a single
synchronous fixture timer; generation-tagged asynchronous inference and safe
late-result cancellation are work for the later restart milestone.

Wayland has no selection-publication acknowledgement. Success means that a
valid selection request was queued without a known transport failure; it does
not prove that another application pasted. A later compositor disconnect
terminates the service with a diagnostic. Capture and finalization never clear
an existing selection. Each offered transcript has its own slot and immutable
bytes. A source cancellation retires that source, but active nonblocking paste
transfers keep its bytes pinned. Only a slot without a source **and** without
readers is reusable; unavailable slots reject publication before changing the
selection. Transfers expire after five seconds without write progress, and a full transfer table
closes additional paste fds rather than blocking the event loop or allocating.
No history is retained after ownership and readers end. External clipboard
managers may independently persist copied text.

## Sizing and storage audit

Package overrides rebuild the whole typed storage layout:

```nix
packages.${system}.default.override {
  transcriptBytes = 65536;
  controlClients = 4;
  clipboardSlots = 2;
  transfers = 4;
}
```

| Input | Default | Unit and valid range |
| --- | ---: | --- |
| `transcriptBytes` | 1048576 | bytes per transcript **and per offered slot**, 1..67108864 |
| `controlClients` | 8 | simultaneous control peers, 1..64 |
| `clipboardSlots` | 3 | simultaneous offered/retiring texts, 2..8 |
| `transfers` | 8 | simultaneous paste fds, 1..64 |

The ceilings are deliberate tracer configuration limits, not automatic session
timeouts. `Sizes.validate` checks arithmetic overflow and incompatible/invalid
capacities at comptime; deterministic tests also exercise the validator.

`main.Storage` is the actual aggregate type, not a guessed arena. Its
`@sizeOf` includes field alignment and tail padding and accounts for:

- the session's transcript and phase/connection state;
- every clipboard slot, bytes, source pointer and reader count;
- transfer fds, offsets, deadlines and source references;
- one surface/layer/pool, two buffer records, five bound-global ids, protocol
  handles, indicator state and fixture deadlines (no audio samples yet);
- all control-client records, address, credentials and request scratch;
- the toggle client's response buffer and poll descriptor;
- daemon poll descriptors, signal flag and 1024-byte formatting scratch.

There are no owned audio windows, GPU workspaces, threads or event/job queues
in this slice; future integrations must extend this aggregate, not allocate
outside it. The client shares the binary's declared layout, even though most
of it is unused by that command. `dictation footprint` prints the derived
working-storage total and component sizes. The default aarch64 build reports
**4,196,192 bytes**, alignment 8. Different capacities/architectures may change
that total; use the built binary, not this example, as the authority. This is
not a claim about process RSS: executable/read-only literal and protocol tables,
loader/OS resources and genuine dependency internals are separate.

**Stack accounting:** no recursion, variable-length arrays, copying of the
aggregate, threads, or allocator-backed argument parsing is used. Ordinary
locals are fixed scalar/pointer/slice values and a `timespec` (16 bytes on the
targets). Formatting uses `std.mem.print`'s 32-byte fixed writer and at most
65 bytes of integer-formatting scratch on these 64-bit targets. The pinned `std.debug.FullPanic` failure path uses a
4111-byte local message buffer, then calls our constant-only diagnostic and
`_exit`; it never reaches symbolization/backtrace allocation. Budget 16 KiB for
the bounded application-owned call chain, separately from static storage and
external library/OS stack frames. This is a conservative source-level budget,
not a compiler-certified total process stack bound. Re-audit it on toolchain or
call-graph changes. No array scales on the stack with a sizing option.

**Allocation audit:** the runtime exports the libc `main(argc, argv)` ABI and
borrows OS arguments. It deliberately does not request `std.process.Init`
(which would initialize allocators and I/O). Reachable standard-library uses
are fixed-buffer integer formatting, memory comparison/trim/zeroing, checked
arithmetic and the custom panic path. `std.mem.print` creates `Io.Writer.fixed`,
not an allocating writer. Runtime syscalls use libc directly: sockets, poll,
clock, signals, writes and the rendering mapping. Generated protocol wrappers
call libwayland; their genuine proxy/queue allocation is exempt. There is no
application malloc shim, arena, container allocation or thread creation.
Audit source and reachable standard-library implementations separately from
fast tests; heap/RSS measurements or process-wide allocation traps cannot
establish this contract. The code never writes recordings, transcript logs,
network requests or clipboard history.

**Wayland backing exception:** one memfd, sized by the fixed 160×40×4-byte
geometry times two frames, contributes a separately reported **51,200 bytes**.
Only rendering pixels live there. Creation checks fd, truncate, mmap, pool and
buffer results; each fd is closed after mapping/pool creation. The buffers are
reused and never repainted until `wl_buffer.release`. If both are busy, drawing
waits rather than growing storage. Shutdown/error cleanup destroys proxies and
unmaps the client view; the compositor's independent mapping owns its lifetime.
Surrounding metadata remains in `Storage`. This is not an application heap.

## Separate integration checks

```sh
nix build .#default.passthru.tests.native-smoke -L --no-link
nix build .#default.passthru.tests.sizing -L --no-link
```

`native-smoke` starts a private headless Sway with the pixman renderer, uses the
**installed** daemon/client, and retrieves clipboard text with wl-paste. It
checks missing/stopped daemon diagnostics, invalid/oversized commands,
control-slot exhaustion/disconnection, preservation of previous text during
capture, publication, and continued clipboard serving. It substitutes **only
capture and inference**; compositor, layer-shell, ext-data-control, IPC and
clipboard transfers are native. It needs a native Linux Nix builder (non-root
sandbox build user), not KVM, a physical GPU, audio server, host desktop or
network. `sizing` builds default and small configurations and compares their
inspectable footprints; each native package also runs the Zig suite.

Neither passthru test runs automatically on an ordinary build or flake check.
The ordinary `checkPhase` runs **only `zig test src/tests.zig`**, with standard
pre/post hooks and `doCheck` enabled. No source audit, Python, shell integration
suite or Nix validation is inserted into those hooks. The Python smoke driver
and footprint validation belong only to their separate derivations.

## Remaining milestones

Real PipeWire capture, resident CUDA whisper.cpp, model provisioning, NixOS
session installation, asynchronous restart safety, streaming and exhaustion
handling, reactive multi-output indicators, and full resource-pressure testing
are not delivered here. There is no bespoke lock/suspend cancellation.
Real-desktop visual/click-through/focus validation and RTX 3090 recognition,
throughput and latency checks remain for the desktop acceptance milestone.
Headless fixture success must not be represented as hardware or recognition
validation. See [the design](design.md) for the intended complete application.

## Verification recorded for this milestone

On 2026-11-19 with Zig 0.17.1:

- Native aarch64-linux default and small Nix packages built; **all six Zig
  tests passed** in each package's checkPhase. The small configuration uses
  64 transcript bytes, two control peers, two clipboard slots and one transfer;
  its derived static footprint is **1,728 bytes** versus the default 4,196,192.
- Both named `native-smoke` and `sizing` derivations **executed successfully**,
  not merely evaluated. The native smoke also exercised external ownership
  replacement, source-slot reuse and idle-control timeout recovery.
- `zig build test`, `zig build -Doptimize=ReleaseSafe`, direct `zig test`,
  `zig fmt --check` and `nixfmt --check` succeeded in the development environment.
- A separate one-byte-capacity test build passed all six tests; a zero-capacity
  build failed at comptime with `InvalidTranscriptCapacity`. Validator tests
  cover overflowing multiplication and the other invalid capacities.
- The runtime/standard-library allocation audit described above was performed
  outside checkPhase, including startup, generated wrappers and panic paths.
- The x86_64 Nix derivation evaluated, and cross-target translated bindings plus
  a Zig object semantic compilation succeeded. **No x86_64 binary was linked or
  executed here.** In particular, the log callback uses the translated parameter
  type to accommodate the two architectures' different `va_list` ABIs.
- No NixOS VM, real microphone, CUDA/model, physical monitor/focus/click-through,
  or recognition-quality acceptance was performed. Those remain later milestones.

The installed-package smoke caught the need to select the Nix GNU interpreter
and library paths explicitly rather than relying on Zig's native interpreter
autodetection inside a sandbox. Keep this consumer-level test when changing
packaging or the compiler pin.
