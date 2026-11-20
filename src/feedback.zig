pub const density = 2;
pub const width = 160 * density;
pub const height = 40 * density;
pub const frame_count = 2;
pub const backing_per_output = frame_count * width * height * 4;

const Indicator = @import("dictation.zig").Indicator;

/// Public dictation feedback seam. Native surfaces consume the latest state,
/// never a queue of old volume/timer events. draw returns false while buffers
/// are busy or a surface awaits configure; retain dirty state until it succeeds.
pub fn Feedback(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 64) @compileError("InvalidOutputCapacity");
    return struct {
        const Self = @This();
        const Output = struct { id: u32 = 0, dirty: bool = true };
        outputs: [capacity]Output = @splat(.{}),
        phase: Indicator = .idle,
        volume: u8 = 0,
        feedback_until: i64 = 0,
        volume_until: i64 = 0,

        pub fn outputAdded(self: *Self, id: u32) !void {
            if (id == 0) return error.InvalidOutput;
            for (self.outputs) |output| if (output.id == id) return;
            for (&self.outputs) |*output| if (output.id == 0) {
                output.* = .{ .id = id };
                return;
            };
            return error.OutputCapacity;
        }
        pub fn outputRemoved(self: *Self, id: u32) void {
            for (&self.outputs) |*output| if (output.id == id) {
                output.* = .{};
                return;
            };
        }
        // Geometry/scale/configure changes redraw current state, not old feedback.
        // Logical size/anchoring remain compositor managed.
        pub fn outputChanged(self: *Self, id: u32) void {
            for (&self.outputs) |*output| if (output.id == id) {
                output.dirty = true;
            };
        }
        fn dirty(self: *Self) void {
            for (&self.outputs) |*output| output.dirty = true;
        }
        pub fn show(self: *Self, phase: Indicator, now: i64) void {
            self.phase = phase;
            self.volume = 0;
            self.volume_until = 0;
            self.feedback_until = switch (phase) {
                .success, .no_speech, .failure => now + 900,
                else => 0,
            };
            self.dirty();
        }
        pub fn level(self: *Self, value: f32, now: i64) void {
            if (self.phase != .recording) return;
            // Session supplies finite normalized RMS. Do not retain PCM here.
            const volume: u8 = @intFromFloat(@min(1, @max(0, value)) * 24);
            if (volume != self.volume) self.dirty();
            self.volume = volume;
            self.volume_until = now + 150;
        }
        pub fn tick(self: *Self, now: i64, effects: anytype) void {
            if (self.feedback_until != 0 and now >= self.feedback_until) self.show(.idle, now);
            if (self.volume_until != 0 and now >= self.volume_until) {
                self.volume_until = 0;
                if (self.volume != 0) self.dirty();
                self.volume = 0;
            }
            for (&self.outputs) |*output| {
                if (output.id != 0 and output.dirty and effects.draw(output.id, self.phase, self.volume)) output.dirty = false;
            }
        }
    };
}
