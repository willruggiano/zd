const std = @import("std");
const dictation = @import("dictation.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const text = std.testing.expectEqualStrings;

const clipboard = @import("clipboard.zig");
const Desktop = TestDesktop(void);

fn TestDesktop(comptime Serving: type) type {
    return struct {
        clipboard: Serving = if (Serving == void) {} else .{},
        io: ClipboardIO = .{},
        capture: bool = false,
        indicator: dictation.Indicator = .idle,
        copied: [4096]u8 = undefined,
        len: usize = 0,
        copies: usize = 0,
        fail: bool = false,
        default_source: ?u64 = 1,
        selected_source: ?u64 = null,
        capture_available: bool = true,
        decode_count: usize = 0,
        operation: dictation.Operation = .{ .session = 0, .window = 0 },
        cancelled: ?dictation.Operation = null,
        decode_samples: usize = 0,
        borrowed: []const f32 = &.{},
        context: [256]u8 = undefined,
        context_len: usize = 0,
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
        pub fn decode(self: *@This(), operation: dictation.Operation, samples: []const f32, context: []const u8) bool {
            self.operation = operation;
            @memcpy(self.context[0..context.len], context);
            self.context_len = context.len;
            self.decode_count += 1;
            self.decode_samples = samples.len;
            self.borrowed = samples;
            self.decoded_while_capturing = self.capture;
            return self.decode_available;
        }
        pub fn cancel(self: *@This(), operation: dictation.Operation) void {
            self.cancelled = operation;
        }
        pub fn problem(self: *@This(), reason: anyerror) void {
            self.last_problem = reason;
        }
        pub fn show(self: *@This(), state: dictation.Indicator) void {
            self.indicator = state;
        }
        pub fn publish(self: *@This(), value: []const u8) bool {
            if (self.fail) return false;
            if (Serving != void and !self.clipboard.publish(value, &self.io)) return false;
            @memcpy(self.copied[0..value.len], value);
            self.len = value.len;
            self.copies += 1;
            return true;
        }
    };
}

test "toggles capture then finalizes and copies once without intermediate publication" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, .{ .samples = 8 }) = .{};
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
    app.complete(desktop.operation, "Known result.", &desktop);
    try text("Known result.", desktop.copied[0..desktop.len]);
    try equal(.success, desktop.indicator);
    app.complete(desktop.operation, "Duplicate.", &desktop);
    try equal(1, desktop.copies);
}

test "empty, failed and over-capacity finalization preserve the clipboard" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(8, .{ .samples = 8 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    for ([_][]const u8{ "", "Too long!", "Fits" }) |result| {
        app.toggle(&desktop);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        desktop.fail = std.mem.eql(u8, result, "Fits");
        app.complete(desktop.operation, result, &desktop);
        try text("Previous", desktop.copied[0..desktop.len]);
        try equal(1, desktop.copies);
        try equal(@as(dictation.Indicator, if (result.len == 0) .no_speech else .failure), desktop.indicator);
    }
}

test "missing required protocols and malformed control do not start capture" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, .{ .samples = 8 }) = .{};
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
    var app: dictation.Session(8, .{ .samples = 8 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{0.1}, &desktop);
    app.toggle(&desktop);
    app.complete(desktop.operation, "12345678", &desktop);
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
        var app: dictation.Session(@import("config.zig").sizes.transcript_bytes, .{ .samples = 8 }) = .{};
    };
    const app = &Backing.app;
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    for (0..4) |_| {
        app.toggle(&desktop);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        app.complete(desktop.operation, "X", &desktop);
        app.toggle(&desktop);
        try expect(desktop.capture);
        try text("X", desktop.copied[0..desktop.len]);
        app.audio(&.{0.1}, &desktop);
        app.toggle(&desktop);
        try expect(!desktop.capture);
        try text("X", desktop.copied[0..desktop.len]);
        app.complete(desktop.operation, "   \n", &desktop);
        try equal(.no_speech, desktop.indicator);
        try text("X", desktop.copied[0..desktop.len]);
    }
    try equal(4, desktop.copies);
}

