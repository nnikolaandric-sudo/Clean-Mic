// CleanMic — RNNoise C bridge implementation
// Wrappuje rnnoise.h (vendor/rnnoise/include) u C API.

#include "RNNoiseBridge.h"
#include "rnnoise.h"

#include <string.h>
#include <stdio.h>

static void write_err(char *err, int32_t err_len, const char *msg) {
    if (!err || err_len <= 0) return;
    snprintf(err, (size_t)err_len, "%s", msg);
}

int32_t cm_rnnoise_frame_size(void) {
    return (int32_t)rnnoise_get_frame_size();
}

int32_t cm_rnnoise_is_available(char *err, int32_t err_len) {
    int32_t fs = rnnoise_get_frame_size();
    if (fs != 480) {
        write_err(err, err_len, "rnnoise_get_frame_size() returned unexpected value (lib not linked?)");
        return 0;
    }
    DenoiseState *test = rnnoise_create(NULL);
    if (!test) {
        write_err(err, err_len, "rnnoise_create(NULL) returned NULL (model data missing or corrupt)");
        return 0;
    }
    rnnoise_destroy(test);
    return 1;
}

void *cm_rnnoise_create(char *err, int32_t err_len) {
    DenoiseState *s = rnnoise_create(NULL);
    if (!s) {
        write_err(err, err_len, "rnnoise_create() returned NULL");
        return NULL;
    }
    return (void *)s;
}

void cm_rnnoise_destroy(void *handle) {
    if (!handle) return;
    rnnoise_destroy((DenoiseState *)handle);
}

// RNNoise ocekuje uzorke u opsegu 16-bitnog PCM-a (+-32768), NE normalizovane
// +-1.0 float uzorke. Vidi examples/rnnoise_demo.c: `x[i] = tmp[i]` gdje je
// tmp[] short — nema dijeljenja sa 32768.
//
// CleanMic interno radi sa normalizovanim +-1.0 uzorcima (AVAudioEngine Float32),
// pa ovdje skaliramo na ulazu i vracamo nazad na izlazu. Bez ovoga RNNoise vidi
// signal 32768x pretih, VAD ostaje ~0.0 i denoise ne radi nista.
#define CM_RNNOISE_SCALE 32768.0f

float cm_rnnoise_process_frame(void *handle, float *output, const float *input) {
    if (!handle || !output || !input) return 0.0f;

    const int frame_size = rnnoise_get_frame_size();
    float scaled[480];
    if (frame_size != 480) return 0.0f;

    for (int i = 0; i < frame_size; i++) {
        scaled[i] = input[i] * CM_RNNOISE_SCALE;
    }

    float vad = rnnoise_process_frame((DenoiseState *)handle, scaled, scaled);

    const float inv = 1.0f / CM_RNNOISE_SCALE;
    for (int i = 0; i < frame_size; i++) {
        output[i] = scaled[i] * inv;
    }
    return vad;
}

void cm_rnnoise_reset(void **handle) {
    if (!handle || !*handle) return;
    rnnoise_destroy((DenoiseState *)*handle);
    *handle = (void *)rnnoise_create(NULL);
}
