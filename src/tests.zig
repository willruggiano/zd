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
    pub fn recording(self: *@This(), active: bool) void {
        self.capture = active;
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
    var app: dictation.Session(64) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.toggle(&desktop);
    try expect(desktop.capture);
    try equal(.recording, desktop.indicator);
    try equal(0, desktop.copies);
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
    var app: dictation.Session(8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    for ([_][]const u8{ "", "Too long!", "Fits" }) |result| {
        app.toggle(&desktop);
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
    var app: dictation.Session(64) = .{};
    try std.testing.expectError(error.MissingLayerShell, app.connect(.{ .layer_shell = false, .data_control = true }));
    try std.testing.expectError(error.MissingDataControl, app.connect(.{ .layer_shell = true, .data_control = false }));
    try equal(.unavailable, app.command("toggle", &desktop));
    try expect(!desktop.capture);
    try app.connect(.{ .layer_shell = true, .data_control = true });
    for ([_][]const u8{ "", "toggle\n", "toggle\x00", "toggle toggle", "garbage" }) |request| {
        try equal(.invalid, app.command(request, &desktop));
    }
    try expect(!desktop.capture);
    try equal(.accepted, app.command("toggle", &desktop));
    try expect(desktop.capture);
}

test "exact transcript boundary succeeds at non-default capacity" {
    var desktop: Desktop = .{};
    var app: dictation.Session(8) = .{};
    try app.connect(.{ .layer_shell = true, .data_control = true });
    app.toggle(&desktop);
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
        var app: dictation.Session(@import("config.zig").sizes.transcript_bytes) = .{};
    };
    const app = &Backing.app;
    try app.connect(.{ .layer_shell = true, .data_control = true });
    for (0..4) |_| {
        app.toggle(&desktop);
        app.toggle(&desktop);
        app.complete("X", &desktop);
        app.toggle(&desktop);
        try expect(desktop.capture);
        try text("X", desktop.copied[0..desktop.len]);
        app.toggle(&desktop);
        try expect(!desktop.capture);
        try text("X", desktop.copied[0..desktop.len]);
        app.complete("   \n", &desktop);
        try equal(.no_speech, desktop.indicator);
        try text("X", desktop.copied[0..desktop.len]);
    }
    try equal(4, desktop.copies);
}
