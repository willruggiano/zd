const std = @import("std");
const Scanner = @import("wayland").Scanner;
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libc_file = b.option(std.Build.LazyPath, "libc", "Libc installation file for translation and linking");
    const wayland_xml = b.dependency("wayland_xml", .{}).path("protocol/wayland.xml");
    const wayland_protocols = b.dependency("wayland_protocols", .{});
    const wlr_protocols = b.dependency("wlr_protocols", .{});
    const xdg_shell_xml = wayland_protocols.path("stable/xdg-shell/xdg-shell.xml");
    const layer_shell_xml = wlr_protocols.path("unstable/wlr-layer-shell-unstable-v1.xml");
    const data_control_xml = wayland_protocols.path("staging/ext-data-control/ext-data-control-v1.xml");
    const scanner = Scanner.create(b, .{
        .wayland_xml = wayland_xml,
        .wayland_protocols = wayland_protocols.path(""),
    });
    // XDG XML supplies interface metadata referenced by layer-shell.
    scanner.addCustomProtocol(xdg_shell_xml);
    scanner.addCustomProtocol(layer_shell_xml);
    scanner.addCustomProtocol(data_control_xml);
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

    const translate_c = b.dependency("translate_c", .{});
    const c: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/interop.h"),
        .target = target,
        // Translate unoptimized headers to avoid unsupported fortified glibc wrappers.
        .optimize = .debug,
        .libc_file = libc_file,
        // Keep inline PipeWire methods and zero defaults for C structs.
        .func_bodies = true,
        .default_init = true,
        .link_system_libs = &.{
            .{ .name = "wayland-client" },
            .{ .name = "libpipewire-0.3" },
            .{ .name = "whisper" },
            // nixpkgs exposes the system ggml headers/library directory via llama.pc.
            .{ .name = "llama" },
        },
    });
    // Optimize the generated Zig with the application.
    c.mod.optimize = optimize;
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("c", c.mod);
    root.addImport("wayland", wayland);
    // libspa exports helpers that translate-c cannot translate correctly.
    // Its pkg-config file supplies the directory, but no linker flags.
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const spa_dir = b.run(&.{ pkg_config, "--variable=plugindir", "libspa-0.2" });
    root.addLibraryPath(.{ .cwd_relative = std.mem.trim(u8, spa_dir, &std.ascii.whitespace) });
    root.linkSystemLibrary("spa", .{ .use_pkg_config = .no });
    const exe = b.addExecutable(.{ .name = "dictation", .root_module = root });
    exe.setLibCFile(libc_file);
    // CUDA libraries need the host driver outside the build sandbox.
    // Keep direct application symbols strict, including when this option is set.
    exe.linker_allow_shlib_undefined = b.option(bool, "allow-shlib-undefined", "Allow unresolved symbols in shared libraries") orelse false;
    exe.each_lib_rpath = true;
    b.installArtifact(exe);
    const wayland_dependency = b.dependency("wayland", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(wayland_dependency.path("LICENSE"), "share/licenses/zig-wayland/LICENSE").step);
    b.getInstallStep().dependOn(&b.addInstallFile(translate_c.path("LICENSE"), "share/licenses/translate-c/LICENSE").step);
    // Keep each XML's copyright notice with the generated bindings.
    for ([_]struct { file: std.Build.LazyPath, name: []const u8 }{
        .{ .file = wayland_xml, .name = "wayland.xml" },
        .{ .file = xdg_shell_xml, .name = "xdg-shell.xml" },
        .{ .file = layer_shell_xml, .name = "wlr-layer-shell-unstable-v1.xml" },
        .{ .file = data_control_xml, .name = "ext-data-control-v1.xml" },
    }) |protocol| {
        b.getInstallStep().dependOn(&b.addInstallFile(protocol.file, b.pathJoin(&.{ "share/licenses/wayland-protocols", protocol.name })).step);
    }

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Run deterministic Zig tests").dependOn(&b.addRunArtifact(tests).step);
}
