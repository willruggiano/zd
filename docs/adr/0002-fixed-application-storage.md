# No dynamic allocation throughout the Zig runtime

Use statically sized storage and bounded, fixed-size stack values throughout the production Zig program.
This rule includes the daemon, toggle client, startup and error paths.
A fixed transcript capacity, bounded heap or initialization-only allocation is not sufficient.
Do not use these application allocation mechanisms:

- Application allocators or startup heap preallocation.
- Arenas or allocator-backed containers.
- Zig convenience functions with hidden allocations.

The rule applies to audio, inference scheduling, rendering state, IPC, configuration and logging.
It also applies to device records, monitor records and clipboard handling.
Define explicit failure behavior for capacity exhaustion. Do not increase storage at runtime.

Make storage-sizing inputs configurable through the package build and NixOS module.
A Zig comptime calculation must derive the layout and total from all application-owned storage requirements.
Include all workspaces, queues, slot tables, buffers, alignment, padding and concurrent instances.
A configurable transcript buffer or an estimated arena size alone is not sufficient.

Document bounded stack requirements separately.
Make the derived footprint available for inspection.
Reject invalid configurations before runtime.
Capacity changes rebuild the program. They must not introduce a runtime allocator, even over fixed backing memory.

Allocations inside external dependencies are outside the guarantee.
These dependencies include whisper.cpp, GPU drivers, PipeWire and libwayland.
Do not patch or constrain their allocations.
Application storage behind C malloc or a custom C wrapper is not an external-dependency allocation.

Wayland shared-memory backing is a permitted integration-resource exception, even when Zig issues the OS calls.
Prefer fixed-size pools that the application reuses.
Resource creation or recreation is permitted when it makes integration much simpler than startup-only mappings.
Document that resource lifecycle separately. Manage it separately from application storage.

The surrounding Zig rendering state, monitor records, buffer records and queues must remain static.
Do not use the Wayland exception as a general application heap or transcript store.
