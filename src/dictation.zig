const std = @import("std");
pub const Indicator = enum { idle, recording, finalizing, success, no_speech, failure };
pub const Capabilities = struct { layer_shell: bool, data_control: bool };

/// Single-threaded public seam. Adapters borrow arguments only for the call;
/// publish must retain its own bounded copy before returning true.
pub fn Session(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        phase: Indicator = .idle,
        ready: bool = false,
        transcript: [capacity]u8 = undefined,

        pub fn connect(self: *Self, capabilities: Capabilities) !void {
            if (!capabilities.layer_shell) return error.MissingLayerShell;
            if (!capabilities.data_control) return error.MissingDataControl;
            self.ready = true;
        }
        pub const Reply = enum { accepted, invalid, unavailable };
        pub fn command(self: *Self, request: []const u8, effects: anytype) Reply {
            if (!std.mem.eql(u8, request, "toggle")) return .invalid;
            if (!self.ready) return .unavailable;
            self.toggle(effects);
            return .accepted;
        }
        pub fn toggle(self: *Self, effects: anytype) void {
            if (!self.ready) return;
            if (self.phase == .recording) {
                effects.recording(false);
                self.phase = .finalizing;
            } else {
                effects.recording(true);
                self.phase = .recording;
            }
            effects.show(self.phase);
        }
        pub fn complete(self: *Self, result: []const u8, effects: anytype) void {
            if (self.phase != .finalizing) return;
            if (std.mem.trim(u8, result, " \r\n\t").len == 0) {
                self.phase = .no_speech;
                effects.show(self.phase);
                return;
            }
            if (result.len > capacity) {
                self.phase = .failure;
                effects.show(self.phase);
                return;
            }
            @memcpy(self.transcript[0..result.len], result);
            self.phase = if (effects.publish(self.transcript[0..result.len])) .success else .failure;
            @memset(self.transcript[0..result.len], 0);
            effects.show(self.phase);
        }
    };
}
