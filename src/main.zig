const std = @import("std");
const c = @import("c");
const platform = @import("platform.zig");
const wayland = @import("wayland.zig");
const control = @import("control.zig");
const dictation = @import("dictation.zig");
const sizes = @import("config.zig").sizes;

// Every mutable long-lived application workspace, including client-only state,
// contributes to this actual typed layout. @sizeOf includes alignment/padding.
const Storage = struct {
    session: dictation.Session(sizes.transcript_bytes) = .{},
    desktop: wayland.Desktop = .{},
    server: control.Control = .{},
    client: control.Toggle = .{},
    pollfds: [2]c.pollfd = undefined,
    formatting: [1024]u8 = undefined,
    stopping: c.sig_atomic_t = 0,
};
var storage: Storage = .{};

pub const panic = std.debug.FullPanic(fatal);
fn fatal(_: []const u8, _: ?usize) noreturn {
    platform.diagnostic("dictation: internal failure\n");
    c._exit(70);
}
fn ignore(_: c_int) callconv(.c) void {}
fn stop(_: c_int) callconv(.c) void {
    @atomicStore(c.sig_atomic_t, &storage.stopping, 1, .seq_cst);
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    _ = c.signal(c.SIGPIPE, ignore);
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "footprint")) {
        const output = std.mem.print(&storage.formatting, "static_bytes={d}\nalignment={d}\nsession_bytes={d}\nwayland_bytes={d}\ncontrol_bytes={d}\nclient_bytes={d}\ntranscript_bytes={d}\nclipboard_slots={d}\ncontrol_clients={d}\ntransfers={d}\nwayland_backing_bytes={d}\n", .{ @sizeOf(Storage), @alignOf(Storage), @sizeOf(@TypeOf(storage.session)), @sizeOf(wayland.Desktop), @sizeOf(control.Control), @sizeOf(control.Toggle), sizes.transcript_bytes, sizes.clipboard_slots, sizes.control_clients, sizes.transfers, wayland.backing_bytes }) catch unreachable;
        _ = c.write(1, output.ptr, output.len);
        return 0;
    }
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "toggle")) {
        storage.client.run(&storage.server) catch |err| {
            report(err);
            return 1;
        };
        platform.diagnostic("dictation: toggle accepted (not a copy acknowledgement)\n");
        return 0;
    }
    if (argc == 3 and std.mem.eql(u8, std.mem.span(argv[1]), "daemon") and std.mem.eql(u8, std.mem.span(argv[2]), "--fixture")) {
        _ = c.signal(c.SIGTERM, stop);
        _ = c.signal(c.SIGINT, stop);
        daemon() catch |err| {
            report(err);
            return 1;
        };
        return 0;
    }
    platform.diagnostic("usage: dictation daemon --fixture | toggle | footprint\nFixture only: no microphone capture or recognition.\n");
    return 2;
}
fn report(err: anyerror) void {
    platform.diagnostic("dictation: ");
    platform.diagnostic(@errorName(err));
    platform.diagnostic("\n");
}
fn daemon() !void {
    const desktop = &storage.desktop;
    const server = &storage.server;
    defer desktop.deinit();
    defer server.deinit();
    try server.init();
    try desktop.init();
    try storage.session.connect(.{ .layer_shell = desktop.shell != null, .data_control = desktop.manager != null });
    platform.diagnostic("dictation: FIXTURE audio/inference; native Wayland ready\n");
    while (@atomicLoad(c.sig_atomic_t, &storage.stopping, .seq_cst) == 0) {
        if (desktop.failed) return error.WaylandDisconnected;
        const now = platform.now();
        server.accept();
        server.tick(&storage.session, desktop, now);
        if (desktop.fixture_due != 0 and now >= desktop.fixture_due) {
            desktop.fixture_due = 0;
            storage.session.complete("Fixture dictation result.", desktop);
        }
        desktop.tick(now);
        while (c.wl_display_prepare_read(desktop.display) != 0) {
            if (c.wl_display_dispatch_pending(desktop.display) < 0) return error.WaylandDisconnected;
        }
        const flushed = c.wl_display_flush(desktop.display);
        if (flushed < 0 and platform.errno() != c.EAGAIN) {
            c.wl_display_cancel_read(desktop.display);
            return error.WaylandDisconnected;
        }
        storage.pollfds = .{
            .{ .fd = c.wl_display_get_fd(desktop.display), .events = @intCast(c.POLLIN | @as(c_int, if (flushed < 0) c.POLLOUT else 0)), .revents = 0 },
            .{ .fd = server.listener, .events = c.POLLIN, .revents = 0 },
        };
        const polled = c.poll(&storage.pollfds, storage.pollfds.len, 20);
        if (polled > 0 and storage.pollfds[0].revents & c.POLLIN != 0) {
            if (c.wl_display_read_events(desktop.display) < 0) return error.WaylandDisconnected;
        } else c.wl_display_cancel_read(desktop.display);
        if (polled < 0 and platform.errno() != c.EINTR) return error.EventLoop;
        if (storage.pollfds[0].revents & (c.POLLERR | c.POLLHUP) != 0) return error.WaylandDisconnected;
        if (c.wl_display_dispatch_pending(desktop.display) < 0) return error.WaylandDisconnected;
    }
}