test "loading toggles never open the microphone or queue a delayed recording" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, .{ .samples = 8 }) = .{};
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
    var app: dictation.Session(64, .{ .samples = 8 }) = .{};
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
    app.complete(desktop.operation, "First.", &desktop);
    app.toggle(&desktop);
    try equal(92, desktop.selected_source.?);
    app.sourceRemoved(41, &desktop);
    try expect(desktop.capture);
    app.sourceRemoved(92, &desktop);
    try expect(!desktop.capture);
    try equal(.failure, desktop.indicator);
    try text("First.", desktop.copied[0..desktop.len]);
}

test "full windows decode during recording and only stop publishes the assembled transcript" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, .{ .samples = 4 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2, -0.3, 0.4 }, &desktop);
    try expect(desktop.capture);
    try equal(1, desktop.decode_count);
    try expect(desktop.decoded_while_capturing);
    try equal(.recording, desktop.indicator);
    app.complete(desktop.operation, "First.", &desktop);
    try text("Previous", desktop.copied[0..desktop.len]);
    try equal(.recording, desktop.indicator);
    app.audio(&.{0.5}, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.finalizing, desktop.indicator);
    try equal(2, desktop.decode_count);
    try equal(1, desktop.decode_samples);
    app.complete(desktop.operation, "Tail.", &desktop);
    try text("First. Tail.", desktop.copied[0..desktop.len]);
    try equal(2, desktop.copies);
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
    var app: dictation.Session(64, .{ .samples = 8 }) = .{};
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
    app.inferenceFailed(desktop.operation, error.InferenceFailure, &desktop); // controlled inference error after relinquishing audio
    app.complete(desktop.operation, "Partial old result", &desktop);
    try text("Previous", desktop.copied[0..desktop.len]);
    try equal(1, desktop.copies);
    app.toggle(&desktop);
    try expect(desktop.capture);
}

test "silence avoids inference and repeated sessions reuse readiness without continuous capture" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, .{ .samples = 8 }) = .{};
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
        app.complete(desktop.operation, "Reply.", &desktop);
        try text("Reply.", desktop.copied[0..desktop.len]);
    }
    try equal(3, desktop.decode_count);
    try equal(4, desktop.copies);
}

test "pause-aligned windows leave recording active and retain the short tail" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, .{ .samples = 8, .min_samples = 4, .pause_samples = 2 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.2, 0.3, 0, 0 }, &desktop);
    try equal(1, desktop.decode_count);
    try equal(4, desktop.decode_samples);
    try equal(.recording, desktop.indicator);
    app.audio(&.{0.4}, &desktop);
    app.toggle(&desktop); // stop while the earlier window is still decoding
    try expect(!desktop.capture);
    app.complete(desktop.operation, "Before pause.", &desktop);
    try equal(0, desktop.copies);
    app.advance(&desktop); // external decoder is ready for its next job
    try equal(2, desktop.decode_count);
    try std.testing.expectEqualSlices(f32, &.{0.4}, desktop.borrowed);
    app.complete(desktop.operation, "After pause.", &desktop);
    try text("Before pause. After pause.", desktop.copied[0..desktop.len]);
    try equal(1, desktop.copies);
}

test "continuous boundaries carry bounded context without deleting repeated words" {
    var desktop: Desktop = .{};
    var app: dictation.Session(64, .{ .samples = 2, .context_bytes = 12 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2, 0.3, 0.4 }, &desktop);
    app.complete(desktop.operation, "  earlier words again  ", &desktop);
    app.advance(&desktop);
    try text("words again", desktop.context[0..desktop.context_len]);
    try std.testing.expectEqualSlices(f32, &.{ 0.3, 0.4 }, desktop.borrowed);
    app.toggle(&desktop);
    app.complete(desktop.operation, "again please", &desktop);
    try text("earlier words again again please", desktop.copied[0..desktop.len]);
    app.toggle(&desktop);
    app.audio(&.{ 0.5, 0.6 }, &desktop);
    try equal(0, desktop.context_len); // never use previous-session text as a prompt
}

