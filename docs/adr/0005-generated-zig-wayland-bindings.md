# Use generated Zig bindings over libwayland

Use `zig-wayland` to generate typed protocol bindings from the pinned Wayland XML files.
Keep libwayland as the native client library.
The [Zig manifest](../../build.zig.zon) owns the generator pin.
The [Zig build graph](../../build.zig) owns protocol selection, generation and application compilation.
It uses the upstream `Scanner` build API.
Both package and development builds use that graph.

Nix supplies native dependencies and prefetches manifest dependencies with `zig.fetchDeps`.
The package setup and development shell populate Zig's dependency cache.
This keeps dependency ownership in Zig without requiring network access during the Nix package build.
A separate Nix generator derivation would duplicate build orchestration outside the Zig graph.

Typed handles and event unions replace translated protocol functions and C listener tables.
This removes generated protocol C from the daemon build.
It also removes application callback casts without a custom binding framework.
A small handwritten layer over the old bindings would retain those generated C files and duplicate protocol-specific adaptation.

The generator can allocate during the build.
Generated client calls use local argument arrays and borrowed listener userdata.
They leave native proxy and connection allocation inside libwayland.
They do not own the application's monitor, frame or clipboard records.
The [storage decision](0002-fixed-application-storage.md) still applies to those records and their lifetimes.

Keep explicit protocol-version limits, disconnect handling and buffer-release handling.
Keep the translated C callback type for sanitized libwayland logging.
That callback's `va_list` ABI differs between the supported architectures.
The bindings do not change the [protocol requirements](0004-require-wayland-protocols-not-a-specific-compositor.md).
