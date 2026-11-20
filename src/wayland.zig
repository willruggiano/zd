const std = @import("std");
const c = @import("c");
const sizes = @import("config.zig").sizes;
const Indicator = @import("dictation.zig").Indicator;
const platform = @import("platform.zig");
const clipboard = @import("clipboard.zig");
pub const Clipboard = clipboard.Clipboard(sizes.transcript_bytes, sizes.clipboard_slots, sizes.transfers, *c.ext_data_control_source_v1);

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
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    shell: ?*c.zwlr_layer_shell_v1 = null,
    manager: ?*c.ext_data_control_manager_v1 = null,
    device: ?*c.ext_data_control_device_v1 = null,
    globals: [5]u32 = @splat(0),
    monitors: [sizes.output_slots]Monitor = @splat(.{}),
    feedback: Feedback = .{},
    clipboard: Clipboard = .{},
    failed: ?anyerror = null,

    const Frame = struct { buffer: ?*c.wl_buffer = null, busy: bool = false };
    const Monitor = struct {
        owner: ?*Desktop = null,
        id: u32 = 0,
        output: ?*c.wl_output = null,
        surface: ?*c.wl_surface = null,
        layer: ?*c.zwlr_layer_surface_v1 = null,
        pool: ?*c.wl_shm_pool = null,
        pixels: ?[*]u32 = null,
        frames: [rendering.frame_count]Frame = @splat(.{}),
        configured: bool = false,

        fn create(self: *Monitor) !void {
            const desktop = self.owner.?;
            self.surface = c.wl_compositor_create_surface(desktop.compositor) orelse return error.WaylandResource;
            const region = c.wl_compositor_create_region(desktop.compositor) orelse return error.WaylandResource;
            c.wl_surface_set_input_region(self.surface, region);
            c.wl_region_destroy(region);
            c.wl_surface_set_buffer_scale(self.surface, density);
            self.layer = c.zwlr_layer_shell_v1_get_layer_surface(desktop.shell, self.surface, self.output, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "dictation") orelse return error.WaylandResource;
            if (c.zwlr_layer_surface_v1_add_listener(self.layer, &layer_listener, self) != 0) return error.WaylandResource;
            c.zwlr_layer_surface_v1_set_size(self.layer, width / density, height / density);
            c.zwlr_layer_surface_v1_set_anchor(self.layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM);
            c.zwlr_layer_surface_v1_set_margin(self.layer, 0, 0, 24, 0);
            c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer, 0);
            c.zwlr_layer_surface_v1_set_keyboard_interactivity(self.layer, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
            try self.createBacking();
            c.wl_surface_commit(self.surface);
        }
        fn createBacking(self: *Monitor) !void {
            const fd = c.memfd_create("dictation-indicator", c.MFD_CLOEXEC);
            if (fd < 0) return error.WaylandBacking;
            defer _ = c.close(fd);
            if (c.ftruncate(fd, backing_per_output) != 0) return error.WaylandBacking;
            const mapping = c.mmap(null, backing_per_output, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
            if (mapping == c.MAP_FAILED) return error.WaylandBacking;
            self.pixels = @ptrCast(@alignCast(mapping));
            self.pool = c.wl_shm_create_pool(self.owner.?.shm, fd, backing_per_output) orelse return error.WaylandResource;
            for (&self.frames, 0..) |*frame, i| {
                frame.buffer = c.wl_shm_pool_create_buffer(self.pool, @intCast(i * frame_bytes), width, height, width * 4, c.WL_SHM_FORMAT_ARGB8888) orelse return error.WaylandResource;
                if (c.wl_buffer_add_listener(frame.buffer, &buffer_listener, frame) != 0) return error.WaylandResource;
            }
        }
        fn closeSurface(self: *Monitor) void {
            // Do not reuse the old backing, even if a compositor still holds it.
            // Destroy proxies before reusing listener slots: libwayland discards
            // their queued callbacks. munmap drops only OUR mapping; the server's
            // fd/mapping stays valid until it releases its own reference.
            if (self.layer) |v| c.zwlr_layer_surface_v1_destroy(v);
            if (self.surface) |v| c.wl_surface_destroy(v);
            for (&self.frames) |*frame| {
                if (frame.buffer) |v| c.wl_buffer_destroy(v);
                frame.* = .{};
            }
            if (self.pool) |v| c.wl_shm_pool_destroy(v);
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
                if (c.wl_output_get_version(v) >= 3) c.wl_output_release(v) else c.wl_output_destroy(v);
            }
            self.* = .{};
        }
    };
    pub fn init(self: *Desktop) !void {
        c.wl_log_set_handler_client(sanitizedLog);
        self.display = c.wl_display_connect(null) orelse return error.WaylandConnection;
        self.registry = c.wl_display_get_registry(self.display) orelse return error.WaylandResource;
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) return error.WaylandResource;
        if (c.wl_display_roundtrip(self.display) < 0) return error.WaylandConnection;
        if (self.failed) |reason| return reason;
        if (self.shell == null) return error.MissingLayerShell;
        if (self.manager == null) return error.MissingDataControl;
        if (self.compositor == null or self.shm == null or self.seat == null) return error.MissingWaylandCore;
        self.device = c.ext_data_control_manager_v1_get_data_device(self.manager, self.seat) orelse return error.WaylandResource;
        if (c.ext_data_control_device_v1_add_listener(self.device, &device_listener, self) != 0) return error.WaylandResource;
        try self.syncOutputs();
        if (c.wl_display_roundtrip(self.display) < 0) return error.WaylandConnection;
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
        if (self.device) |v| c.ext_data_control_device_v1_destroy(v);
        if (self.manager) |v| c.ext_data_control_manager_v1_destroy(v);
        // Bound shell v1 has no destroy request (introduced in v3).
        if (self.shell) |v| c.wl_proxy_destroy(@ptrCast(v));
        if (self.seat) |v| c.wl_seat_destroy(v);
        if (self.shm) |v| c.wl_shm_destroy(v);
        if (self.compositor) |v| c.wl_compositor_destroy(v);
        if (self.registry) |v| c.wl_registry_destroy(v);
        if (self.display) |v| c.wl_display_disconnect(v);
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
                c.wl_surface_attach(monitor.surface, frame.buffer, 0, 0);
                c.wl_surface_damage(monitor.surface, 0, 0, width / density, height / density);
                c.wl_surface_commit(monitor.surface);
                frame.busy = true;
                return true;
            }
        }
        return false;
    }

    // Native clipboard I/O boundary. All application ownership/transfer state is
    // in Clipboard, within the typed whole-program Storage aggregate.
    pub fn create(self: *Desktop) ?*c.ext_data_control_source_v1 {
        const source = c.ext_data_control_manager_v1_create_data_source(self.manager) orelse return null;
        if (c.ext_data_control_source_v1_add_listener(source, &source_listener, self) != 0) {
            c.ext_data_control_source_v1_destroy(source);
            return null;
        }
        c.ext_data_control_source_v1_offer(source, mime);
        c.ext_data_control_source_v1_offer(source, "text/plain");
        return source;
    }
    pub fn select(self: *Desktop, source: *c.ext_data_control_source_v1) bool {
        c.ext_data_control_device_v1_set_selection(self.device, source);
        // No publication acknowledgement. Success means queued, not pasted.
        if (c.wl_display_flush(self.display) < 0 and platform.errno() != c.EAGAIN) {
            self.failed = error.WaylandDisconnected;
            return false;
        }
        return true;
    }
    pub fn destroy(_: *Desktop, source: *c.ext_data_control_source_v1) void {
        c.ext_data_control_source_v1_destroy(source);
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

fn cast(comptime T: type, data: ?*anyopaque) *T {
    return @ptrCast(@alignCast(data.?));
}
fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const self = cast(Desktop, data);
    const value = std.mem.span(interface);
    if (self.failed != null) return;
    if (std.mem.eql(u8, value, "wl_output")) {
        self.feedback.outputAdded(name) catch |reason| {
            self.failed = reason;
            return;
        };
        for (&self.monitors) |*monitor| if (monitor.id == 0) {
            monitor.* = .{ .owner = self, .id = name };
            monitor.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 3)));
            if (monitor.output == null or c.wl_output_add_listener(monitor.output, &output_listener, monitor) != 0) self.failed = error.WaylandResource;
            return;
        };
        self.failed = error.OutputCapacity;
        return;
    }
    if (std.mem.eql(u8, value, "wl_compositor") and self.compositor == null and version >= 3) {
        self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        self.globals[0] = name;
    } else if (std.mem.eql(u8, value, "wl_shm") and self.shm == null) {
        self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        self.globals[1] = name;
    } else if (std.mem.eql(u8, value, "wl_seat") and self.seat == null) {
        self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
        self.globals[2] = name;
    } else if (std.mem.eql(u8, value, "zwlr_layer_shell_v1") and self.shell == null) {
        self.shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, 1));
        self.globals[3] = name;
    } else if (std.mem.eql(u8, value, "ext_data_control_manager_v1") and self.manager == null) {
        self.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.ext_data_control_manager_v1_interface, 1));
        self.globals[4] = name;
    }
}
fn removed(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    const self = cast(Desktop, data);
    for (&self.monitors) |*monitor| if (monitor.id == name) {
        self.feedback.outputRemoved(name);
        monitor.deinit();
        return;
    };
    for (self.globals) |id| if (id == name) {
        self.failed = error.WaylandDisconnected;
    };
}
fn configure(data: ?*anyopaque, layer: ?*c.zwlr_layer_surface_v1, serial: u32, _: u32, _: u32) callconv(.c) void {
    c.zwlr_layer_surface_v1_ack_configure(layer, serial);
    const monitor = cast(Desktop.Monitor, data);
    monitor.configured = true;
    monitor.owner.?.feedback.outputChanged(monitor.id);
}
fn closed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    // Output removal and closed may arrive in either order. Recreate on the
    // next loop only if the registry still advertises this output.
    cast(Desktop.Monitor, data).closeSurface();
}
fn outputGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn outputMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn outputDone(data: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {
    const monitor = cast(Desktop.Monitor, data);
    monitor.owner.?.feedback.outputChanged(monitor.id);
}
fn outputScale(data: ?*anyopaque, output: ?*c.wl_output, _: i32) callconv(.c) void {
    outputDone(data, output);
}
const output_listener: c.wl_output_listener = .{ .geometry = outputGeometry, .mode = outputMode, .done = outputDone, .scale = outputScale, .name = null, .description = null };
fn released(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
    cast(Desktop.Frame, data).busy = false;
}
fn offered(_: ?*anyopaque, _: ?*c.ext_data_control_device_v1, offer: ?*c.ext_data_control_offer_v1) callconv(.c) void {
    // We only publish; destroy incoming offers immediately, including external text.
    c.ext_data_control_offer_v1_destroy(offer);
}
fn selection(_: ?*anyopaque, _: ?*c.ext_data_control_device_v1, _: ?*c.ext_data_control_offer_v1) callconv(.c) void {}
fn finished(data: ?*anyopaque, _: ?*c.ext_data_control_device_v1) callconv(.c) void {
    cast(Desktop, data).failed = error.WaylandDisconnected;
}
fn cancelled(data: ?*anyopaque, source: ?*c.ext_data_control_source_v1) callconv(.c) void {
    const self = cast(Desktop, data);
    self.clipboard.cancelled(source.?, self);
}
fn send(data: ?*anyopaque, source: ?*c.ext_data_control_source_v1, requested: [*c]const u8, fd: i32) callconv(.c) void {
    const self = cast(Desktop, data);
    const requested_mime = std.mem.span(requested);
    if (std.mem.eql(u8, requested_mime, mime) or std.mem.eql(u8, requested_mime, "text/plain")) {
        self.clipboard.send(source.?, fd, platform.now(), self);
    } else self.close(fd);
}
const registry_listener: c.wl_registry_listener = .{ .global = global, .global_remove = removed };
const layer_listener: c.zwlr_layer_surface_v1_listener = .{ .configure = configure, .closed = closed };
const buffer_listener: c.wl_buffer_listener = .{ .release = released };
const source_listener: c.ext_data_control_source_v1_listener = .{ .send = send, .cancelled = cancelled };
const device_listener: c.ext_data_control_device_v1_listener = .{ .data_offer = offered, .selection = selection, .finished = finished, .primary_selection = selection };

// va_list is passed differently on x86_64 (array decay) and aarch64 (struct).
// Use the translated callback parameter, not the va_list typedef itself.
const LogHandler = @typeInfo(c.wl_log_func_t).optional.child;
const LogArgs = @typeInfo(@typeInfo(LogHandler).pointer.child).@"fn".param_types[1].?;
fn sanitizedLog(_: [*c]const u8, _: LogArgs) callconv(.c) void {
    platform.diagnostic("dictation: Wayland library diagnostic (details suppressed)\n");
}
