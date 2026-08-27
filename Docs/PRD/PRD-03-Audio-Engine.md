# PRD-03 — Audio Engine Specifikacija (Capture, Processing, Real-Time Sigurnost)

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |
| Kritičnost | **P0 — Najveći tehnički rizik iza drivera** |

---

## 1. Cilj

Stabilan, low-latency audio pipeline od fizičkog mikrofona do virtualnog uređaja koji radi **2–4 sata bez dropova**, preživljava promjene uređaja i ne alocira u real-time callbacku.

---

## 2. Audio Pipeline — detaljno

### 2.1 Tok podataka

```
[1] Physical Mic (44.1/48k, mono/stereo, Int16/Float32)
  ↓  Core Audio HAL → AVAudioEngine Tap (bufferSize ~512–1024)
[2] Format Converter (AVAudioConverter)
  → 48 kHz / Mono / Float32 / non-interleaved
  ↓  copy → Input Ring Buffer (lock-free, prealociran)
[3] Processing Worker Thread (odvojen thread, visok prioritet)
  - čita 10ms frameove (480 samples @48k)
  - RNNoise process
  - VAD + gain/limiter
  ↓  copy → Output Ring Buffer
[4] Virtual Driver IOProc
  - čita iz OutputRing na zahtjev klijenta (Zoom itd.)
  - isporučuje PCM kao da je hardverski mic
```

### 2.2 Veličine buffera (inicijalni prijedlog — potvrditi mjerenjem)

| Buffer | Veličina | Razlog |
|--------|----------|--------|
| HAL callback buffer | 512 frames (~10.6 ms @48k) | Balans latencija/stabilnost |
| Input Ring | 16384 samples (~340 ms) | Apsorbuje jitter, device change |
| Processing frame | 480 samples (10 ms) | RNNoise native |
| Output Ring | 16384 samples (~340 ms) | Isto kao input |
| Virtual driver buffer | Zavisi od klijenta (obično 512) | Mora biti spreman odmah |

**Formula za end-to-end latenciju:**
```
Total = capture buffer + converter delay + ring queueing + RNNoise (10ms) + output queueing + driver buffer
Cilj: 20–30 ms dodatno (bez hardware latency-a)
```

---

## 3. Real-Time Sigurnost (Critical)

### 3.1 Šta se NE smije raditi u audio callbacku

| Zabranjeno | Zašto | Alternativa |
|------------|-------|-------------|
| `malloc` / `free` / `new` | Može blokirati, uzrokuje drop | Prealocirati sve na startu |
| `lock` / `mutex` / `dispatch_sync` | Priority inversion | Lock-free SPSC queue |
| `NSLog` / `print` / file I/O | Blokirajuće | Ring log buffer, flush van callbacka |
| `Swift ARC retain/release` | Nepredvidivo | Koristi `Unmanaged` ili C++ u hot path-u |
| `Objective-C message send` (težak) | Overhead | C funkcija |
| `RNNoise inference` | Teško, blokira | Premjestiti u worker thread |

### 3.2 Šta callback smije raditi

- `memcpy` PCM-a u InputRing (lock-free `write`)
- `memcpy` iz OutputRing u driver buffer (na driver strani)
- Atomics (`std::atomic`, `OSAtomic`)
- Provjera `availableBytes` i brojanje underrun-a (in-memory counter)

### 3.3 Worker thread

- Prioritet: `THREAD_TIME_CONSTRAINT_POLICY` ili `qos_class_t = QOS_CLASS_USER_INTERACTIVE`
- Alokacije dozvoljene **samo** na startu; u loop-u nema `malloc`
- RNNoise se poziva ovdje — **ne u callbacku**
- Sleep strategija: `mach_wait_until` / `semaphore` / `condition_variable` sa timeoutom, ne busy-wait

---

## 4. Format Converter Spec

| Ulaz | Izlaz |
|------|-------|
| Sample rate: 44.1k / 48k / 16k / ... | 48 kHz |
| Kanali: 1 / 2 | 1 (mono, mixdown) |
| Format: Int16 / Int32 / Float32 | Float32 |
| Interleaved / non-interleaved | Non-interleaved |

- Koristiti `AVAudioConverter` (Swift) ili `AudioConverterRef` (C)
- Testirati kvalitet resamplinga: ne smije unositi aliasing koji RNNoise pogrešno klasifikuje kao šum/govor
- Fallback: ako je ulaz već 48k/mono/Float32 → bypass converter (zero-copy)

---

## 5. Ring Buffer Spec

### 5.1 Zahtjevi

- **Lock-free, SPSC** (single producer, single consumer)
- **Prealociran** — `malloc` samo u `init`, `free` u `deinit`
- **Cache-friendly** — power-of-two veličina, head/tail kao `atomic<int>`
- **API:**
  ```cpp
  class RingBuffer {
    bool write(const float* data, size_t frames);
    bool read(float* out, size_t frames);
    size_t availableRead();
    size_t availableWrite();
    void reset();
  };
  ```
- **Underrun/overrun handling:**
  - Ako `availableRead < needed` → underrun counter++, isporuči tišinu ili prethodni frame
  - Ako `availableWrite < needed` → overrun counter++, odbaci najstariji (ili novi, definisati)

### 5.2 Implementacija

