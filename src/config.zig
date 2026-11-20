const std = @import("std");
const options = @import("options.zig");
pub const Sizes = struct {
    transcript_bytes: usize = 1048576,
    control_clients: usize = 8,
    clipboard_slots: usize = 3,
    transfers: usize = 8,
    audio_samples: usize = 480000,
    audio_windows: usize = 3,
    window_min_samples: usize = 48000,
    pause_samples: usize = 8000,
    context_bytes: usize = 256,
    device_slots: usize = 32,
    output_slots: usize = 8,
    worker_stack_bytes: usize = 8388608,
    inference_threads: usize = 4,

    pub fn windows(self: Sizes) @import("dictation.zig").Windows {
        return .{ .samples = self.audio_samples, .slots = self.audio_windows, .min_samples = self.window_min_samples, .pause_samples = self.pause_samples, .context_bytes = self.context_bytes };
    }
    pub fn validate(self: Sizes) !void {
        try self.windows().validate();
        _ = try std.math.mul(usize, self.output_slots, @import("feedback.zig").backing_per_output);
        if (self.output_slots == 0 or self.output_slots > 64) return error.InvalidOutputCapacity;
        _ = try std.math.mul(usize, self.transcript_bytes, try std.math.add(usize, self.clipboard_slots, 1));
        const pcm = try std.math.mul(usize, try std.math.mul(usize, self.audio_samples, self.audio_windows), @sizeOf(f32));
        _ = try std.math.add(usize, pcm, self.worker_stack_bytes);
        if (self.audio_samples == 0 or self.audio_samples > 16000 * 600) return error.InvalidAudioCapacity;
        if (self.device_slots == 0 or self.device_slots > 256) return error.InvalidDeviceCapacity;
        if (self.worker_stack_bytes < 1048576 or self.worker_stack_bytes > 67108864 or self.worker_stack_bytes % 65536 != 0) return error.InvalidWorkerStack;
        if (self.inference_threads == 0 or self.inference_threads > 64) return error.InvalidInferenceThreads;
        if (self.transcript_bytes == 0 or self.transcript_bytes > 64 * 1024 * 1024) return error.InvalidTranscriptCapacity;
        if (self.control_clients == 0 or self.control_clients > 64) return error.InvalidControlCapacity;
        if (self.clipboard_slots < 2 or self.clipboard_slots > 8) return error.InvalidClipboardSlots;
        if (self.transfers == 0 or self.transfers > 64) return error.InvalidTransferCapacity;
    }
};
pub const sizes: Sizes = .{
    .transcript_bytes = options.transcript_bytes,
    .control_clients = options.control_clients,
    .clipboard_slots = options.clipboard_slots,
    .transfers = options.transfers,
    .audio_samples = options.audio_samples,
    .audio_windows = options.audio_windows,
    .window_min_samples = options.window_min_samples,
    .pause_samples = options.pause_samples,
    .context_bytes = options.context_bytes,
    .device_slots = options.device_slots,
    .output_slots = options.output_slots,
    .worker_stack_bytes = options.worker_stack_bytes,
    .inference_threads = options.inference_threads,
};
comptime {
    sizes.validate() catch |err| @compileError(@errorName(err));
}
