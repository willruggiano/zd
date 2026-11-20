const std = @import("std");
const c = @import("c");
const Operation = @import("dictation.zig").Operation;
const sizes = @import("config.zig").sizes;

pub const State = enum(u8) { loading, loaded, idle, decoding, complete, failed, load_failed };
/// One resident context, one borrowed audio slice, one completion slot.
/// Release/acquire transfers ownership in both directions. The session owns
/// the bounded FIFO; this worker never queues or decodes concurrent jobs.
pub const Worker = struct {
    thread: c.pthread_t = undefined,
    attr: c.pthread_attr_t = undefined,
    started: bool = false,
    state: State = .loading,
    stopping: bool = false,
    cancelled: bool = false,
    operation: Operation = .{ .session = 0, .window = 0 },
    model_path: [*:0]const u8 = undefined,
    cuda: bool = true,
    samples: []const f32 = &.{},
    result: [sizes.transcript_bytes]u8 = undefined,
    result_len: usize = 0,
    prompt: [sizes.context_bytes + 1]u8 = undefined,
    prompt_len: usize = 0,
    short_audio: [c.WHISPER_SAMPLE_RATE]f32 = undefined,
    problem: anyerror = error.InferenceFailure,
    params: c.whisper_full_params = undefined,
    stack: [sizes.worker_stack_bytes]u8 align(65536) = undefined,

    pub fn start(self: *Worker, path: [*:0]const u8, cuda: bool) !void {
        self.model_path = path;
        self.cuda = cuda;
        if (c.pthread_attr_init(&self.attr) != 0) return error.WorkerAttributes;
        defer _ = c.pthread_attr_destroy(&self.attr);
        if (c.pthread_attr_setstack(&self.attr, &self.stack, self.stack.len) != 0) return error.WorkerStack;
        if (c.pthread_create(&self.thread, &self.attr, run, self) != 0) return error.WorkerStart;
        self.started = true;
    }
    pub fn status(self: *Worker) State {
        return @atomicLoad(State, &self.state, .acquire);
    }
    pub fn release(self: *Worker) void {
        @memset(self.result[0..self.result_len], 0);
        self.result_len = 0;
        self.clearPrompt();
        @atomicStore(State, &self.state, .idle, .release);
    }
    pub fn decode(self: *Worker, operation: Operation, samples: []const f32, context: []const u8) bool {
        if (self.status() != .idle or context.len > sizes.context_bytes) return false;
        @memcpy(self.prompt[0..context.len], context);
        self.prompt[context.len] = 0;
        self.prompt_len = context.len;
        self.params.initial_prompt = if (context.len == 0) null else &self.prompt;
        self.samples = samples;
        self.operation = operation;
        @atomicStore(bool, &self.cancelled, false, .release);
        @atomicStore(State, &self.state, .decoding, .release);
        return true;
    }
    pub fn cancel(self: *Worker, operation: Operation) void {
        // Main-thread identity check; cancellation never releases borrowed data.
        if (std.meta.eql(operation, self.operation)) @atomicStore(bool, &self.cancelled, true, .release);
    }
    fn clearPrompt(self: *Worker) void {
        @memset(self.prompt[0 .. self.prompt_len + 1], 0);
        self.prompt_len = 0;
    }
    pub fn deinit(self: *Worker) void {
        if (!self.started) return;
        @atomicStore(bool, &self.stopping, true, .release);
        _ = c.pthread_join(self.thread, null);
        @memset(self.result[0..self.result_len], 0);
        self.result_len = 0;
        self.samples = &.{};
        self.clearPrompt();
        self.started = false;
    }
    fn run(data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Worker = @ptrCast(@alignCast(data.?));
        // Never forward library strings: they may contain recognized text.
        c.whisper_log_set(silentLog, null);
        c.ggml_log_set(silentLog, null);
        var context_params = c.whisper_context_default_params();
        context_params.use_gpu = self.cuda;
        context_params.gpu_device = 0;
        const context = c.whisper_init_from_file_with_params_no_state(self.model_path, context_params) orelse {
            @atomicStore(State, &self.state, .load_failed, .release);
            return null;
        };
        defer c.whisper_free(context);
        // Verify the backend before readiness, but do not retain past audio/text
        // in a resident decoder state. Only the model context remains resident.
        var decoder = c.whisper_init_state(context) orelse {
            @atomicStore(State, &self.state, .load_failed, .release);
            return null;
        };
        var decoder_live = true;
        defer if (decoder_live) c.whisper_free_state(decoder);
        self.params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        self.params.n_threads = @intCast(sizes.inference_threads);
        self.params.language = "en";
        self.params.translate = false;
        self.params.no_context = true;
        self.params.no_timestamps = true;
        self.params.print_realtime = false;
        self.params.print_progress = false;
        self.params.print_timestamps = false;
        self.params.print_special = false;
        self.params.suppress_nst = true;
        self.params.abort_callback = abort;
        self.params.abort_callback_user_data = self;
        @atomicStore(State, &self.state, .loaded, .release);
        const delay: c.timespec = .{ .tv_sec = 0, .tv_nsec = 10_000_000 };
        while (!@atomicLoad(bool, &self.stopping, .acquire)) {
            if (self.status() != .decoding) {
                _ = c.nanosleep(&delay, null);
                continue;
            }
            if (!decoder_live) {
                decoder = c.whisper_init_state(context) orelse {
                    self.samples = &.{};
                    self.problem = error.InferenceInitialization;
                    @atomicStore(State, &self.state, .failed, .release);
                    continue;
                };
                decoder_live = true;
            }
            // whisper.cpp skips inputs shorter than 100 ms. Give short tails
            // one second including silence, without copying full-size windows.
            const padded = self.samples.len < self.short_audio.len;
            if (padded) {
                @memcpy(self.short_audio[0..self.samples.len], self.samples);
                @memset(self.short_audio[self.samples.len..], 0);
            }
            const pcm = if (padded) &self.short_audio else self.samples;
            const succeeded = !@atomicLoad(bool, &self.cancelled, .acquire) and c.whisper_full_with_state(context, decoder, self.params, pcm.ptr, @intCast(pcm.len)) == 0;
            if (padded) @memset(&self.short_audio, 0);
            self.samples = &.{};
            const cancelled = @atomicLoad(bool, &self.cancelled, .acquire);
            self.problem = if (cancelled) error.InferenceCancelled else error.InferenceFailure;
            var valid = succeeded and !cancelled;
            self.result_len = 0;
            if (valid) {
                const count = c.whisper_full_n_segments_from_state(decoder);
                var i: c_int = 0;
                while (i < count) : (i += 1) {
                    const ptr = c.whisper_full_get_segment_text_from_state(decoder, i);
                    if (ptr == null) {
                        valid = false;
                        break;
                    }
                    const text = std.mem.span(ptr);
                    if (text.len > self.result.len - self.result_len) {
                        self.problem = error.TranscriptCapacity;
                        valid = false;
                        break;
                    }
                    @memcpy(self.result[self.result_len..][0..text.len], text);
                    self.result_len += text.len;
                }
            }
            c.whisper_free_state(decoder);
            decoder_live = false;
            @atomicStore(State, &self.state, if (valid) .complete else .failed, .release);
        }
        return null;
    }
};
fn silentLog(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
fn abort(data: ?*anyopaque) callconv(.c) bool {
    const self: *Worker = @ptrCast(@alignCast(data.?));
    return @atomicLoad(bool, &self.stopping, .acquire) or @atomicLoad(bool, &self.cancelled, .acquire);
}