- Opcije: `TPCircularBuffer` (Apple sample), `moodycamel::ReaderWriterQueue`, ili custom
- Preporuka: custom na bazi `std::atomic` sa `memory_order_acquire/release`
- Test: stress test sa 2 threada, 48kHz, 2h, provjera da nema data race (TSan)

---

## 6. Noise Engine — RNNoise integracija

### 6.1 RNNoise API (C)

```c
DenoiseState* rnnoise_create(NULL);
void rnnoise_destroy(DenoiseState* st);
float rnnoise_process_frame(DenoiseState* st, float* out, const float* in);
```

- `in` / `out`: 480 Float32 samples (10 ms @48k)
- Vraća VAD vjerovatnoću (0–1) kao povratnu vrijednost

### 6.2 Wrapper (Objective-C++)

```objc
// NoiseProcessor.h
@interface NoiseProcessor : NSObject
- (instancetype)initWithMode:(CleanMicMode)mode;
- (void)processFrame:(float*)out input:(const float*)in vad:(float*)vadOut;
- (void)setMode:(CleanMicMode)mode;
- (void)reset;
@end

// NoiseProcessor.mm — poziva rnnoise_process_frame
```

### 6.3 Modovi

| Mod | RNNoise strength | Post-processing |
|-----|------------------|-----------------|
| Light | 0.3 | Blagi gain, bez limitera |
| Balanced | 0.6 | Srednji gain + soft limiter |
| Maximum | 0.9 | Agresivniji + hard limiter + VAD gate |

- `strength` se može implementirati kao `out = in * (1 - strength) + rnnoise_out * strength` ili direktno preko RNNoise parametra ako postoji
- Mjerenje: PESQ / STOI / subjektivni listening test za svaki mod

### 6.4 Buduća zamjena (v2.0)

- DeepFilterNet: veći kvalitet, veći CPU — samo za M1+ i opciono
- Core ML: iskoristiti Neural Engine — zahtijeva konverziju modela

---

## 7. Processing Pipeline — VAD, Gain, Limiter

```
RNNoise out (480 samples)
  → VAD (0–1) — ako < threshold, pojačaj supresiju
  → Gain: kompenzuj gubitak glasnoće (npr. +3 dB)
  → Limiter: spreči clipping (>0 dBFS) — lookahead 1-2ms ili soft clip
  → Output
```

- **AGC (opciono za v1.1):** Automatski gain da govor bude konzistentan
- **Fail-safe:** ako `rnnoise_process_frame` vrati NaN ili `processingTime > 10ms` → bypass frame

---

## 8. Device Monitor — promjene uređaja

### 8.1 Događaji koje treba hendlovati

| Događaj | Izvor | Akcija |
|---------|-------|--------|
| Default input promijenjen | `kAudioHardwarePropertyDefaultInputDevice` | Re-enumerate, switch ako je auto |
| Uređaj unplugged | `kAudioDevicePropertyDeviceIsAlive` | Pause → fallback na sljedeći dostupan |
| Sample rate promjena | `kAudioDevicePropertyNominalSampleRate` | Reconfigure converter |
| Sleep | `NSWorkspace.screensDidSleepNotification` | Pause pipeline |
| Wake | `screensDidWakeNotification` | Resume, re-init capture |
| Bluetooth reconnect | Isto kao unplug/plug | Auto-reconnect <2s |

### 8.2 Recovery flow

```
Detect change → pause worker → drain rings → re-init capture with new format → reset rings → resume worker → update UI
```

- Mora biti **bez crasha** i bez ostavljanja virtualnog uređaja u invalid stanju
- Testirati sa AirPods (najčešći edge case)

---

## 9. Metrics & Diagnostics

| Metrika | Kako mjeriti | Alarm |
|---------|--------------|-------|
| Frame processing time | `mach_absolute_time` prije/poslije `rnnoise_process_frame` | >8 ms |
| CPU % | `task_info` / `host_statistics` | >15% sustained |
| Underrun count | `availableRead < needed` | >0 u 10 min |
| Overrun count | `availableWrite < needed` | >0 u 10 min |
| Latency | Loopback: generiši impuls → mjeri kašnjenje kroz pipeline | >30 ms dodatno |
| Memory | `footprint` | Rast >1 MB / h |

- Logovati u cirkularni buffer, flush na disk van real-time threada
- **Nikad ne logovati audio sadržaj**

---

## 10. Test plan za Audio Engine (sažetak — detaljno u PRD-06)

- **Offline test:** WAV file → kroz NoiseProcessor → slušni test
- **Real-time test:** Mic → pipeline → virtual mic → slušalice (loopback)
- **Soak test:** 2–4h kontinuiranog rada, prati underrun/CPU/memory
- **Device switch test:** 20x plug/unplug tokom rada
- **Sleep/wake test:** 10x sleep/wake
- **Performance test:** Instruments → Time Profiler, Allocations

---

## 11. Rizici i mitigacije

| Rizik | Mitigacija |
|-------|------------|
| AVAudioEngine tap nije dovoljno stabilan za produkciju | Spike: uporedi sa direktnim HAL IOProc, ostavi apstrakciju |
| RNNoise latency prevelika za 20ms cilj | Mjeri odmah u Fazi 0; ako >10ms, smanji buffer ili koristi manji frame |
| Ring buffer underrun na starijim Macovima | Povećati ring veličinu, testirati na Intel i M1 |
| Swift ARC u callbacku | Izdvojiti hot path u C++ |

---

**Sledeći dokument:** `PRD-04-Virtual-Driver.md`