test "130 seconds recycle audio without changing recording phase or publishing partial text" {
    var desktop: Desktop = .{};
    var app: dictation.Session(1024, .{ .samples = 16000, .min_samples = 16000, .pause_samples = 8000 }) = .{};
    const second: [16000]f32 = @splat(0.1);
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    for (0..130) |_| {
        app.audio(&second, &desktop);
        app.complete(desktop.operation, "word", &desktop);
        app.advance(&desktop);
        try expect(desktop.capture);
        try equal(.recording, desktop.indicator);
        try equal(0, desktop.copies);
    }
    app.toggle(&desktop);
    try equal(649, desktop.len);
    for (0..129) |i| try text("word ", desktop.copied[i * 5 ..][0..5]);
    try text("word", desktop.copied[645..649]);
    try equal(130, desktop.decode_count);
    try equal(1, desktop.copies);
}

test "full backlog fails on the next sample without modifying borrowed PCM or publishing late results" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, .{ .samples = 2, .slots = 2 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2, 0.3, 0.4 }, &desktop);
    try expect(desktop.capture); // exact backlog capacity fits
    try equal(1, desktop.decode_count);
    app.audio(&.{0.5}, &desktop);
    try equal(.failure, desktop.indicator);
    try equal(@as(?anyerror, error.AudioCapacity), desktop.last_problem);
    try expect(!desktop.capture);
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2 }, desktop.borrowed);
    app.toggle(&desktop); // no reuse before the borrow is relinquished
    try expect(!desktop.capture);
    app.complete(desktop.operation, "Late partial", &desktop);
    app.advance(&desktop);
    try equal(1, desktop.decode_count); // discarded queued audio is never decoded
    try text("Previous", desktop.copied[0..desktop.len]);
    app.toggle(&desktop);
    try expect(desktop.capture);
    app.audio(&.{0.6}, &desktop);
    app.toggle(&desktop);
    app.complete(desktop.operation, "Recovered", &desktop);
    try text("Recovered", desktop.copied[0..desktop.len]);
}

test "streamed transcript exactly fills capacity but one extra byte fails before stop" {
    for ([_][]const u8{ "defg", "defgh" }) |tail| {
        var desktop: Desktop = .{};
        _ = desktop.publish("Previous");
        var app: dictation.Session(8, .{ .samples = 1 }) = .{};
        try app.connect(.{ .layer_shell = true, .data_control = true });
        app.modelLoaded(true, &desktop);
        app.toggle(&desktop);
        app.audio(&.{0.1}, &desktop);
        app.complete(desktop.operation, "abc", &desktop);
        app.audio(&.{0.2}, &desktop);
        app.complete(desktop.operation, tail, &desktop);
        if (tail.len == 4) {
            try expect(desktop.capture);
            try text("Previous", desktop.copied[0..desktop.len]);
            app.toggle(&desktop);
            try text("abc defg", desktop.copied[0..desktop.len]);
        } else {
            try expect(!desktop.capture);
            try equal(.failure, desktop.indicator);
            try equal(@as(?anyerror, error.TranscriptCapacity), desktop.last_problem);
            app.complete(desktop.operation, "Late", &desktop);
            app.advance(&desktop);
            try text("Previous", desktop.copied[0..desktop.len]);
        }
    }
}

test "source loss and malformed PCM during decoding retain the borrow and discard all pending text" {
    for (0..2) |failure| {
        var desktop: Desktop = .{};
        _ = desktop.publish("Previous");
        var app: dictation.Session(64, .{ .samples = 2 }) = .{};
        try app.connect(.{ .layer_shell = true, .data_control = true });
        app.modelLoaded(true, &desktop);
        app.toggle(&desktop);
        app.audio(&.{ 0.1, 0.2 }, &desktop);
        app.complete(desktop.operation, "Internal only", &desktop);
        app.audio(&.{ 0.3, 0.4, 0.5 }, &desktop);
        if (failure == 0) app.sourceRemoved(1, &desktop) else app.audio(&.{std.math.nan(f32)}, &desktop);
        try equal(.failure, desktop.indicator);
        try std.testing.expectEqualSlices(f32, &.{ 0.3, 0.4 }, desktop.borrowed);
        app.complete(desktop.operation, "Late", &desktop);
        app.advance(&desktop);
        try text("Previous", desktop.copied[0..desktop.len]);
    }
}

