# Idiomatic Zig: research reference

These findings use Zig 0.17.1.
They guide review of runtime modules, tests, build code and native bindings.
They do not select a Wayland dependency or represent a complete code audit.

## Sources

Use the [development shell](../CONTRIBUTING.md#development-setup) to locate the
pinned standard-library source and documentation.
Compare web advice with that source.

### Web sources and their authority

Start with the versioned official material.
Then examine APIs in the local source:

- [0.17.1 language reference: style guide](https://ziglang.org/documentation/0.17.1/#Style-Guide),
  [ownership](https://ziglang.org/documentation/0.17.1/#Lifetime-and-Ownership),
  [errors](https://ziglang.org/documentation/0.17.1/#Errors) and
  [Zen](https://ziglang.org/documentation/0.17.1/#Zen).
- [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html)
  for language, library and build-system changes that also apply to 0.17.1.
- [0.17.1 announcement](https://ziglang.org/news/0.17.1-released/).
  This is a bug-fix release. It does not justify use of unversioned `master` examples.
- [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
  for the earlier `std.Io` and entry-point changes.
  Before you copy code, compare those details with 0.17.1.

The search also found community migration guides.
The official material and pinned implementation were sufficient for these findings.
Advice to replace `@cImport` with `b.addTranslateC` alone omits the next deprecation in 0.17.
Treat older tutorials as explanations, not current API specifications.

## What to emulate

1. **Use readable, precise names and modules.**
   Functions use `camelCase`. Types and type-producing functions use `TitleCase`.
   Other values and fields use `snake_case`.

   A file with top-level fields is itself a struct.
   It normally uses a type name, such as `Writer.zig`.
   A namespace file uses `snake_case`, such as `array_list.zig`.

   Do not add unnecessary namespace prefixes and unclear `Manager` or `Utils` wrappers.
   Use glossary terms instead of new names for the same domain concepts.
   Use `zig fmt`.
   The style guide also recommends approximately 100-column lines and multiline
   lists with trailing commas. Formatting alone does not make complex code easy to read.

2. **Use types to communicate the contract.**
   Use slices for bounded sequences. Use `[]const T` for read-only borrows.
   Use `?T` for meaningful absence and error unions for failure.
   Use enums, tagged unions and exhaustive switches for alternatives.

   Prefer these types when they explain an invariant more clearly than pointer/length
   pairs, magic sentinels or combinations of booleans.
   Keep ABI-required shapes at the foreign boundary.
   Do not combine independent flags into a union.

3. **Document ownership and invalidation as part of the API.**
   Describe who owns each handle or buffer. Describe how long a returned slice is valid.
   Describe whether a value can move. Describe what callbacks borrow.

   The standard library's container and I/O comments give useful examples.
   `init` and `deinit` conventions do not imply automatic destruction or idempotent cleanup.

4. **Keep cleanup local and failure explicit.**
   Pair resource acquisition with `defer` for cleanup at scope exit.
   Use `errdefer` for initialization rollback.
   Use `try` to propagate errors. Use `catch` to recover or translate errors at an
   applicable boundary.

   Use assertions or `unreachable` for proven programmer invariants.
   Do not use them for ordinary device loss, malformed input or capacity exhaustion.
   Callback-owned resources still need explicit teardown after their last use.
   Lexical cleanup does not permit early release of a busy Wayland buffer.

5. **Pass resources explicitly.**
   Modern standard-library APIs distinguish caller buffers from allocating variants.
   They pass allocators and I/O explicitly.

   Our runtime uses static backing, not an allocator.
   Build tools and tests have different constraints.
   A call without an allocator argument can still allocate internally.

6. **Use abstractions that simplify code.**
   Plain structs, functions, comptime type factories and `anytype` are normal Zig.
   Runtime vtables and `@fieldParentPtr` also support dynamic dispatch and intrusive ownership.

   Do not replace every generic test adapter with an interface.
   Do not replace every interface with generics.
   Typed boundaries should reduce requirements at call sites.
   They should not only wrap C functions or hide casts elsewhere.

7. **Use comptime for static information.**
   Capacity-specialized types, checked layout arithmetic and compile-time validation
   are suitable for this project.
   Unless specialization or comptime iteration is necessary, prefer ordinary loops and functions.
   Do not add a reflection framework for a small fixed problem.

8. **Use tests of observable contracts.**
   Standard-library tests use `std.testing` for success, boundary and error cases.
   Keep our public behavioral test interface.
   Do not reorganize tests around private helpers only to copy the standard library's file layout.
   See the [verification policy](../CONTRIBUTING.md#verification).

### Good source-reading starting points

The shell prints the Zig store path.
All paths below are relative to `lib/std` in that store output.
Read the implementation and tests, not only the declaration name.

| Source | What to study |
| --- | --- |
| `Io/Writer.zig`: `fixed`, `VTable`, `buffered` | Caller-owned buffers, typed interface contracts, explicit capacity failure |
| `mem.zig`: `print`, `printSentinel` | Fixed-writer formatting without allocation, error translation |
| `array_list.zig`: `initBuffer`, `appendBounded`, `appendSliceBounded` | Borrowed backing, capacity checks, documented pointer stability |
| `bit_set.zig`: `Static` | Small comptime type factory, inline storage, no allocator or deinit |
| `DoublyLinkedList.zig`: `Node`, `popFirst` | Optional captures, intrusive ownership, documented preconditions |
| `Io.zig`, `Io/Reader.zig` | Explicit effects and vtable, lifetime and error contracts |
| `process.zig`: `Init`; `start.zig`: `callMain`; `Io/Threaded.zig` | Allocation risks in startup and concurrency APIs |
| `Build.zig`, `Build/Step/Run.zig` | Version-matching declarative build graph and tool execution APIs |

The library is a useful example, not a template with only current APIs.
It still contains deprecated aliases and some internal uses of them.
A standard-library linked list is not necessarily better than our small fixed slot tables.

## Important 0.17 details

- **I/O:** `std.Io` is an explicit interface for effects, including files, clocks
  and concurrency. It is not only a new name for byte streams.
  Readers and writers use concrete interfaces with caller-provided buffers.
  Learn this model instead of copying older `std.io`, `GenericWriter` or
  `fixedBufferStream` examples.
  An execution backend needs a separate allocation and lifecycle decision.
- **C import:** Zig 0.17 removed `@cImport`.
  Its release notes also deprecate `std.Build.Step.TranslateC` in favor of the
  official external `translate-c` package.
  This project still uses the bundled `zig translate-c` CLI.
  Before a generator migration, evaluate Nix pinning, target/header consistency and real ABI coverage.
  This research does not select a dependency change.
- **Formatting:** Zig deprecated `std.fmt.bufPrint` in favor of `std.mem.print`.
  Allocating printing moved to `Allocator.print`.
  For a borrowed destination, use `std.Io.Writer.fixed` or `std.mem.print`.
  Do not use allocating formatting for that destination.
  Failed formatting can leave a prefix in the buffer.
  Do not publish that prefix as a successful transcript.
- **Containers:** `std.ArrayList(T)` normally takes an allocator for allocating operations.
  Its `initBuffer` and bounded operations instead use caller-owned storage.
  For these operations, `error.OutOfMemory` means insufficient capacity.
  If a list uses `initBuffer`, **do not call allocator-taking methods**, including `deinit(gpa)`.
  This list is not a fixed-buffer allocator or arena.
- **Cleanup:** ordinary `errdefer` remains.
  Zig removed the `errdefer |err|` capture form.
  Instead, examine errors through `catch` at the applicable boundary.
- **Other migration changes:** `@splat` replaces array multiplication.
  `@backingInt` and `@fromBackingInt` replace enum integer casts.
  List `last()` returns an optional.
  Reflection uses the new field-name and field-type arrays.
  These are version facts, not instructions to rewrite working code without a reason.

### The crucial constraint for this application

The [static-storage ADR](adr/0002-fixed-application-storage.md) is stricter than
ordinary Zig practice.
In pinned `start.zig`, the full `std.process.Init` path creates allocators,
`Io.Threaded` and an allocated environment map.
The `Init.Minimal` branch avoids that full setup.
Each entry-point change still requires an audit of reachable paths.
`Io.Threaded` also allocates for tasks and can create worker threads.
The storage rule still applies to application workspaces that use these mechanisms.

**Do not adopt full `std.process.Init`, an arena, a fixed-buffer allocator or a
scheduler for style alone.**
A reviewed low-level OS integration can be the applicable choice.
The 0.16 notes describe both higher-level `std.Io` and lower-level
`std.posix.system` migration paths.
Fixed readers and writers do not themselves require an `Io.Threaded` scheduler.

Use borrowed-buffer containers only when they simplify the code.
Their backing and records must remain in the comptime layout or documented
bounded stack. The backing must not move while borrowed.
A copy of a self-referential aggregate is unsafe even without heap allocation.

Keep explicit session-capacity errors.
Do tests for reuse, exhaustion and outstanding readers or inference.
Do not limit the tests to successful append operations.
