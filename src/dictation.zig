const std = @import("std");
pub const Indicator = enum { loading, idle, recording, finalizing, success, no_speech, failure };
pub const Capabilities = struct { layer_shell: bool, data_control: bool };

/// Single-threaded public seam. publish retains its own bounded copy. decode
/// borrows immutable samples until complete/fail, which may only be delivered
/// after inference relinquishes the slice. Other arguments are call-scoped.
pub fn Session(comptime capacity: usize, comptime audio_capacity: usize) type {
    return struct {
        const Self = @This();
        phase: Indicator = .idle,
        ready: bool = false,
        model: enum { loading, ready, failed } = .loading,
        source: ?u64 = null,
        transcript: [capacity]u8 = undefined,
        samples: [audio_capacity]f32 = undefined,
        sample_count: usize = 0,
        energy: f64 = 0,

        pub fn connect(self: *Self, capabilities: Capabilities) !void {
            if (!capabilities.layer_shell) return error.MissingLayerShell;
            if (!capabilities.data_control) return error.MissingDataControl;
            self.ready = true;
        }
        pub fn modelLoaded(self: *Self, success: bool, effects: anytype) void {
            self.model = if (success) .ready else .failed;
            self.phase = if (success) .idle else .failure;
            effects.show(self.phase);
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
            if (self.model != .ready) {
                effects.show(if (self.model == .loading) .loading else .failure);
                return;
            }
            // Asynchronous restart is milestone 05. Refuse, rather than reuse
            // samples still borrowed by the single inference worker.
            if (self.phase == .finalizing) return;
            if (self.phase == .recording) {
                _ = effects.recording(null);
                self.source = null;
                self.phase = .finalizing;
                if (self.sample_count == 0 or self.energy / @as(f64, @floatFromInt(self.sample_count)) < 0.000001) {
                    self.complete("", effects);
                    return;
                }
                if (!effects.decode(self.samples[0..self.sample_count])) {
                    self.fail(effects);
                    return;
                }
            } else {
                const source = effects.defaultSource() orelse {
                    effects.problem(error.DefaultMicrophoneUnavailable);
                    self.fail(effects);
                    return;
                };
                if (!effects.recording(source)) {
                    effects.problem(error.CaptureStart);
                    self.fail(effects);
                    return;
                }
                self.source = source;
                self.phase = .recording;
            }
            effects.show(self.phase);
        }
        pub fn audio(self: *Self, samples: []const f32, effects: anytype) void {
            if (self.phase != .recording) return;
            if (samples.len > audio_capacity - self.sample_count) {
                effects.problem(error.AudioCapacity);
                self.fail(effects);
                return;
            }
            for (samples) |sample| {
                if (!std.math.isFinite(sample)) {
                    effects.problem(error.InvalidPcm);
                    self.fail(effects);
                    return;
                }
                self.energy += @as(f64, sample) * sample;
            }
            @memcpy(self.samples[self.sample_count..][0..samples.len], samples);
            self.sample_count += samples.len;
        }
        fn clearAudio(self: *Self) void {
            @memset(self.samples[0..self.sample_count], 0);
            self.sample_count = 0;
            self.energy = 0;
        }
        pub fn sourceRemoved(self: *Self, source: u64, effects: anytype) void {
            if (self.phase == .recording and self.source == source) self.fail(effects);
        }
        pub fn captureFailed(self: *Self, effects: anytype) void {
            if (self.phase == .recording) self.fail(effects);
        }
        // Caller first stops capture and joins inference before shutdown.
        pub fn shutdown(self: *Self) void {
            self.clearAudio();
        }
        pub fn fail(self: *Self, effects: anytype) void {
            _ = effects.recording(null);
            self.source = null;
            self.clearAudio();
            self.phase = .failure;
            effects.show(.failure);
        }
        pub fn complete(self: *Self, result: []const u8, effects: anytype) void {
            if (self.phase != .finalizing) return;
            self.clearAudio();
            if (std.mem.trim(u8, result, " \r\n\t").len == 0) {
                self.phase = .no_speech;
                effects.show(self.phase);
                return;
            }
            if (result.len > capacity) {
                effects.problem(error.TranscriptCapacity);
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