test "streaming sizing rejects incompatible windows, empty backlog and arithmetic overflow" {
    const Sizes = @import("config.zig").Sizes;
    try std.testing.expectError(error.InvalidAudioWindows, (Sizes{ .audio_windows = 1 }).validate());
    try std.testing.expectError(error.InvalidWindowBoundary, (Sizes{ .window_min_samples = 0 }).validate());
    try std.testing.expectError(error.InvalidWindowBoundary, (Sizes{ .audio_samples = 100, .window_min_samples = 101 }).validate());
    try std.testing.expectError(error.InvalidWindowBoundary, (Sizes{ .pause_samples = 0 }).validate());
    try std.testing.expectError(error.InvalidWindowBoundary, (Sizes{ .pause_samples = 48001 }).validate());
    try std.testing.expectError(error.InvalidContextCapacity, (Sizes{ .context_bytes = 4097 }).validate());
    try std.testing.expectError(error.Overflow, (Sizes{ .audio_windows = std.math.maxInt(usize) }).validate());
    try std.testing.expectError(error.Overflow, (Sizes{ .context_bytes = std.math.maxInt(usize) }).validate());
    try (Sizes{ .audio_samples = 2, .audio_windows = 2, .window_min_samples = 1, .pause_samples = 1, .context_bytes = 0 }).validate();
}

test "restart opens replacement capture before old inference returns" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, .{ .samples = 2, .slots = 2 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2 }, &desktop);
    const borrowed = desktop.borrowed;
    const old = desktop.operation;
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.finalizing, desktop.indicator);
    desktop.default_source = 92;
    app.toggle(&desktop);
    try expect(desktop.capture);
    try equal(92, desktop.selected_source.?);
    try equal(old, desktop.cancelled.?);
    try equal(.recording, desktop.indicator);
    app.audio(&.{ 0.3, 0.4 }, &desktop);
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2 }, borrowed);
    try equal(1, desktop.decode_count);
    try text("Previous", desktop.copied[0..desktop.len]);
    app.complete(old, "Abandoned partial", &desktop);
    try expect(desktop.capture);
    try equal(.recording, desktop.indicator);
    try text("Previous", desktop.copied[0..desktop.len]);
    app.advance(&desktop);
    try equal(2, desktop.decode_count);
    try equal(0, desktop.context_len);
    try std.testing.expectEqualSlices(f32, &.{ 0.3, 0.4 }, desktop.borrowed);
    app.toggle(&desktop);
    app.complete(desktop.operation, "Replacement", &desktop);
    try text("Replacement", desktop.copied[0..desktop.len]);
    try equal(2, desktop.copies);
}

