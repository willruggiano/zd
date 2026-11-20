const std = @import("std");
const dictation = @import("dictation.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const text = std.testing.expectEqualStrings;

const Desktop = struct {
    capture: bool = false,
    indicator: dictation.Indicator = .idle,
    copied: [64]u8 = undefined,
    len: usize = 0,
    copies: usize = 0,
    fail: bool = false,
    default_source: ?u64 = 1,
    selected_source: ?u64 = null,
    capture_available: bool = true,
    decode_count: usize = 0,
    decode_samples: usize = 0,
    decoded_while_capturing: bool = false,
    decode_available: bool = true,
    last_problem: ?anyerror = null,
    pub fn defaultSource(self: *@This()) ?u64 {
        return self.default_source;
    }
    pub fn recording(self: *@This(), source: ?u64) bool {
        self.selected_source = source;
        self.capture = source != null and self.capture_available;
        return source == null or self.capture;
    }
    pub fn decode(self: *@This(), samples: []const f32) bool {
        self.decode_count += 1;
        self.decode_samples = samples.len;
        self.decoded_while_capturing = self.capture;
        return self.decode_available;
    }
    pub fn problem(self: *@This(), reason: anyerror) void {
        self.last_problem = reason;
    }
    pub fn show(self: *@This(), state: dictation.Indicator) void {
        self.indicator = state;
    }
    pub fn publish(self: *@This(), value: []const u8) bool {
        if (self.fail) return false;
        @memcpy(self.copied[0..value.len], value);
        self.len = value.len;
        self.copies += 1;
        return true;
    }
};

test "toggles capture then finalizes and copies once without intermediate publication" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    try expect(desktop.capture);
    try equal(.recording, desktop.indicator);
    try equal(0, desktop.copies);
    app.audio(&.{0.1}, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.finalizing, desktop.indicator);
    try equal(0, desktop.copies);
    app.complete("Known result.", &desktop);
    try text("Known result.", desktop.copied[0..desktop.len]);
    try equal(.success, desktop.indicator);
    app.complete("Duplicate.", &desktop);
    try equal(1, desktop.copies);
}

test "empty, failed and over-capacity finalization preserve the clipboard" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(8, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    for ([_][]const u8{ "", "Too long!", "Fits" }) |result| {
        app.toggle(&desktop);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        desktop.fail = std.mem.eql(u8, result, "Fits");
        app.complete(result, &desktop);
        try text("Previous", desktop.copied[0..desktop.len]);
        try equal(1, desktop.copies);
        try equal(@as(dictation.Indicator, if (result.len == 0) .no_speech else .failure), desktop.indicator);
    }
}

test "missing required protocols and malformed control do not start capture" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, 8) = .{};
    try std.testing.expectError(error.MissingLayerShell, app.connect(.{ .layer_shell = false, .data_control = true }));
    try std.testing.expectError(error.MissingDataControl, app.connect(.{ .layer_shell = true, .data_control = false }));
    try equal(.unavailable, app.command("toggle", &desktop));
    try expect(!desktop.capture);
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    for ([_][]const u8{ "", "toggle\n", "toggle\x00", "toggle toggle", "garbage" }) |request| {
        try equal(.invalid, app.command(request, &desktop));
    }
    try expect(!desktop.capture);
    try equal(.accepted, app.command("toggle", &desktop));
    try expect(desktop.capture);
}

test "exact transcript boundary succeeds at non-default capacity" {
    var desktop: Desktop = .{};
    var app: dictation.Session(8, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{0.1}, &desktop);
    app.toggle(&desktop);
    app.complete("12345678", &desktop);
    try text("12345678", desktop.copied[0..desktop.len]);
}

test "sizing rejects zero, incompatible capacities and overflow" {
    const Sizes = @import("config.zig").Sizes;
    try (Sizes{}).validate();
    try (Sizes{ .transcript_bytes = 8, .control_clients = 1, .clipboard_slots = 2, .transfers = 1 }).validate();
    try std.testing.expectError(error.InvalidTranscriptCapacity, (Sizes{ .transcript_bytes = 0 }).validate());
    try std.testing.expectError(error.InvalidControlCapacity, (Sizes{ .control_clients = 0 }).validate());
    try std.testing.expectError(error.InvalidClipboardSlots, (Sizes{ .clipboard_slots = 1 }).validate());
    try std.testing.expectError(error.InvalidTransferCapacity, (Sizes{ .transfers = 0 }).validate());
    try std.testing.expectError(error.Overflow, (Sizes{ .transcript_bytes = std.math.maxInt(usize) }).validate());
}

