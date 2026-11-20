const std = @import("std");
const c = @import("c");
const protocols = @import("wayland").client;
const wl = protocols.wl;
const zwlr = protocols.zwlr;
const ext = protocols.ext;
const sizes = @import("config.zig").sizes;
const Indicator = @import("dictation.zig").Indicator;
const platform = @import("platform.zig");
const clipboard = @import("clipboard.zig");
pub const Clipboard = clipboard.Clipboard(sizes.transcript_bytes, sizes.clipboard_slots, sizes.transfers, *ext.DataControlSourceV1);

// Fixed 2x raster density: geometry/scale changes remain compositor-managed.
// No resize-time pool or retired-frame queue is needed; logical size is 160x40.
const rendering = @import("feedback.zig");
const density = rendering.density;
const width = rendering.width;
const height = rendering.height;
const frame_bytes = width * height * 4;
pub const backing_per_output = rendering.backing_per_output;
pub const backing_bytes = sizes.output_slots * backing_per_output;
const Feedback = @import("dictation.zig").Feedback(sizes.output_slots);
const mime = "text/plain;charset=utf-8";

pub const Desktop = struct {
    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    shell: ?*zwlr.LayerShellV1 = null,
    manager: ?*ext.DataControlManagerV1 = null,
    device: ?*ext.DataControlDeviceV1 = null,
    globals: [5]u32 = @splat(0),
    monitors: [sizes.output_slots]Monitor = @splat(.{}),
    feedback: Feedback = .{},
    clipboard: Clipboard = .{},
    failed: ?anyerror = null,

    const Frame = struct { buffer: ?*wl.Buffer = null, busy: bool = false };
    const Monitor = struct {
        owner: ?*Desktop = null,
        id: u32 = 0,
        output: ?*wl.Output = null,
        surface: ?*wl.Surface = null,
        layer: ?*zwlr.LayerSurfaceV1 = null,
        pool: ?*wl.ShmPool = null,
        pixels: ?[*]u32 = null,
        frames: [rendering.frame_count]Frame = @splat(.{}),
        configured: bool = false,

        fn create(self: *Monitor) !void {
            const desktop = self.owner.?;
            self.surface = desktop.compositor.?.createSurface() catch return error.WaylandResource;
            const region = desktop.compositor.?.createRegion() catch return error.WaylandResource;
            self.surface.?.setInputRegion(region);
            region.destroy();
            self.surface.?.setBufferScale(density);
            self.layer = desktop.shell.?.getLayerSurface(self.surface.?, self.output, .overlay, "dictation") catch return error.WaylandResource;
            self.layer.?.setListener(*Monitor, layerEvent, self);
            self.layer.?.setSize(width / density, height / density);
            self.layer.?.setAnchor(.{ .bottom = true });
            self.layer.?.setMargin(0, 0, 24, 0);
            self.layer.?.setExclusiveZone(0);
            self.layer.?.setKeyboardInteractivity(.none);
            try self.createBacking();
            self.surface.?.commit();
        }
        fn createBacking(self: *Monitor) !void {
            const fd = c.memfd_create("dictation-indicator", c.MFD_CLOEXEC);
            if (fd < 0) return error.WaylandBacking;
            defer _ = c.close(fd);
            if (c.ftruncate(fd, backing_per_output) != 0) return error.WaylandBacking;
            const mapping = c.mmap(null, backing_per_output, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
            if (mapping == c.MAP_FAILED) return error.WaylandBacking;
            self.pixels = @ptrCast(@alignCast(mapping));
            self.pool = self.owner.?.shm.?.createPool(fd, backing_per_output) catch return error.WaylandResource;
            for (&self.frames, 0..) |*frame, i| {
                frame.buffer = self.pool.?.createBuffer(@intCast(i * frame_bytes), width, height, width * 4, .argb8888) catch return error.WaylandResource;
                frame.buffer.?.setListener(*Frame, bufferEvent, frame);
            }
        }
        fn closeSurface(self: *Monitor) void {
            // Do not reuse the old backing, even if a compositor still holds it.
            // Destroy proxies before reusing listener slots: libwayland discards
            // their queued callbacks. munmap drops only OUR mapping; the server's
            // fd/mapping stays valid until it releases its own reference.
            if (self.layer) |v| v.destroy();
            if (self.surface) |v| v.destroy();
            for (&self.frames) |*frame| {
                if (frame.buffer) |v| v.destroy();
                frame.* = .{};
            }
            if (self.pool) |v| v.destroy();
            if (self.pixels) |v| _ = c.munmap(v, backing_per_output);
            self.layer = null;
            self.surface = null;
            self.pool = null;
            self.pixels = null;
            self.configured = false;
        }
        fn deinit(self: *Monitor) void {
            self.closeSurface();
            if (self.output) |v| {
                if (v.getVersion() >= 3) v.release() else v.destroy();
            }
            self.* = .{};
        }
    };
    pub fn init(self: *Desktop) !void {
        c.wl_log_set_handler_client(sanitizedLog);
        self.display = wl.Display.connect(null) catch return error.WaylandConnection;
        self.registry = self.display.?.getRegistry() catch return error.WaylandResource;
        self.registry.?.setListener(*Desktop, registryEvent, self);
        if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandConnection;
        if (self.failed) |reason| return reason;
        if (self.shell == null) return error.MissingLayerShell;
        if (self.manager == null) return error.MissingDataControl;
        if (self.compositor == null or self.shm == null or self.seat == null) return error.MissingWaylandCore;
        self.device = self.manager.?.getDataDevice(self.seat.?) catch return error.WaylandResource;
        self.device.?.setListener(*Desktop, deviceEvent, self);
        try self.syncOutputs();
        if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandConnection;
        if (self.failed) |reason| return reason;
    }

    fn syncOutputs(self: *Desktop) !void {
        for (&self.monitors) |*monitor| {
            if (monitor.output != null and monitor.surface == null) try monitor.create();
        }
    }

    pub fn deinit(self: *Desktop) void {
        self.clipboard.deinit(self);
        for (&self.monitors) |*monitor| monitor.deinit();
        if (self.device) |v| v.destroy();
        if (self.manager) |v| v.destroy();
        // Bound shell v1 has no destroy request (introduced in v3).
        if (self.shell) |v| v.destroy();
        if (self.seat) |v| v.destroy();
        if (self.shm) |v| v.destroy();
        if (self.compositor) |v| v.destroy();
        if (self.registry) |v| v.destroy();
        if (self.display) |v| v.disconnect();
    }

    pub fn show(self: *Desktop, state: Indicator) void {
        self.feedback.show(state, platform.now());
    }
    pub fn level(self: *Desktop, value: f32) void {
        self.feedback.level(value, platform.now());
    }
    pub fn publish(self: *Desktop, value: []const u8) bool {
        if (self.failed != null) return false;
        return self.clipboard.publish(value, self);
    }

    pub fn tick(self: *Desktop, now: i64) void {
        if (self.failed != null) return;
        self.syncOutputs() catch |reason| {
            self.failed = reason;
            return;
        };
        self.clipboard.tick(now, self);
        self.feedback.tick(now, self);
    }
    pub fn draw(self: *Desktop, id: u32, phase: Indicator, volume: u8) bool {
        for (&self.monitors) |*monitor| {
            if (monitor.id != id or !monitor.configured) continue;
            for (&monitor.frames, 0..) |*frame, i| {
                if (frame.busy) continue;
                paint(monitor.pixels.?[i * width * height ..][0 .. width * height], phase, volume);
                monitor.surface.?.attach(frame.buffer, 0, 0);
                monitor.surface.?.damage(0, 0, width / density, height / density);
                monitor.surface.?.commit();
                frame.busy = true;
                return true;
            }
        }
        return false;
    }

    // Native clipboard I/O boundary. All application ownership/transfer state is
    // in Clipboard, within the typed whole-program Storage aggregate.
    pub fn create(self: *Desktop) ?*ext.DataControlSourceV1 {
        const source = self.manager.?.createDataSource() catch return null;
        source.setListener(*Desktop, sourceEvent, self);
        source.offer(mime);
        source.offer("text/plain");
        return source;
    }
    pub fn select(self: *Desktop, source: *ext.DataControlSourceV1) bool {
        self.device.?.setSelection(source);
        // No publication acknowledgement. Success means queued, not pasted.
        const result = self.display.?.flush();
        if (result != .SUCCESS and result != .AGAIN) {
            self.failed = error.WaylandDisconnected;
            return false;
        }
        return true;
    }
    pub fn destroy(_: *Desktop, source: *ext.DataControlSourceV1) void {
        source.destroy();
    }
    pub fn prepare(_: *Desktop, fd: i32) bool {
        // O_NONBLOCK does not prevent regular-file/device writes from blocking.
        // Readers must supply a pipe or socket; reject other sinks, never stall capture.
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0) return false;
        const kind = stat.st_mode & c.S_IFMT;
        if (kind != c.S_IFIFO and kind != c.S_IFSOCK) return false;
        const flags = c.fcntl(fd, c.F_GETFL);
        return flags >= 0 and c.fcntl(fd, c.F_SETFL, flags | @as(c_int, c.O_NONBLOCK)) == 0;
    }
    pub fn write(_: *Desktop, fd: i32, bytes: []const u8) clipboard.Write {
        const n = c.write(fd, bytes.ptr, bytes.len);
        if (n >= 0) return .{ .progress = @intCast(n) };
        const err = platform.errno();
        return if (err == c.EAGAIN or err == c.EINTR) .blocked else .failed;
    }
    pub fn close(_: *Desktop, fd: i32) void {
        _ = c.close(fd);
    }

    fn paint(pixels: []u32, phase: Indicator, volume: u8) void {
        @memset(pixels, 0);
        if (phase == .idle) return;
        const color: u32 = switch (phase) {
            .recording => 0xffeeeeee,
            .finalizing => 0xff6699ff,
            .loading => 0xffcc99ff,
            .success => 0xff66dd88,
            .no_speech => 0xffffcc55,
            .failure => 0xffff6677,
            .idle => unreachable,
        };
        for (0..height) |py| for (0..width) |px| {
            const x = px / density;
            const y = py / density;
            const dx: i32 = if (x < 20) @as(i32, @intCast(x)) - 20 else if (x >= 140) @as(i32, @intCast(x)) - 139 else 0;
            const dy = @as(i32, @intCast(y)) - 20;
            if (dx * dx + dy * dy <= 400) pixels[py * width + px] = 0xee181818;
            if (x >= 48 and x < 113 and (x - 48) % 14 < 7) {
                const bar = (x - 48) / 14;
                const envelope: usize = if (bar == 2) 24 else if (bar == 1 or bar == 3) 18 else 12;
                const bar_height: usize = switch (phase) {
                    .recording => 4 + @as(usize, volume) * envelope / 24,
                    .loading => if (bar % 2 == 0) 6 else 18,
                    .finalizing => 8 + bar * 4,
                    .success => 20,
                    .no_speech => 4,
                    .failure => if (bar % 2 == 0) 24 else 8,
                    .idle => unreachable,
                };
                if (y >= 20 - bar_height / 2 and y < 20 + bar_height / 2) pixels[py * width + px] = color;
            }
        };
    }
};