test "repeated restarts discard pending chunks and obsolete events cannot retire replacement work" {
    var desktop: Desktop = .{};
    _ = desktop.publish("Previous");
    var app: dictation.Session(64, .{ .samples = 2, .slots = 3 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&.{ 0.1, 0.2 }, &desktop);
    app.complete(desktop.operation, "Discard this prefix", &desktop);
    const prefix = desktop.operation;
    app.audio(&.{ 0.3, 0.4, 0.5, 0.6, 0.7 }, &desktop);
    const old = desktop.operation;
    const borrowed = desktop.borrowed;
    desktop.decode_available = false; // external shared context is still occupied
    for (0..20) |_| {
        app.toggle(&desktop); // stops even though old inference is active
        try expect(!desktop.capture);
        app.toggle(&desktop);
        try expect(desktop.capture);
        try equal(.recording, desktop.indicator);
        app.audio(&.{ 0.8, 0.9, 1.0 }, &desktop);
        app.complete(prefix, "Duplicate earlier completion", &desktop);
        app.inferenceFailed(prefix, error.ObsoleteFailure, &desktop);
        try expect(desktop.capture);
        try std.testing.expectEqualSlices(f32, &.{ 0.3, 0.4 }, borrowed);
        try text("Previous", desktop.copied[0..desktop.len]);
    }
    try equal(2, desktop.decode_count);
    app.inferenceFailed(old, error.InferenceCancelled, &desktop);
    desktop.decode_available = true;
    app.advance(&desktop);
    const current = desktop.operation;
    try equal(0, desktop.context_len);
    try std.testing.expectEqualSlices(f32, &.{ 0.8, 0.9 }, desktop.borrowed);
    app.complete(old, "Late partial after cancelled", &desktop);
    app.inferenceFailed(old, error.ObsoleteFailure, &desktop);
    app.advance(&desktop);
    try equal(current, desktop.operation);
    try equal(3, desktop.decode_count);
    try equal(@as(?anyerror, null), desktop.last_problem);
    try expect(desktop.capture);
    app.toggle(&desktop);
    app.complete(current, "Only", &desktop);
    app.advance(&desktop);
    try std.testing.expectEqualSlices(f32, &.{1.0}, desktop.borrowed);
    app.complete(current, "Duplicate current-session window", &desktop);
    try equal(.finalizing, desktop.indicator);
    app.complete(desktop.operation, "replacement", &desktop);
    try text("Only replacement", desktop.copied[0..desktop.len]);
    try equal(2, desktop.copies);
}

test "replacement failure preserves clipboard while cancellation is delayed" {
    for (0..3) |failure| {
        var desktop: Desktop = .{};
        _ = desktop.publish("Previous");
        var app: dictation.Session(64, .{ .samples = 2, .slots = 2 }) = .{};
        try app.connect(.{ .layer_shell = true, .data_control = true });
        app.modelLoaded(true, &desktop);
        app.toggle(&desktop);
        app.audio(&.{ 0.1, 0.2 }, &desktop);
        const old = desktop.operation;
        const borrowed = desktop.borrowed;
        app.toggle(&desktop);
        try equal(@as(?dictation.Operation, null), desktop.cancelled);
        if (failure == 1) desktop.default_source = null;
        if (failure == 2) desktop.capture_available = false;
        app.toggle(&desktop);
        if (failure == 0) {
            app.audio(&.{ 0.3, 0.4 }, &desktop);
            try expect(desktop.capture); // one retained + one replacement window fits
            app.audio(&.{0.5}, &desktop);
        }
        try expect(!desktop.capture);
        try equal(.failure, desktop.indicator);
        try equal(@as(?anyerror, switch (failure) {
            0 => error.AudioCapacity,
            1 => error.DefaultMicrophoneUnavailable,
            else => error.CaptureStart,
        }), desktop.last_problem);
        try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2 }, borrowed);
        app.complete(old, "Old partial must not recover a failed replacement", &desktop);
        app.advance(&desktop);
        app.inferenceFailed(old, error.ObsoleteFailure, &desktop);
        try equal(.failure, desktop.indicator);
        try equal(1, desktop.decode_count);
        try text("Previous", desktop.copied[0..desktop.len]);
        desktop.default_source = 2;
        desktop.capture_available = true;
        app.toggle(&desktop);
        app.audio(&.{0.6}, &desktop);
        app.toggle(&desktop);
        app.complete(desktop.operation, "Recovered", &desktop);
        try text("Recovered", desktop.copied[0..desktop.len]);
    }
}

test "default sizing permits replacement capture while old audio remains borrowed" {
    const sizes = @import("config.zig").sizes;
    const Backing = struct {
        var app: dictation.Session(sizes.transcript_bytes, sizes.windows()) = .{};
        const window: [sizes.audio_samples]f32 = @splat(0.1);
    };
    var desktop: Desktop = .{};
    const app = &Backing.app;
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    app.toggle(&desktop);
    app.audio(&Backing.window, &desktop);
    const old = desktop.operation;
    const borrowed = desktop.borrowed;
    app.toggle(&desktop);
    app.toggle(&desktop);
    app.audio(&.{0.7}, &desktop);
    app.toggle(&desktop);
    try equal(.finalizing, desktop.indicator);
    try std.testing.expectEqualSlices(f32, &Backing.window, borrowed);
    app.complete(old, "Abandoned", &desktop);
    try equal(0, desktop.copies);
    app.advance(&desktop);
    try std.testing.expectEqualSlices(f32, &.{0.7}, desktop.borrowed);
    app.complete(desktop.operation, "Current", &desktop);
    try text("Current", desktop.copied[0..desktop.len]);
}

