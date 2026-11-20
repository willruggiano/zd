const std = @import("std");
const c = @import("c");
const sizes = @import("config.zig").sizes;
const platform = @import("platform.zig");
const Identity = @import("dictation.zig").Capture;
const Node = struct { id: u32 = 0, serial: u64 = 0, present: bool = false, name: [256:0]u8 = @splat(0) };

// These inline bodies contain variable-length arrays and variadic calls that translate-c cannot translate correctly.
// libspa exports the same functions. Derive their ABI types without taking the inline functions' addresses.
const spa_json_str_object_find = @extern(*const @TypeOf(c.spa_json_str_object_find), .{ .name = "spa_json_str_object_find" });
const spa_format_audio_raw_build = @extern(*const @TypeOf(c.spa_format_audio_raw_build), .{ .name = "spa_format_audio_raw_build" });
const spa_format_audio_raw_parse = @extern(*const @TypeOf(c.spa_format_audio_raw_parse), .{ .name = "spa_format_audio_raw_parse" });

/// All callbacks execute on the daemon thread, never PipeWire's RT thread.
/// Native conversion delivers mono 16 kHz float PCM directly to the session.
pub const Capture = struct {
    initialized: bool = false,
    loop: ?*c.pw_loop = null,
    context: ?*c.pw_context = null,
    core: ?*c.pw_core = null,
    registry: ?*c.pw_registry = null,
    metadata: ?*c.pw_metadata = null,
    stream: ?*c.pw_stream = null,
    registry_hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    metadata_hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    core_hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    stream_hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    nodes: [sizes.device_slots]Node = @splat(.{}),
    default_name: [256:0]u8 = @splat(0),
    serial_text: [32:0]u8 = @splat(0),
    pod: [1024]u8 align(8) = undefined,
    selected: ?Identity = null,
    metadata_id: u32 = 0,
    failed: ?anyerror = null,
    stream_failed: ?anyerror = null,
    formatted: bool = false,
    started: bool = false,
    start_deadline: i64 = 0,
    on_samples: *const fn (Identity, []const f32) void = undefined,

    pub fn init(self: *Capture, on_samples: *const fn (Identity, []const f32) void) !void {
        self.on_samples = on_samples;
        c.pw_init(null, null);
        self.initialized = true;
        _ = c.pw_log_set_level_string("0");
        self.loop = c.pw_loop_new(null) orelse return error.PipeWireLoop;
        c.pw_loop_enter(self.loop);
        self.context = c.pw_context_new(self.loop, null, 0) orelse return error.PipeWireContext;
        self.core = c.pw_context_connect(self.context, null, 0) orelse return error.PipeWireConnection;
        if (c.pw_core_add_listener(self.core, &self.core_hook, &core_events, self) < 0) return error.PipeWireListener;
        self.registry = c.pw_core_get_registry(self.core, c.PW_VERSION_REGISTRY, 0) orelse return error.PipeWireRegistry;
        if (c.pw_registry_add_listener(self.registry, &self.registry_hook, &registry_events, self) < 0) return error.PipeWireListener;
    }
    pub fn defaultSource(self: *Capture) ?u64 {
        if (self.failed != null or self.metadata == null) return null;
        for (&self.nodes) |*node| if (node.present and std.mem.eql(u8, std.mem.sliceTo(&node.name, 0), std.mem.sliceTo(&self.default_name, 0))) return node.serial;
        return null;
    }
    pub fn start(self: *Capture, identity: Identity) bool {
        if (self.failed != null or self.stream != null) return false;
        const serial_value = std.mem.print(&self.serial_text, "{d}", .{identity.source}) catch return false;
        self.serial_text[serial_value.len] = 0;
        const props = c.pw_properties_new(@as([*:0]const u8, "media.type"), @as([*:0]const u8, "Audio"), @as(?*anyopaque, null)) orelse return false;
        _ = c.pw_properties_set(props, "media.category", "Capture");
        _ = c.pw_properties_set(props, "node.name", "dictation.capture");
        _ = c.pw_properties_set(props, "media.role", "Communication");
        _ = c.pw_properties_set(props, "target.object", &self.serial_text);
        _ = c.pw_properties_set(props, "node.dont-reconnect", "true");
        _ = c.pw_properties_set(props, "node.dont-fallback", "true");
        _ = c.pw_properties_set(props, "stream.capture.sink", "false");
        self.stream = c.pw_stream_new(self.core, "dictation microphone", props) orelse return false;
        self.selected = identity;
        self.stream_failed = null;
        self.formatted = false;
        self.started = false;
        self.start_deadline = platform.now() + 3000;
        c.pw_stream_add_listener(self.stream, &self.stream_hook, &stream_events, self);
        var builder: c.spa_pod_builder = undefined;
        c.spa_pod_builder_init(&builder, &self.pod, self.pod.len);
        var info: c.spa_audio_info_raw = .{ .format = c.SPA_AUDIO_FORMAT_F32, .rate = 16000, .channels = 1 };
        info.position[0] = c.SPA_AUDIO_CHANNEL_MONO;
        var param: [*c]const c.spa_pod = spa_format_audio_raw_build(&builder, c.SPA_PARAM_EnumFormat, &info);
        // Do not set RT_PROCESS. The daemon thread owns capture callbacks.
        if (param == null or c.pw_stream_connect(self.stream, c.PW_DIRECTION_INPUT, c.PW_ID_ANY, c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS, &param, 1) < 0) {
            self.stop();
            return false;
        }
        return true;
    }
    pub fn stop(self: *Capture) void {
        if (self.stream) |stream| {
            _ = c.pw_stream_set_active(stream, false);
            c.pw_stream_destroy(stream);
            self.stream = null;
        }
        // destroy drains this stream's callbacks on our loop; only then can
        // its identity and failure slot be reused by a subsequent recording.
        self.selected = null;
        self.stream_failed = null;
        self.start_deadline = 0;
    }
    pub fn tick(self: *Capture) void {
        if (c.pw_loop_iterate(self.loop, 0) < 0) self.failed = error.PipeWireDisconnected;
        // A connection/negotiation timeout, never a recording-duration timer.
        if (self.start_deadline != 0 and platform.now() >= self.start_deadline and !self.started) self.stream_failed = error.CaptureTimeout;
    }
    pub fn deinit(self: *Capture) void {
        if (!self.initialized) return;
        self.stop();
        if (self.metadata) |v| c.pw_proxy_destroy(@ptrCast(v));
        if (self.registry) |v| c.pw_proxy_destroy(@ptrCast(v));
        if (self.core) |v| _ = c.pw_core_disconnect(v);
        if (self.context) |v| c.pw_context_destroy(v);
        if (self.loop) |v| {
            c.pw_loop_leave(v);
            c.pw_loop_destroy(v);
        }
        c.pw_deinit();
        self.initialized = false;
    }
};
fn owner(data: ?*anyopaque) *Capture {
    return @ptrCast(@alignCast(data.?));
}
fn is(value: [*c]const u8, expected: []const u8) bool {
    return value != null and std.mem.eql(u8, std.mem.span(value), expected);
}
fn global(data: ?*anyopaque, id: u32, _: u32, kind: [*c]const u8, _: u32, props: [*c]const c.spa_dict) callconv(.c) void {
    // spa_dict_lookup requires a dictionary; registry properties can be absent.
    if (props == null) return;
    const self = owner(data);
    if (is(kind, "PipeWire:Interface:Metadata") and is(c.spa_dict_lookup(props, "metadata.name"), "default") and self.metadata == null) {
        const metadata = c.pw_registry_bind(self.registry, id, c.PW_TYPE_INTERFACE_Metadata, c.PW_VERSION_METADATA, 0) orelse {
            self.failed = error.PipeWireRegistry;
            return;
        };
        self.metadata = @ptrCast(metadata);
        self.metadata_id = id;
        if (c.pw_metadata_add_listener(self.metadata, &self.metadata_hook, &metadata_events, self) < 0) self.failed = error.PipeWireRegistry;
    } else if (is(kind, "PipeWire:Interface:Node") and (is(c.spa_dict_lookup(props, "media.class"), "Audio/Source") or is(c.spa_dict_lookup(props, "media.class"), "Audio/Source/Virtual"))) {
        const name = c.spa_dict_lookup(props, "node.name");
        const serial = c.spa_dict_lookup(props, "object.serial");
        if (name == null or serial == null) return;
        const value = std.mem.span(name);
        if (value.len >= self.default_name.len) {
            self.failed = error.DeviceNameCapacity;
            return;
        }
        for (&self.nodes) |*node| if (!node.present) {
            node.id = id;
            node.serial = std.fmt.parseInt(u64, std.mem.span(serial), 10) catch {
                self.failed = error.PipeWireRegistry;
                return;
            };
            @memcpy(node.name[0..value.len], value);
            node.name[value.len] = 0;
            node.present = true;
            return;
        };
        self.failed = error.DeviceCapacity; // table exhaustion is explicit, never an arbitrary input
    }
}
fn removed(data: ?*anyopaque, id: u32) callconv(.c) void {
    const self = owner(data);
    if (self.metadata != null and self.metadata_id == id) {
        c.pw_proxy_destroy(@ptrCast(self.metadata.?));
        self.metadata = null;
        self.default_name[0] = 0;
    }
    for (&self.nodes) |*node| if (node.present and node.id == id) {
        if (self.selected) |identity| {
            if (identity.source == node.serial) self.stream_failed = error.MicrophoneRemoved;
        }
        node.present = false;
    };
}
fn property(data: ?*anyopaque, subject: u32, key: [*c]const u8, _: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const self = owner(data);
    if (subject != 0 or (key != null and !is(key, "default.audio.source"))) return 0;
    self.default_name[0] = 0;
    if (value != null and spa_json_str_object_find(value, std.mem.len(value), "name", &self.default_name, self.default_name.len) < 0) self.default_name[0] = 0;
    return 0;
}
fn coreError(data: ?*anyopaque, id: u32, _: c_int, result: c_int, _: [*c]const u8) callconv(.c) void {
    owner(data).failed = if (id == c.PW_ID_CORE and result == -c.EPIPE) error.PipeWireDisconnected else error.PipeWireCore;
}
fn state(data: ?*anyopaque, _: c.pw_stream_state, next: c.pw_stream_state, _: [*c]const u8) callconv(.c) void {
    const self = owner(data);
    if (next == c.PW_STREAM_STATE_ERROR or (self.started and next == c.PW_STREAM_STATE_UNCONNECTED)) self.stream_failed = error.CaptureDisconnected;
}
fn format(data: ?*anyopaque, id: u32, param: [*c]const c.spa_pod) callconv(.c) void {
    if (id != c.SPA_PARAM_Format or param == null) return;
    const self = owner(data);
    var info: c.spa_audio_info_raw = .{};
    self.formatted = spa_format_audio_raw_parse(param, &info) >= 0 and info.format == c.SPA_AUDIO_FORMAT_F32 and info.rate == 16000 and info.channels == 1;
    if (!self.formatted) self.stream_failed = error.CaptureFormat;
}
fn process(data: ?*anyopaque) callconv(.c) void {
    const self = owner(data);
    const buffer = c.pw_stream_dequeue_buffer(self.stream) orelse return;
    defer _ = c.pw_stream_queue_buffer(self.stream, buffer);
    if (!self.formatted or self.stream_failed != null or self.failed != null) return;
    const identity = self.selected orelse return;
    const raw = buffer.*.buffer.*;
    if (raw.n_datas != 1) {
        self.stream_failed = error.CaptureBuffer;
        return;
    }
    const block = raw.datas[0];
    if (block.data == null or block.chunk == null or @intFromPtr(block.data.?) % @alignOf(f32) != 0) {
        self.stream_failed = error.CaptureBuffer;
        return;
    }
    const chunk = block.chunk.*;
    if (chunk.offset > block.maxsize or chunk.size > block.maxsize - chunk.offset or chunk.size % 4 != 0 or chunk.offset % 4 != 0 or chunk.stride != 4 or chunk.flags & c.SPA_CHUNK_FLAG_CORRUPTED != 0) {
        self.stream_failed = error.CaptureBuffer;
        return;
    }
    if (!self.started) platform.diagnostic("dictation: capture ready (mono 16000 Hz)\n");
    self.started = true;
    const bytes: [*]const u8 = @ptrCast(block.data.?);
    const samples: [*]const f32 = @ptrCast(@alignCast(bytes + chunk.offset));
    self.on_samples(identity, samples[0 .. chunk.size / 4]);
}
const registry_events: c.pw_registry_events = .{ .version = c.PW_VERSION_REGISTRY_EVENTS, .global = global, .global_remove = removed };
const metadata_events: c.pw_metadata_events = .{ .version = c.PW_VERSION_METADATA_EVENTS, .property = property };
const core_events: c.pw_core_events = .{ .version = c.PW_VERSION_CORE_EVENTS, .@"error" = coreError };
const stream_events: c.pw_stream_events = .{ .version = c.PW_VERSION_STREAM_EVENTS, .state_changed = state, .param_changed = format, .process = process };
