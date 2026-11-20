# Use generated Zig bindings over libwayland

Use `zig-wayland` to generate typed protocol bindings from the pinned Wayland XML files.
Keep libwayland as the native client library.
The [binding derivation](../../nix/wayland-bindings.nix) owns the generator pin and protocol-version selection.
Both package and development builds use its output.
The Zig build graph downloads no dependencies.

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

The migration does not replace PipeWire, whisper.cpp or their C bindings.
It does not establish physical-desktop or GPU acceptance.
See the [verification record](../verification.md) for executed checks and their limits.