// Deterministic external protocol/pipe adapter. It never models text ownership:
// Session and the production Clipboard own that logic. fd indexes test readers.
const ClipboardIO = struct {
    const Reader = struct {
        bytes: [4096]u8 = undefined,
        len: usize = 0,
        limit: usize = 4096,
        blocked: bool = false,
        failed: bool = false,
        prepared: bool = true,
        closed: bool = false,
        writes: usize = 0,
    };
    readers: [4]Reader = @splat(.{}),
    selected: ?u32 = null,
    next: u32 = 0,
    live: usize = 0,
    create_failed: bool = false,
    select_failed: bool = false,
    pub fn create(self: *@This()) ?u32 {
        if (self.create_failed) return null;
        self.next += 1;
        self.live += 1;
        return self.next;
    }
    pub fn select(self: *@This(), source: u32) bool {
        if (self.select_failed) return false;
        self.selected = source;
        return true;
    }
    pub fn destroy(self: *@This(), _: u32) void {
        self.live -= 1;
    }
    pub fn prepare(self: *@This(), fd: i32) bool {
        return self.readers[@intCast(fd)].prepared;
    }
    pub fn write(self: *@This(), fd: i32, bytes: []const u8) clipboard.Write {
        const reader = &self.readers[@intCast(fd)];
        std.debug.assert(!reader.closed);
        reader.writes += 1;
        if (reader.failed) return .failed;
        if (reader.blocked) return .blocked;
        const n = @min(bytes.len, reader.limit);
        @memcpy(reader.bytes[reader.len..][0..n], bytes[0..n]);
        reader.len += n;
        return .{ .progress = n };
    }
    pub fn close(self: *@This(), fd: i32) void {
        const reader = &self.readers[@intCast(fd)];
        std.debug.assert(!reader.closed);
        reader.closed = true;
    }
    fn received(self: *@This(), fd: usize) []const u8 {
        const reader = &self.readers[fd];
        return reader.bytes[0..reader.len];
    }
};

fn reply(app: anytype, desktop: anytype, value: []const u8) void {
    app.toggle(desktop);
    app.audio(&.{0.1}, desktop);
    app.toggle(desktop);
    app.complete(desktop.operation, value, desktop);
}

