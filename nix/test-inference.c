/* Test-only decoder interposer. Never linked into or installed with dictation.
 * Model loading/state allocation, PCM capture and Wayland remain real. */
#include <math.h>
#include <unistd.h>
#include <whisper.h>

int whisper_full_with_state(struct whisper_context *ctx,
                            struct whisper_state *state,
                            struct whisper_full_params params,
                            const float *samples, int n_samples) {
    (void)ctx;
    (void)state;
    if (!samples || n_samples < WHISPER_SAMPLE_RATE) return -1;
    if (params.abort_callback && params.abort_callback(params.abort_callback_user_data)) return -1;
    double energy = 0;
    for (int i = 0; i < n_samples; ++i) {
        if (!isfinite(samples[i])) return -1;
        energy += (double)samples[i] * samples[i];
    }
    if (energy / n_samples < 0.000001) return -1;
    static const char diagnostic[] = "test inference adapter: non-silent PCM\n";
    if (write(STDERR_FILENO, diagnostic, sizeof(diagnostic) - 1) !=
        (ssize_t)(sizeof(diagnostic) - 1)) return -1;
    return 0;
}

int whisper_full_n_segments_from_state(struct whisper_state *state) {
    (void)state;
    return 1;
}

const char *whisper_full_get_segment_text_from_state(struct whisper_state *state,
                                                    int segment) {
    (void)state;
    return segment == 0 ? "Virtual microphone input reached inference." : "";
}
