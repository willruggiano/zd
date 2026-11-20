const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    // XDG XML supplies interface metadata referenced by layer-shell.
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const wlr_protocols = b.run(&.{ pkg_config, "--variable=pkgdatadir", "wlr-protocols" });
    scanner.addCustomProtocol(.{ .cwd_relative = b.pathJoin(&.{
        std.mem.trim(u8, wlr_protocols, &std.ascii.whitespace),
        "unstable/wlr-layer-shell-unstable-v1.xml",
    }) });
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    // Generate implemented versions, not the newest XML versions.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 1);
    scanner.generate("wl_output", 3);
    scanner.generate("zwlr_layer_shell_v1", 1);
    scanner.generate("ext_data_control_manager_v1", 1);
    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("c", b.createModule(.{ .root_source_file = b.path("generated/c.zig"), .target = target, .optimize = optimize }));
    root.addImport("wayland", wayland);
    root.linkSystemLibrary("wayland-client", .{});
    root.linkSystemLibrary("libpipewire-0.3", .{});
    // libspa exports helpers that translate-c cannot translate correctly.
    // Its pkg-config file supplies the directory, but no linker flags.
    const spa_dir = b.run(&.{ pkg_config, "--variable=plugindir", "libspa-0.2" });
    root.addLibraryPath(.{ .cwd_relative = std.mem.trim(u8, spa_dir, &std.ascii.whitespace) });
    root.linkSystemLibrary("spa", .{ .use_pkg_config = .no });
    root.linkSystemLibrary("whisper", .{});
    // nixpkgs exposes the system ggml headers/library directory via llama.pc.
    root.linkSystemLibrary("llama", .{});
    const exe = b.addExecutable(.{ .name = "dictation", .root_module = root });
    // CUDA libraries need the host driver outside the build sandbox.
    // Keep direct application symbols strict, including when this option is set.
    exe.linker_allow_shlib_undefined = b.option(bool, "allow-shlib-undefined", "Allow unresolved symbols in shared libraries") orelse false;
    exe.each_lib_rpath = true;
    b.installArtifact(exe);
    const wayland_dependency = b.dependency("wayland", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(wayland_dependency.path("LICENSE"), "share/licenses/zig-wayland/LICENSE").step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Run deterministic Zig tests").dependOn(&b.addRunArtifact(tests).step);
}