test "previous clipboard remains readable during subsequent capture and finalization" {
    var desktop: Desktop = .{};
    const Backing = struct {
        var app: dictation.Session(@import("config.zig").sizes.transcript_bytes, 8) = .{};
    };
    const app = &Backing.app;
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    for (0..4) |_| {
        app.toggle(&desktop);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        app.complete("X", &desktop);
        app.toggle(&desktop);
        try expect(desktop.capture);
        try text("X", desktop.copied[0..desktop.len]);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        try expect(!desktop.capture);
        try text("X", desktop.copied[0..desktop.len]);
        app.complete("   \n", &desktop);
        try equal(.no_speech, desktop.indicator);
        try text("X", desktop.copied[0..desktop.len]);
    }
    try equal(4, desktop.copies);
}

test "loading toggles never open the microphone or queue a delayed recording" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.loading, desktop.indicator);
    app.toggle(&desktop);
    app.modelLoaded(true, &desktop);
    try expect(!desktop.capture);
    try equal(.idle, desktop.indicator);
    app.toggle(&desktop);
    try expect(desktop.capture);
}

test "a missing default microphone fails without capture and each session pins its source" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    desktop.default_source = null;
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    desktop.default_source = 41;
    app.toggle(&desktop);
    try equal(41, desktop.selected_source.?);
    desktop.default_source = 92;
    try equal(41, desktop.selected_source.?);
    app.audio(&.{0.1}, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    app.complete("First.", &desktop);
    app.toggle(&desktop);
    try equal(92, desktop.selected_source.?);
    app.sourceRemoved(41, &desktop);
    try expect(desktop.capture);
    app.sourceRemoved(92, &desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    try text("First.", desktop.copied[0..desktop.len]);
}

test "audio reaches the decoder only after capture closes; exhaustion never publishes partial work" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, 4) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2, -0.3, 0.4 }, &desktop);
    try expect(desktop.capture);
    try equal(0, desktop.decode_count);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try expect(!desktop.decoded_while_capturing);
    try equal(4, desktop.decode_samples);
    app.complete("Real result.", &desktop);
    try text("Real result.", desktop.copied[0..desktop.len]);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2, 0.3, 0.4, 0.5 }, &desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    try equal(@as(?anyerror, error.AudioCapacity), desktop.last_problem);
    try equal(1, desktop.decode_count);
    app.complete("Partial", &desktop);
    try text("Real result.", desktop.copied[0..desktop.len]);
}

test "capture and worker sizing rejects zero, incompatible stacks and overflowing PCM" {
    const Sizes = @import("config.zig").Sizes;
    try std.testing.expectError(error.InvalidAudioCapacity, (Sizes{ .audio_samples = 0 }).validate());
    try std.testing.expectError(error.InvalidDeviceCapacity, (Sizes{ .device_slots = 0 }).validate());
    try std.testing.expectError(error.InvalidWorkerStack, (Sizes{ .worker_stack_bytes = 1 }).validate());
    try std.testing.expectError(error.InvalidInferenceThreads, (Sizes{ .inference_threads = 0 }).validate());
    try std.testing.expectError(error.Overflow, (Sizes{ .audio_samples = std.math.maxInt(usize) }).validate());
}

test "initialization, capture and inference failures preserve the previous clipboard" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(false, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    app.modelLoaded(true, &desktop);
    desktop.capture_available = false;
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    desktop.capture_available = true;
    desktop.decode_available = false;
    app.toggle(&desktop);
    app.audio(&.{0.2}, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    desktop.decode_available = true;
    app.toggle(&desktop);
    app.audio(&.{0.2}, &desktop);
    app.toggle(&desktop);
    app.fail(&desktop); // controlled inference error after relinquishing audio
    app.complete("Partial old result", &desktop);
    try text("Previous", desktop.copied[0..desktop.len]);
    try equal(1, desktop.copies);
    app.toggle(&desktop);
    try expect(desktop.capture);
}

test "silence avoids inference and repeated sessions reuse readiness without continuous capture" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, 8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0, 0, 0, 0 }, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.no_speech, desktop.indicator);
    try equal(0, desktop.decode_count);
    try text("Previous", desktop.copied[0..desktop.len]);
    for (0..3) |_| {
        app.toggle(&desktop);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        // Until milestone 05, a toggle during finalization refuses new capture.
        app.toggle(&desktop);
        try expect(!desktop.capture);
        app.complete("Reply.", &desktop);
        try text("Reply.", desktop.copied[0..desktop.len]);
    }
    try equal(3, desktop.decode_count);
    try equal(4, desktop.copies);
}
