const std = @import("std");
pub const Indicator = enum { loading, idle, recording, finalizing, success, no_speech, failure };
pub const Capabilities = struct { layer_shell: bool, data_control: bool };
/// Capture callbacks carry the recording identity, even when the same device is reused.
pub const Capture = struct { session: u64, source: u64 };
/// Never reused within a daemon lifetime. Both counters fail closed on exhaustion.
pub const Operation = struct { session: u64, window: u64 };
pub const Windows = struct {
    samples: usize,
    slots: usize = 3,
    min_samples: usize = 1,
    pause_samples: usize = 1,
    context_bytes: usize = 256,

    pub fn validate(self: Windows) !void {
        _ = try std.math.mul(usize, try std.math.mul(usize, self.samples, self.slots), @sizeOf(f32));
        _ = try std.math.add(usize, self.context_bytes, 1);
        if (self.samples == 0 or self.samples > 16000 * 600) return error.InvalidAudioCapacity;
        if (self.slots < 2 or self.slots > 16) return error.InvalidAudioWindows;
        if (self.min_samples == 0 or self.min_samples > self.samples or self.pause_samples == 0 or self.pause_samples > self.min_samples) return error.InvalidWindowBoundary;
        if (self.context_bytes > 4096) return error.InvalidContextCapacity;
    }
};