// Listener userdata borrows fixed Storage records. Destroy each proxy before
// its record can be reused; libwayland discards events for destroyed proxies.
fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Desktop) void {
    switch (event) {
        .global => |value| global(self, registry, value.name, value.interface, value.version),
        .global_remove => |value| removed(self, value.name),
    }
}
fn global(self: *Desktop, registry: *wl.Registry, name: u32, interface: [*:0]const u8, version: u32) void {
    const value = std.mem.span(interface);
    if (self.failed != null) return;
    if (std.mem.eql(u8, value, "wl_output")) {
        self.feedback.outputAdded(name) catch |reason| {
            self.failed = reason;
            return;
        };
        for (&self.monitors) |*monitor| if (monitor.id == 0) {
            monitor.* = .{ .owner = self, .id = name };
            monitor.output = registry.bind(name, wl.Output, version) catch {
                self.failed = error.WaylandResource;
                return;
            };
            monitor.output.?.setListener(*Desktop.Monitor, outputEvent, monitor);
            return;
        };
        self.failed = error.OutputCapacity;
        return;
    }
    // bind caps the advertised version at the generated interface version.
    if (std.mem.eql(u8, value, "wl_compositor") and self.compositor == null and version >= 3) {
        self.compositor = registry.bind(name, wl.Compositor, version) catch null;
        self.globals[0] = name;
    } else if (std.mem.eql(u8, value, "wl_shm") and self.shm == null) {
        self.shm = registry.bind(name, wl.Shm, version) catch null;
        self.globals[1] = name;
    } else if (std.mem.eql(u8, value, "wl_seat") and self.seat == null) {
        self.seat = registry.bind(name, wl.Seat, version) catch null;
        self.globals[2] = name;
    } else if (std.mem.eql(u8, value, "zwlr_layer_shell_v1") and self.shell == null) {
        self.shell = registry.bind(name, zwlr.LayerShellV1, version) catch null;
        self.globals[3] = name;
    } else if (std.mem.eql(u8, value, "ext_data_control_manager_v1") and self.manager == null) {
        self.manager = registry.bind(name, ext.DataControlManagerV1, version) catch null;
        self.globals[4] = name;
    }
}
fn removed(self: *Desktop, name: u32) void {
    for (&self.monitors) |*monitor| if (monitor.id == name) {
        self.feedback.outputRemoved(name);
        monitor.deinit();
        return;
    };
    for (self.globals) |id| if (id == name) {
        self.failed = error.WaylandDisconnected;
    };
}
fn layerEvent(layer: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, monitor: *Desktop.Monitor) void {
    switch (event) {
        .configure => |value| {
            layer.ackConfigure(value.serial);
            monitor.configured = true;
            monitor.owner.?.feedback.outputChanged(monitor.id);
        },
        // Output removal and closed can arrive in either order. Recreate only
        // if the registry still advertises this output on the next loop.
        .closed => monitor.closeSurface(),
    }
}
fn outputEvent(_: *wl.Output, event: wl.Output.Event, monitor: *Desktop.Monitor) void {
    switch (event) {
        .geometry, .mode => {},
        .done, .scale => monitor.owner.?.feedback.outputChanged(monitor.id),
    }
}
fn bufferEvent(_: *wl.Buffer, event: wl.Buffer.Event, frame: *Desktop.Frame) void {
    switch (event) {
        .release => frame.busy = false,
    }
}
fn deviceEvent(_: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, self: *Desktop) void {
    switch (event) {
        // We only publish. Do not retain incoming offers or external text.
        .data_offer => |value| value.id.destroy(),
        .selection, .primary_selection => {},
        .finished => self.failed = error.WaylandDisconnected,
    }
}
fn sourceEvent(source: *ext.DataControlSourceV1, event: ext.DataControlSourceV1.Event, self: *Desktop) void {
    switch (event) {
        .cancelled => self.clipboard.cancelled(source, self),
        .send => |value| {
            const requested_mime = std.mem.span(value.mime_type);
            if (std.mem.eql(u8, requested_mime, mime) or std.mem.eql(u8, requested_mime, "text/plain")) {
                self.clipboard.send(source, value.fd, platform.now(), self);
            } else self.close(value.fd);
        },
    }
}

// va_list is passed differently on x86_64 (array decay) and aarch64 (struct).
// Use the translated callback parameter, not the va_list typedef itself.
const LogHandler = @typeInfo(c.wl_log_func_t).optional.child;
const LogArgs = @typeInfo(@typeInfo(LogHandler).pointer.child).@"fn".param_types[1].?;
fn sanitizedLog(_: [*c]const u8, _: LogArgs) callconv(.c) void {
    platform.diagnostic("dictation: Wayland library diagnostic (details suppressed)\n");
}
