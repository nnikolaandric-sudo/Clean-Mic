// CleanMic — RNNoise C bridge
// Faza 0.5 — zamjena mock NoiseProcessor-a pravim RNNoise C lib-om.
// Izlaže C API umjesto ObjC klase da bi Swift import bio trivijalan
// (bez bridging header-a, bez NSError throwable konverzije).
//
// Svi simboli imaju `cm_` prefix da se ne kolju sa drugim vendor-ima.

#ifndef CLEANMIC_RNNOISE_BRIDGE_H
#define CLEANMIC_RNNOISE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 480 za RNNoise (10ms @ 48kHz). Konstanto.
int32_t cm_rnnoise_frame_size(void);

/// Health-check: vraca 1 ako je RNNoise lib uspjesno linkovan i model
/// dostupan, 0 inace. Ako je `err` ne-NULL, upisuje kratak opis razloga.
/// `err` mora imati najmanje 256 bajtova.
int32_t cm_rnnoise_is_available(char *err, int32_t err_len);

/// Otvara RNNoise state. Vraca ne-NULL handle na uspjeh.
/// Ako `err` ne-NULL, popunjava opis greske (~256 bajtova).
void *cm_rnnoise_create(char *err, int32_t err_len);

/// Zatvara handle (poziva rnnoise_destroy).
void cm_rnnoise_destroy(void *handle);

/// Procesira jedan frame (480 float-ova).
/// VAD vjerovatnoca 0..1 (iz rnnoise_process_frame).
/// In-place poziv (input == output) je dozvoljen.
float cm_rnnoise_process_frame(void *handle, float *output, const float *input);

/// Resetuje state — handle se dealocira i re-alocira.
/// Pozivalac prosljedjuje &handle; nakon poziva `*handle` je novi state
/// (ili NULL ako recreate failuje). Best-effort.
void cm_rnnoise_reset(void **handle);

#ifdef __cplusplus
}
#endif

#endif
