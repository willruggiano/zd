const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("c", b.createModule(.{ .root_source_file = b.path("generated/c.zig"), .target = target, .optimize = optimize }));
    root.linkSystemLibrary("wayland-client", .{});
    root.linkSystemLibrary("libpipewire-0.3", .{});
    root.linkSystemLibrary("whisper", .{});
    // nixpkgs exposes the system ggml headers/library directory via llama.pc.
    root.linkSystemLibrary("llama", .{});
    root.addIncludePath(b.path("generated"));
    root.addCSourceFiles(.{ .files = &.{ "generated/layer.c", "generated/control.c", "generated/xdg.c", "src/native.c" }, .flags = &.{} });
    const exe = b.addExecutable(.{ .name = "dictation", .root_module = root });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Run deterministic Zig tests").dependOn(&b.addRunArtifact(tests).step);
}