/// Single-threaded public seam. publish copies; decode borrows immutable PCM
/// until a matching complete/inferenceFailed (not merely a cancel request). Call advance after releasing the decoder's
/// result slot, so the next queued window can be submitted. No other effect may
/// retain its arguments. Capture errors may arrive while PCM is still borrowed.
pub fn Session(comptime capacity: usize, comptime audio_config: Windows) type {
    comptime {
        audio_config.validate() catch |err| @compileError(@errorName(err));
    }
    return struct {
        const Self = @This();
        const Window = struct {
            samples: [audio_config.samples]f32 = undefined,
            len: usize = 0,
            energy: f64 = 0,
            quiet: usize = 0,
            fn clear(self: *@This()) void {
                @memset(self.samples[0..self.len], 0);
                self.len = 0;
                self.energy = 0;
                self.quiet = 0;
            }
        };
        phase: Indicator = .idle,
        ready: bool = false,
        model: enum { loading, ready, failed } = .loading,
        source: ?Capture = null,
        transcript: [capacity]u8 = undefined,
        transcript_len: usize = 0,
        windows: [audio_config.slots]Window = @splat(.{}),
        read_index: usize = 0,
        write_index: usize = 0,
        queued: usize = 0, // Sealed windows, including the decoder's borrow.
        generation: u64 = 0,
        window_number: u64 = 0,
        in_flight: ?Operation = null,

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
            if (self.phase == .recording) {
                _ = effects.recording(null);
                self.source = null;
                self.phase = .finalizing;
                effects.show(.finalizing);
                if (self.queued < audio_config.slots and self.windows[self.write_index].len != 0) self.seal();
                self.advance(effects);
            } else {
                if (self.phase == .finalizing) {
                    self.discard(effects);
                }
                self.generation = std.math.add(u64, self.generation, 1) catch {
                    effects.problem(error.SessionIdentityCapacity);
                    self.fail(effects);
                    return;
                };
                self.window_number = 0;
                const source = effects.defaultSource() orelse {
                    effects.problem(error.DefaultMicrophoneUnavailable);
                    self.fail(effects);
                    return;
                };
                const capture: Capture = .{ .session = self.generation, .source = source };
                if (!effects.recording(capture)) {
                    effects.problem(error.CaptureStart);
                    self.fail(effects);
                    return;
                }
                self.source = capture;
                self.phase = .recording;
                effects.show(.recording);
            }
        }
        pub fn audio(self: *Self, capture: Capture, samples: []const f32, effects: anytype) void {
            if (!self.capturing(capture)) return;
            self.advance(effects);
            for (samples) |sample| {
                if (self.phase != .recording) return;
                if (!std.math.isFinite(sample)) {
                    effects.problem(error.InvalidPcm);
                    self.fail(effects);
                    return;
                }
                if (self.queued == audio_config.slots) {
                    effects.problem(error.AudioCapacity);
                    self.fail(effects);
                    return;
                }
                const window = &self.windows[self.write_index];
                window.samples[window.len] = sample;
                window.len += 1;
                const energy = @as(f64, sample) * sample;
                window.energy += energy;
                window.quiet = if (energy < 0.000001) window.quiet + 1 else 0;
                if (window.len == audio_config.samples or (window.len >= audio_config.min_samples and window.quiet >= audio_config.pause_samples)) {
                    self.seal();
                    self.advance(effects);
                }
            }
        }
        fn seal(self: *Self) void {
            self.queued += 1;
            self.write_index = (self.write_index + 1) % audio_config.slots;
        }
        fn retire(self: *Self) void {
            self.windows[self.read_index].clear();
            self.read_index = (self.read_index + 1) % audio_config.slots;
            self.queued -= 1;
        }
        pub fn advance(self: *Self, effects: anytype) void {
            if (self.in_flight != null or (self.phase != .recording and self.phase != .finalizing)) return;
            while (self.queued != 0) {
                const window = &self.windows[self.read_index];
                if (window.energy / @as(f64, @floatFromInt(window.len)) < 0.000001) {
                    self.retire();
                    continue;
                }
                self.window_number = std.math.add(u64, self.window_number, 1) catch {
                    effects.problem(error.InferenceIdentityCapacity);
                    self.fail(effects);
                    return;
                };
                const operation: Operation = .{ .session = self.generation, .window = self.window_number };
                if (!effects.decode(operation, window.samples[0..window.len], self.context())) {
                    effects.problem(error.InferenceUnavailable);
                    self.fail(effects);
                    return;
                }
                self.in_flight = operation;
                return;
            }
            self.finish(effects);
        }
        fn context(self: *Self) []const u8 {
            var start = self.transcript_len - @min(self.transcript_len, audio_config.context_bytes);
            // Start at an ASCII whitespace boundary, never inside UTF-8 or a
            // partial word. Only prompt context is shortened, never the transcript.
            if (start != 0) {
                while (start < self.transcript_len and !std.ascii.isWhitespace(self.transcript[start - 1])) : (start += 1) {}
            }
            return std.mem.trim(u8, self.transcript[start..self.transcript_len], " \r\n\t");
        }
        fn clearTranscript(self: *Self) void {
            @memset(self.transcript[0..self.transcript_len], 0);
            self.transcript_len = 0;
        }
        fn capturing(self: *Self, capture: Capture) bool {
            const current = self.source orelse return false;
            return self.phase == .recording and std.meta.eql(current, capture);
        }
        pub fn sourceRemoved(self: *Self, capture: Capture, effects: anytype) void {
            self.captureFailed(capture, error.MicrophoneRemoved, effects);
        }
        pub fn captureFailed(self: *Self, capture: Capture, reason: anyerror, effects: anytype) void {
            if (!self.capturing(capture)) return;
            effects.problem(reason);
            self.fail(effects);
        }
        // Caller first closes capture and joins inference.
        pub fn shutdown(self: *Self) void {
            for (&self.windows) |*window| window.clear();
            self.clearTranscript();
            self.in_flight = null;
            self.queued = 0;
        }
        // Retain only the borrowed head. All other slots immediately belong to
        // replacement capture; queued includes that head until its owner returns.
        fn discard(self: *Self, effects: anytype) void {
            if (self.in_flight) |operation| {
                if (operation.session == self.generation) effects.cancel(operation);
            }
            self.clearTranscript();
            for (&self.windows, 0..) |*window, i| {
                if (self.in_flight == null or i != self.read_index) window.clear();
            }
            self.queued = if (self.in_flight != null) 1 else 0;
            self.write_index = (self.read_index + self.queued) % audio_config.slots;
        }
        pub fn fail(self: *Self, effects: anytype) void {
            _ = effects.recording(null);
            self.source = null;
            self.discard(effects);
            self.phase = .failure;
            effects.show(.failure);
        }
        fn returned(self: *Self, operation: Operation) bool {
            const flight = self.in_flight orelse return false;
            if (!std.meta.eql(operation, flight)) return false;
            self.in_flight = null;
            self.retire();
            return operation.session == self.generation and (self.phase == .recording or self.phase == .finalizing);
        }
        pub fn inferenceFailed(self: *Self, operation: Operation, reason: anyerror, effects: anytype) void {
            if (!self.returned(operation)) return;
            effects.problem(reason);
            self.fail(effects);
        }
        pub fn complete(self: *Self, operation: Operation, result: []const u8, effects: anytype) void {
            if (!self.returned(operation)) return;
            const trimmed = std.mem.trim(u8, result, " \r\n\t");
            if (trimmed.len != 0) {
                const separator: usize = if (self.transcript_len == 0) 0 else 1;
                const remaining = capacity - self.transcript_len;
                if (separator > remaining or trimmed.len > remaining - separator) {
                    effects.problem(error.TranscriptCapacity);
                    self.fail(effects);
                    return;
                }
                if (separator != 0) {
                    self.transcript[self.transcript_len] = ' ';
                    self.transcript_len += 1;
                }
                @memcpy(self.transcript[self.transcript_len..][0..trimmed.len], trimmed);
                self.transcript_len += trimmed.len;
            }
            self.finish(effects);
        }
        fn finish(self: *Self, effects: anytype) void {
            if (self.phase != .finalizing or self.queued != 0) return;
            self.phase = if (self.transcript_len == 0) .no_speech else if (effects.publish(self.transcript[0..self.transcript_len])) .success else .failure;
            self.clearTranscript();
            effects.show(self.phase);
        }
    };
}
