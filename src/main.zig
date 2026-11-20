const std = @import("std");
const c = @import("c");
const platform = @import("platform.zig");
const wayland = @import("wayland.zig");
const control = @import("control.zig");
const dictation = @import("dictation.zig");
const audio = @import("audio.zig");
const inference = @import("inference.zig");
const options = @import("options.zig");
const sizes = @import("config.zig").sizes;

// Every mutable long-lived application workspace, including client-only state,
// contributes to this actual typed layout. @sizeOf includes alignment/padding.
const Storage = struct {
    session: dictation.Session(sizes.transcript_bytes, sizes.windows()) = .{},
    desktop: wayland.Desktop = .{},
    server: control.Control = .{},
    client: control.Toggle = .{},
    capture: audio.Capture = .{},
    worker: inference.Worker = .{},
    fixture: bool = false,
    fixture_due: i64 = 0,
    fixture_operation: dictation.Operation = .{ .session = 0, .window = 0 },
    in_audio_callback: bool = false,
    stop_capture: bool = false,
    model_reported: bool = false,
    pollfds: [3]c.pollfd = undefined,
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
        const output = std.mem.print(&storage.formatting, "static_bytes={d}\nalignment={d}\nsession_bytes={d}\nwayland_bytes={d}\nclipboard_bytes={d}\nclipboard_offer_bytes={d}\nclipboard_transfer_bytes={d}\ncontrol_bytes={d}\nclient_bytes={d}\ntranscript_bytes={d}\nclipboard_slots={d}\ncontrol_clients={d}\ntransfers={d}\nwayland_backing_bytes={d}\naudio_samples={d}\naudio_windows={d}\nwindow_min_samples={d}\npause_samples={d}\ncontext_bytes={d}\ndevice_slots={d}\nworker_stack_bytes={d}\ninference_threads={d}\ncapture_bytes={d}\nworker_bytes={d}\nretained_inference_windows=1\nreplacement_audio_windows={d}\noperation_bytes={d}\n", .{ @sizeOf(Storage), @alignOf(Storage), @sizeOf(@TypeOf(storage.session)), @sizeOf(wayland.Desktop), @sizeOf(wayland.Clipboard), @sizeOf(@TypeOf(storage.desktop.clipboard.offers)), @sizeOf(@TypeOf(storage.desktop.clipboard.transfers)), @sizeOf(control.Control), @sizeOf(control.Toggle), sizes.transcript_bytes, sizes.clipboard_slots, sizes.control_clients, sizes.transfers, wayland.backing_bytes, sizes.audio_samples, sizes.audio_windows, sizes.window_min_samples, sizes.pause_samples, sizes.context_bytes, sizes.device_slots, sizes.worker_stack_bytes, sizes.inference_threads, @sizeOf(audio.Capture), @sizeOf(inference.Worker), sizes.audio_windows - 1, @sizeOf(dictation.Operation) }) catch unreachable;
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
    if (argc >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "daemon") and (argc == 2 or (argc == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "--fixture")))) {
        storage.fixture = argc == 3;
        _ = c.signal(c.SIGTERM, stop);
        _ = c.signal(c.SIGINT, stop);
        daemon() catch |err| {
            report(err);
            return 1;
        };
        return 0;
    }
    platform.diagnostic("usage: dictation daemon [--fixture] | toggle | footprint\n--fixture explicitly simulates capture and inference.\n");
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
    defer {
        storage.capture.stop();
        storage.worker.deinit();
        storage.session.shutdown();
        if (!storage.fixture) storage.capture.deinit();
    }
    var effects: Effects = .{};
    try server.init();
    try desktop.init();
    try storage.session.connect(.{ .layer_shell = desktop.shell != null, .data_control = desktop.manager != null });
    if (storage.fixture) {
        storage.session.modelLoaded(true, &effects);
        platform.diagnostic("dictation: FIXTURE audio/inference; native Wayland ready\n");
    } else {
        try storage.capture.init(samplesReceived);
        try storage.worker.start(options.model_path, options.cuda);
        platform.diagnostic("dictation: model loading; native Wayland ready\n");
    }
    while (@atomicLoad(c.sig_atomic_t, &storage.stopping, .seq_cst) == 0) {
        if (desktop.failed) return error.WaylandDisconnected;
        const now = platform.now();
        if (!storage.fixture) {
            storage.capture.tick();
            if (storage.capture.removed_source) |source| {
                storage.session.sourceRemoved(source, &effects);
                storage.capture.removed_source = null;
            }
            if (storage.stop_capture) {
                storage.capture.stop();
                storage.stop_capture = false;
            }
            if (storage.capture.failed or storage.capture.stream_failed) {
                storage.session.captureFailed(&effects);
            }
            switch (storage.worker.status()) {
                .loaded => {
                    storage.worker.release();
                    storage.session.modelLoaded(true, &effects);
                    platform.diagnostic(if (options.cuda) "dictation: model ready (GPU requested; CPU fallback allowed)\n" else "dictation: model ready (explicit CPU build)\n");
                },
                .load_failed => if (!storage.model_reported) {
                    storage.model_reported = true;
                    storage.session.modelLoaded(false, &effects);
                    report(error.ModelBackendInitialization);
                },
                .complete, .failed => |state| {
                    if (state == .complete) {
                        storage.session.complete(storage.worker.operation, storage.worker.result[0..storage.worker.result_len], &effects);
                        platform.diagnostic("dictation: window decoded\n");
                    } else {
                        storage.session.inferenceFailed(storage.worker.operation, storage.worker.problem, &effects);
                    }
                    storage.worker.release();
                    storage.session.advance(&effects);
                },
                else => {},
            }
        }
        server.accept();
        server.tick(&storage.session, &effects, now);
        if (storage.fixture_due != 0 and now >= storage.fixture_due) {
            storage.fixture_due = 0;
            storage.session.complete(storage.fixture_operation, "Fixture dictation result.", &effects);
            storage.session.advance(&effects);
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
            .{ .fd = if (storage.fixture) -1 else c.zd_loop_fd(storage.capture.loop), .events = c.POLLIN, .revents = 0 },
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

const Effects = struct {
    pub fn problem(_: *Effects, reason: anyerror) void {
        report(reason);
    }
    pub fn defaultSource(_: *Effects) ?u64 {
        return if (storage.fixture) 1 else storage.capture.defaultSource();
    }
    pub fn recording(_: *Effects, source: ?u64) bool {
        if (storage.fixture) return true;
        if (source) |id| return storage.capture.start(id);
        if (storage.in_audio_callback) storage.stop_capture = true else storage.capture.stop();
        return true;
    }
    pub fn decode(_: *Effects, operation: dictation.Operation, samples: []const f32, context: []const u8) bool {
        if (storage.fixture) {
            if (storage.fixture_due != 0) return false;
            storage.fixture_operation = operation;
            storage.fixture_due = platform.now() + 350;
            return true;
        }
        const accepted = storage.worker.decode(operation, samples, context);
        if (accepted) platform.diagnostic("dictation: decoding window\n");
        return accepted;
    }
    pub fn cancel(_: *Effects, operation: dictation.Operation) void {
        if (!storage.fixture) storage.worker.cancel(operation);
        // Fixture completion remains pending to simulate a delayed unwind.
        platform.diagnostic("dictation: inference cancellation requested\n");
    }
    pub fn show(self: *Effects, phase: dictation.Indicator) void {
        storage.desktop.show(phase);
        // Supply explicit synthetic audio only in --fixture mode.
        if (storage.fixture and phase == .recording) storage.session.audio(&.{0.1}, self);
        switch (phase) {
            .recording => platform.diagnostic("dictation: recording\n"),
            .finalizing => platform.diagnostic("dictation: finalizing; microphone closed\n"),
            .success => platform.diagnostic("dictation: copied\n"),
            .failure => platform.diagnostic("dictation: session failed (capture, inference, publication or capacity)\n"),
            .no_speech => platform.diagnostic("dictation: no speech\n"),
            else => {},
        }
    }
    pub fn publish(_: *Effects, text: []const u8) bool {
        return storage.desktop.publish(text);
    }
};
fn samplesReceived(samples: []const f32) void {
    storage.in_audio_callback = true;
    defer storage.in_audio_callback = false;
    var effects: Effects = .{};
    storage.session.audio(samples, &effects);
}
