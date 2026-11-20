# Idiomatic Zig: research reference

These findings use Zig 0.17.1. They guide review of runtime modules, tests, build
code and native bindings. They do not select a Wayland dependency or claim a
completed code audit.

## Sources

Use the [development shell](../CONTRIBUTING.md#development-setup) to locate the
pinned standard-library source and docs. Check web advice against that source.

### Web sources and their authority

Start with the versioned official material, then verify APIs in the local source:

- [0.17.1 language reference: style guide](https://ziglang.org/documentation/0.17.1/#Style-Guide),
  [ownership](https://ziglang.org/documentation/0.17.1/#Lifetime-and-Ownership),
  [errors](https://ziglang.org/documentation/0.17.1/#Errors) and
  [Zen](https://ziglang.org/documentation/0.17.1/#Zen).
- [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html)
  for language, library and build-system changes inherited by 0.17.1.
- [0.17.1 announcement](https://ziglang.org/news/0.17.1-released/): a bug-fix
  release, not a reason to follow unversioned `master` examples.
- [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
  explain the preceding `std.Io` and entry-point changes; check their details
  against 0.17.1 before copying code.

Search also surfaced community migration guides, but the official material and
pinned implementation were sufficient for these findings. In particular, advice
to replace `@cImport` with `b.addTranslateC` alone misses the next deprecation in
0.17. Treat older tutorials as explanations, not current API specifications.

## What to emulate

1. **Readable, precise names and modules.** Functions use `camelCase`, types and
   type-producing functions `TitleCase`, other values/fields `snake_case`.
   A file with top-level fields is itself a struct and normally uses a type name
   (`Writer.zig`); a namespace file uses `snake_case` (`array_list.zig`).
   Avoid redundant namespace prefixes and vague `Manager`/`Utils` wrappers.
   Follow the glossary rather than gratuitously renaming domain concepts.
   Use `zig fmt`; the style guide also recommends roughly 100-column lines and
   multiline lists with trailing commas. Formatting alone does not make dense
   code readable.
2. **Types communicate the contract.** Use slices for bounded sequences,
   `[]const T` for read-only borrows, `?T` for meaningful absence, error unions
   for failure, enums/tagged unions and exhaustive switches for alternatives.
   Prefer those over pointer/length pairs, magic sentinels or combinations of
   booleans when they clarify the actual invariant. Keep ABI-mandated shapes at
   the foreign boundary; do not force unions into independent flags.
3. **Ownership and invalidation are part of the API.** Document who owns a
   handle/buffer, how long a returned slice is valid, whether a value may move,
   and what callbacks borrow. The standard library's container and I/O comments
   are especially useful here. `init`/`deinit` conventions do not imply automatic
   destruction or idempotent cleanup.
4. **Make cleanup local and failure explicit.** Pair acquisition with `defer`
   for scope-bound resources and `errdefer` for initialization rollback. Use
   `try` to propagate, `catch` to recover or translate at a meaningful boundary.
   Use assertions/`unreachable` for proven programmer invariants, not ordinary
   device loss, malformed input or exhausted capacity. Callback-owned resources
   still need explicit teardown after their last use; lexical cleanup is not
   permission to release a busy Wayland buffer early.
5. **Pass resources rather than hiding them.** Modern stdlib APIs distinguish
   caller buffers from allocating variants and pass allocators/I/O explicitly.
   Our runtime chooses static backing, not an allocator. Build tools and tests
   have different constraints. A stdlib convenience is not automatically
   allocation-free just because the call site lacks an allocator argument.
6. **Use abstraction where it earns its keep.** Plain structs/functions,
   comptime type factories and `anytype` are normal Zig. So are explicit runtime
   vtables and `@fieldParentPtr` when dynamic dispatch or intrusive ownership is
   needed. Do not replace every generic test adapter with an interface, or every
   interface with generics. Typed boundaries should reduce obligations at call
   sites, not merely wrap every C function or conceal casts elsewhere.
7. **Use comptime for real static knowledge.** Capacity-specialized types,
   checked layout arithmetic and compile-time validation fit this project well.
   Prefer ordinary loops/functions unless specialization or comptime iteration
   is actually needed. Avoid a reflection framework for a small fixed problem.
8. **Test observable contracts.** Standard-library tests demonstrate both
   success and boundary/error cases using `std.testing`. Keep our established
   public behavioral seam; do not reorganize tests around private helpers just
   to imitate source-file layout. See the
   [verification policy](../CONTRIBUTING.md#verification).

### Good source-reading starting points

All paths below are relative to `lib/std` in the Zig store output printed by the shell.
Read the implementation and tests, not only the declaration name.

| Source | What to study |
| --- | --- |
| `Io/Writer.zig`: `fixed`, `VTable`, `buffered` | Caller-owned buffers, typed interface contracts, explicit capacity failure |
| `mem.zig`: `print`, `printSentinel` | Small nonallocating convenience built over a fixed writer; error translation |
| `array_list.zig`: `initBuffer`, `appendBounded`, `appendSliceBounded` | Borrowed backing, capacity checks, documented pointer stability |
| `bit_set.zig`: `Static` | Small comptime type factory, inline storage, no allocator/deinit |
| `DoublyLinkedList.zig`: `Node`, `popFirst` | Optional captures, intrusive ownership, documented preconditions |
| `Io.zig`, `Io/Reader.zig` | Explicit effects, precise vtable/lifetime/error contracts |
| `process.zig`: `Init`; `start.zig`: `callMain`; `Io/Threaded.zig` | Why friendly startup/concurrency APIs need an allocation audit |
| `Build.zig`, `Build/Step/Run.zig` | Version-matching declarative build graph and tool execution APIs |

The library is an exemplar, not a uniformly modern template: it still contains
deprecated aliases and some internal uses of them. Nor is a linked list
necessarily better than our small fixed slot tables just because std provides it.

## Important 0.17 details

- **I/O:** modern `std.Io` is an explicit interface for effects, including files,
  clocks and concurrency, not merely renamed byte streams. Readers/writers use
  concrete interfaces with caller-provided buffers. Learn this model rather
  than copying older `std.io`, `GenericWriter` or `fixedBufferStream` examples;
  choosing an execution backend is a separate allocation/lifecycle decision.
- **C import:** `@cImport` is removed. The 0.17 release notes also deprecate
  `std.Build.Step.TranslateC` in favor of the official external `translate-c`
  package. The bundled `zig translate-c` CLI still exists and is what this
  project currently uses. Evaluate any generator migration with Nix pinning,
  target/header consistency and real ABI coverage; no dependency change is
  selected by this research.
- **Formatting:** `std.fmt.bufPrint` is deprecated in favor of `std.mem.print`;
  allocating printing moved to `Allocator.print`. For a borrowed destination,
  use `std.Io.Writer.fixed` or `std.mem.print`, not allocating formatting.
  Failed formatting may already have written a prefix: do not publish it as a
  successful transcript.
- **Containers:** `std.ArrayList(T)` normally takes an allocator on allocating
  operations. Its `initBuffer`/bounded operations instead use caller-owned
  storage, with `error.OutOfMemory` meaning insufficient capacity. On a list
  initialized with `initBuffer`, **all allocator-taking methods are forbidden**,
  including `deinit(gpa)`. This is not a fixed-buffer allocator or arena.
- **Cleanup:** ordinary `errdefer` remains; `errdefer |err|` capture was removed.
  Inspect an error through `catch` at the appropriate boundary instead.
- **Other migration traps:** use `@splat` instead of array multiplication;
  `@backingInt`/`@fromBackingInt` supersede enum integer casts; list `last()`
  returns an optional; reflection uses the new field-name/type arrays.
  These are version facts, not instructions to rewrite working code blindly.

### The crucial constraint for this application

The [static-storage ADR](adr/0002-fixed-application-storage.md) is stricter than
ordinary Zig practice. In pinned `start.zig`, the full `std.process.Init` path
sets up allocators, `Io.Threaded` and an allocated environment map. The
`Init.Minimal` branch avoids that full setup, but any entry-point change still
requires auditing its reachable paths. `Io.Threaded` also allocates for tasks and
can create worker threads. Those are not exemptions for application workspaces.

Therefore **do not adopt full `std.process.Init`, an arena, a fixed-buffer
allocator or a scheduler simply to look more idiomatic**. A reviewed low-level
OS integration can be the appropriate choice; the 0.16 notes explicitly describe
both higher-level `std.Io` and lower-level `std.posix.system` migration paths.
Pure fixed readers/writers do not themselves require an `Io.Threaded` scheduler.

Borrowed-buffer containers are candidates only when they simplify real code.
Their backing and bookkeeping must remain in the comptime layout (or documented
bounded stack), and the backing must not move while borrowed. In particular,
constructing a self-referential aggregate and then copying it is unsafe even if
no heap allocation occurs. Keep explicit session-capacity errors and test reuse,
exhaustion and outstanding readers/inference, not just nominal append behavior.
