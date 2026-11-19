const std = @import("std");
const c = @import("c");
const sizes = @import("config.zig").sizes;

pub const State = enum(u8) { loading, loaded, idle, decoding, complete, failed, load_failed };
/// One resident context, one borrowed audio slice, one completion slot.
/// Release/acquire transfers ownership in both directions. No job queue.
pub const Worker = struct {
    thread: c.pthread_t = undefined,
    attr: c.pthread_attr_t = undefined,
    started: bool = false,
    state: State = .loading,
    stopping: bool = false,
    model_path: [*:0]const u8 = undefined,
    cuda: bool = true,
    samples: []const f32 = &.{},
    result: [sizes.transcript_bytes]u8 = undefined,
    result_len: usize = 0,
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
        @atomicStore(State, &self.state, .idle, .release);
    }
    pub fn decode(self: *Worker, samples: []const f32) bool {
        if (self.status() != .idle) return false;
        self.samples = samples;
        @atomicStore(State, &self.state, .decoding, .release);
        return true;
    }
    pub fn deinit(self: *Worker) void {
        if (!self.started) return;
        @atomicStore(bool, &self.stopping, true, .release);
        _ = c.pthread_join(self.thread, null);
        @memset(self.result[0..self.result_len], 0);
        self.result_len = 0;
        self.samples = &.{};
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
            const succeeded = c.whisper_full_with_state(context, decoder, self.params, self.samples.ptr, @intCast(self.samples.len)) == 0;
            self.samples = &.{};
            self.problem = error.InferenceFailure;
            var valid = succeeded;
            self.result_len = 0;
            if (succeeded) {
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
    return @atomicLoad(bool, &self.stopping, .acquire);
}