test "slow concurrent readers keep distinct complete offers through capture, inference and takeover" {
    var desktop: TestDesktop(clipboard.Clipboard(8, 2, 3, u32)) = .{};
    var app: dictation.Session(8, .{ .samples = 1 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    reply(&app, &desktop, "abcdefgh");
    const old = desktop.io.selected.?;
    desktop.io.readers[0].limit = 2;
    desktop.io.readers[1].limit = 1;
    desktop.clipboard.send(old, 0, 0, &desktop.io);
    desktop.clipboard.send(old, 1, 0, &desktop.io);
    desktop.clipboard.tick(1, &desktop.io);
    app.toggle(&desktop);
    app.audio(&.{0.2}, &desktop);
    try expect(desktop.capture);
    try equal(.recording, desktop.indicator);
    try expect(desktop.decoded_while_capturing);
    app.complete(desktop.operation, "new", &desktop);
    desktop.clipboard.tick(2, &desktop.io);
    try equal(old, desktop.io.selected.?);
    try text("abcd", desktop.io.received(0));
    try text("ab", desktop.io.received(1));
    // Another paste while inference builds the next transcript still gets old.
    desktop.clipboard.send(old, 2, 2, &desktop.io);
    desktop.clipboard.tick(3, &desktop.io);
    try text("abcdefgh", desktop.io.received(2));
    app.audio(&.{0.3}, &desktop);
    app.toggle(&desktop);
    try expect(!desktop.capture);
    try equal(.finalizing, desktop.indicator);
    app.complete(desktop.operation, "text", &desktop);
    try equal(.success, desktop.indicator);
    const current = desktop.io.selected.?;
    try expect(old != current);
    // Native cancellation is asynchronous and must not terminate prior readers.
    desktop.clipboard.cancelled(old, &desktop.io);
    desktop.io.readers[2] = .{ .limit = 2 };
    desktop.clipboard.send(current, 2, 3, &desktop.io);
    desktop.clipboard.tick(4, &desktop.io);
    try text("ne", desktop.io.received(2));
    // External selection takeover also leaves already requested pipes intact.
    desktop.clipboard.cancelled(current, &desktop.io);
    desktop.io.selected = null;
    for (5..9) |now| desktop.clipboard.tick(@intCast(now), &desktop.io);
    try text("abcdefgh", desktop.io.received(0));
    try text("abcdefgh", desktop.io.received(1));
    try text("new text", desktop.io.received(2));
    try expect(desktop.io.readers[0].closed and desktop.io.readers[1].closed);
    try equal(0, desktop.io.live);
    // Ownership/reader release makes both slots reusable, with no history queue.
    for (0..20) |_| {
        reply(&app, &desktop, "again");
        try equal(.success, desktop.indicator);
        desktop.clipboard.cancelled(desktop.io.selected.?, &desktop.io);
    }
    desktop.clipboard.deinit(&desktop.io);
}

test "offer exhaustion fails publication without changing current selection and reuses released slots" {
    var desktop: TestDesktop(clipboard.Clipboard(8, 2, 2, u32)) = .{};
    var app: dictation.Session(8, .{ .samples = 1 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    reply(&app, &desktop, "old");
    const old = desktop.io.selected.?;
    desktop.io.readers[0].blocked = true;
    desktop.clipboard.send(old, 0, 0, &desktop.io);
    reply(&app, &desktop, "current");
    const current = desktop.io.selected.?;
    // Even a cancellation cannot reclaim a reader-pinned old slot.
    desktop.clipboard.cancelled(old, &desktop.io);
    reply(&app, &desktop, "rejected");
    try equal(.failure, desktop.indicator);
    try equal(2, desktop.copies);
    try equal(current, desktop.io.selected.?);
    desktop.clipboard.send(current, 1, 0, &desktop.io);
    desktop.clipboard.tick(4999, &desktop.io);
    try text("current", desktop.io.received(1));
    desktop.io.readers[0].blocked = false;
    // Becoming writable at the deadline must not revive a stalled transfer.
    desktop.clipboard.tick(5000, &desktop.io);
    try expect(desktop.io.readers[0].closed);
    try text("", desktop.io.received(0));
    reply(&app, &desktop, "reused");
    try equal(.success, desktop.indicator);
    try equal(3, desktop.copies);
    desktop.clipboard.cancelled(current, &desktop.io);
    desktop.clipboard.deinit(&desktop.io);
    try equal(0, desktop.io.live);
}

test "transfer exhaustion, short writes, interruptions, disconnect and preparation errors are bounded" {
    var desktop: TestDesktop(clipboard.Clipboard(8, 2, 1, u32)) = .{};
    var app: dictation.Session(8, .{ .samples = 1 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    reply(&app, &desktop, "12345678");
    const source = desktop.io.selected.?;
    desktop.io.readers[0].limit = 2;
    desktop.clipboard.send(source, 0, 0, &desktop.io);
    desktop.clipboard.send(source, 1, 0, &desktop.io);
    try expect(desktop.io.readers[1].closed);
    desktop.clipboard.tick(1, &desktop.io);
    try text("12", desktop.io.received(0));
    desktop.io.readers[0].blocked = true; // EAGAIN or EINTR
    desktop.clipboard.tick(4999, &desktop.io);
    desktop.io.readers[0].blocked = false;
    desktop.clipboard.tick(5000, &desktop.io); // before progress deadline (5001)
    try text("1234", desktop.io.received(0));
    desktop.io.readers[0].failed = true; // EPIPE; SIGPIPE ignored natively
    desktop.clipboard.tick(5001, &desktop.io);
    try expect(desktop.io.readers[0].closed);
    desktop.io.readers[1] = .{ .prepared = false };
    desktop.clipboard.send(source, 1, 5002, &desktop.io);
    try expect(desktop.io.readers[1].closed);
    desktop.io.readers[1] = .{};
    desktop.clipboard.send(source, 1, 5002, &desktop.io);
    desktop.clipboard.tick(5003, &desktop.io);
    try text("12345678", desktop.io.received(1));
    try equal(.success, desktop.indicator);
    // A request with no progress cannot pin indefinitely, even with zero writes.
    desktop.io.readers[0] = .{ .limit = 0 };
    desktop.clipboard.send(source, 0, 6000, &desktop.io);
    desktop.clipboard.tick(10999, &desktop.io);
    desktop.clipboard.tick(11000, &desktop.io);
    try expect(desktop.io.readers[0].closed);
    desktop.clipboard.deinit(&desktop.io);
}

test "source creation and selection failures preserve publication eligibility and release capacity" {
    var desktop: TestDesktop(clipboard.Clipboard(8, 2, 1, u32)) = .{};
    var app: dictation.Session(8, .{ .samples = 1 }) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.modelLoaded(true, &desktop);
    reply(&app, &desktop, "old");
    const old = desktop.io.selected.?;
    for (0..4) |failure| {
        desktop.io.create_failed = failure == 0;
        desktop.io.select_failed = failure == 1;
        reply(&app, &desktop, switch (failure) {
            2 => "   ",
            3 => "overflow!",
            else => "rejected",
        });
        try equal(old, desktop.io.selected.?);
        try equal(1, desktop.io.live);
        try equal(1, desktop.copies);
        try equal(@as(dictation.Indicator, if (failure == 2) .no_speech else .failure), desktop.indicator);
    }
    reply(&app, &desktop, "fits");
    try equal(.success, desktop.indicator);
    // Shutdown closes in-flight requests and destroys both still-live sources.
    desktop.clipboard.send(old, 0, 0, &desktop.io);
    desktop.clipboard.deinit(&desktop.io);
    try equal(0, desktop.io.live);
    try expect(desktop.io.readers[0].closed);
}

test "configured clipboard capacity copies independently and limits each reader to one write budget per turn" {
    const sizes = @import("config.zig").sizes;
    const Backing = struct {
        var serving: clipboard.Clipboard(sizes.transcript_bytes, sizes.clipboard_slots, sizes.transfers, u32) = .{};
        var value: [sizes.transcript_bytes]u8 = @splat('A');
    };
    const IO = struct {
        count: usize = 0,
        closed: bool = false,
        pub fn create(_: *@This()) ?u32 {
            return 1;
        }
        pub fn select(_: *@This(), _: u32) bool {
            return true;
        }
        pub fn destroy(_: *@This(), _: u32) void {}
        pub fn prepare(_: *@This(), _: i32) bool {
            return true;
        }
        pub fn write(self: *@This(), _: i32, bytes: []const u8) clipboard.Write {
            std.debug.assert(bytes.len <= clipboard.write_budget);
            std.debug.assert(std.mem.allEqual(u8, bytes, 'A'));
            self.count += bytes.len;
            return .{ .progress = bytes.len };
        }
        pub fn close(self: *@This(), _: i32) void {
            std.debug.assert(!self.closed);
            self.closed = true;
        }
    };
    var io: IO = .{};
    const serving = &Backing.serving;
    try expect(serving.publish(&Backing.value, &io));
    @memset(&Backing.value, 'B'); // preparing new work cannot modify offered bytes
    serving.send(1, 0, 0, &io);
    serving.tick(1, &io);
    try equal(@min(sizes.transcript_bytes, clipboard.write_budget), io.count);
    var now: i64 = 2;
    while (!io.closed) : (now += 1) serving.tick(now, &io);
    try equal(sizes.transcript_bytes, io.count);
    serving.cancelled(1, &io);
    serving.deinit(&io);
}
