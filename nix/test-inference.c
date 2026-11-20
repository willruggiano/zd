/* Test-only decoder interposer. Never linked into or installed with dictation.
 * Model loading/state allocation, PCM capture and Wayland remain real. */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#ifdef DICTATION_TEST_CLIPBOARD
#include <stdio.h>
#include <string.h>
static char clipboard_text[131073];
#endif
#include <time.h>
#include <unistd.h>
#include <whisper.h>

#ifdef DICTATION_TEST_RESTART
static unsigned calls;
static int wait_for_restart(const struct whisper_full_params *params,
                            const float *samples, int n_samples, double energy) {
    static const char held[] = "test inference adapter: holding old operation\n";
    static const char cancelled[] = "test inference adapter: cancellation observed\n";
    if (write(STDERR_FILENO, held, sizeof(held) - 1) !=
        (ssize_t)(sizeof(held) - 1)) return -1;
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
    int observed = 0;
    for (int i = 0; i < 6000; ++i) {
        if (!observed && params->abort_callback &&
            params->abort_callback(params->abort_callback_user_data)) {
            observed = 1;
            if (write(STDERR_FILENO, cancelled, sizeof(cancelled) - 1) !=
                (ssize_t)(sizeof(cancelled) - 1)) return -1;
        }
        if (observed && access("restart-release", F_OK) == 0) {
            double retained = 0;
            for (int j = 0; j < n_samples; ++j)
                retained += (double)samples[j] * samples[j];
            if (retained != energy) return -1;
            static const char intact[] = "test inference adapter: borrowed PCM intact\n";
            if (write(STDERR_FILENO, intact, sizeof(intact) - 1) !=
                (ssize_t)(sizeof(intact) - 1)) return -1;
            return 0; /* Deliberately succeed despite cancellation, with old text. */
        }
        nanosleep(&delay, NULL);
    }
    return -1;
}
#endif

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
#ifdef DICTATION_TEST_RESTART
    if (++calls == 1) return wait_for_restart(&params, samples, n_samples, energy);
#endif
#ifdef DICTATION_TEST_CLIPBOARD
    static const char held[] = "test clipboard: decode held\n";
    if (write(STDERR_FILENO, held, sizeof(held) - 1) != (ssize_t)(sizeof(held) - 1)) return -1;
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
    for (int i = 0; i < 6000; ++i) {
        if (params.abort_callback && params.abort_callback(params.abort_callback_user_data)) return -1;
        FILE *gate = fopen("clipboard-release", "r");
        if (gate) {
            int value = fgetc(gate);
            fclose(gate);
            unlink("clipboard-release");
            if (value < 'A' || value > 'Z') return -1;
            memset(clipboard_text, value, sizeof(clipboard_text) - 1);
            return 0;
        }
        nanosleep(&delay, NULL);
    }
    return -1;
#endif
    return 0;
}

int whisper_full_n_segments_from_state(struct whisper_state *state) {
    (void)state;
    return 1;
}

const char *whisper_full_get_segment_text_from_state(struct whisper_state *state,
                                                    int segment) {
    (void)state;
#ifdef DICTATION_TEST_CLIPBOARD
    if (segment == 0) return clipboard_text;
#endif
#ifdef DICTATION_TEST_RESTART
    if (calls == 1) return "Abandoned partial from cancelled inference.";
#endif
    return segment == 0 ? "Virtual microphone input reached inference." : "";
}
