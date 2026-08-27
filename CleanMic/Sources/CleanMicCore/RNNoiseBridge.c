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

float cm_rnnoise_process_frame(void *handle, float *output, const float *input) {
    if (!handle || !output || !input) return 0.0f;
    return rnnoise_process_frame((DenoiseState *)handle, output, input);
}

void cm_rnnoise_reset(void **handle) {
    if (!handle || !*handle) return;
    rnnoise_destroy((DenoiseState *)*handle);
    *handle = (void *)rnnoise_create(NULL);
}
