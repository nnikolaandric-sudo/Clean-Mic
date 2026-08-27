# PRD-02 — Tehnička Arhitektura i Komponente Sistema

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |
| Zavisnost | PRD-00, PRD-01 |

---

## 1. Pregled arhitekture

### 1.1 Audio pipeline (end-to-end)

```
┌─────────────────┐
│ Physical Mic    │  MacBook / AirPods / USB mic
└────────┬────────┘
         ↓  AVAudioEngine / Core Audio Capture
┌─────────────────┐
│ Format Converter│  Resample → 48 kHz / Mono / Float32 PCM
└────────┬────────┘
         ↓  Lock-free Input Ring Buffer (prealociran)
┌─────────────────┐
│ Processing      │  Dedicated Worker Thread
│ Worker          │  RNNoise → VAD → Gain / Limiter
└────────┬────────┘
         ↓  Lock-free Output Ring Buffer
┌─────────────────┐
│ CleanMic        │  Audio Server Driver Plug-in
│ Virtual Device  │  HAL — vidljiv kao sistemski input
└────────┬────────┘
         ↓
┌─────────────────┐
│ Client Apps     │  Zoom / Meet / Teams / Discord / Browser
└─────────────────┘
```

### 1.2 Ključni princip

> **Audio callback mora ostati real-time safe.**
>
> - Nema `malloc`, `free`, `lock`, `log`, `disk I/O`, `network` u callbacku.
> - Sav težak rad ide u **processing worker** preko **prealociranih ring buffera**.
> - Callback samo kopira PCM u/out buffera i vraća se.

---

## 2. Glavne komponente

| # | Komponenta | Lokacija u repo-u | Tehnologija | Odgovornost |
|---|------------|-------------------|-------------|-------------|
| C-01 | **CleanMic.app** | `CleanMic/App/` | Swift + SwiftUI | Menu-bar UI, settings, dozvole, DeviceMonitor |
| C-02 | **Audio Capture Layer** | `AudioEngine/Capture/` | AVAudioEngine + Core Audio | Hvatanje PCM-a, praćenje promjena uređaja |
| C-03 | **Format Converter** | `AudioEngine/Capture/` | Core Audio Converter | Resampling, channel conversion |
| C-04 | **Noise Engine** | `NoiseEngine/RNNoise/` | RNNoise + Obj-C++ wrapper | Denoising (Light/Balanced/Max) |
| C-05 | **Processing Pipeline** | `AudioEngine/Processing/` | C++ / Swift | VAD, suppression strength, gain, limiter |
| C-06 | **Ring Buffers** | `AudioEngine/RingBuffer/` | Lock-free queue (C++) | Komunikacija callback ↔ worker |
| C-07 | **Virtual Audio Device** | `VirtualDriver/CleanMicDriver/` | Audio Server Plugin (HAL) | Registruje "CleanMic" kao input |
| C-08 | **Device Monitor** | `App/DeviceMonitor/` | Core Audio notifications | Unplug/reconnect, sample rate change, sleep/wake |
| C-09 | **Diagnostics** | `AudioEngine/Metrics/` | Swift/C++ | CPU, underrun/overrun, latency — bez snimanja govora |

---

## 3. Detalj komponenti

### 3.1 CleanMic.app (C-01)

- **UI:** Menu-bar extra (NSMenuBarExtra / MenuBarExtra SwiftUI), Settings window
- **State:** `@AppStorage` / UserDefaults za izabrani mic, mod, ON/OFF
- **Lifecycle:** `AppDelegate` za permission flow, `DeviceMonitor` observer
- **Bez servera u MVP-u** — sav state lokalno

### 3.2 Audio Capture Layer (C-02)

- Koristi `AVAudioEngine` za brzi spike, ali dizajnirati da može preći na čisti `Core Audio HAL` ako AVAudioEngine ne daje dovoljnu kontrolu nad callbackovima.
- Input node tap: `installTap(onBus:bufferSize:format:block:)`
- Alternativa: `AudioUnit` kAudioUnitType_Output / HAL IOProc
- **Device change:** `kAudioObjectPropertySelector` + `AudioObjectAddPropertyListener`

### 3.3 Format Converter (C-03)

- Ulaz: proizvoljan format uređaja (44.1/48 kHz, mono/stereo)
- Izlaz: **48 kHz, Mono, Float32, non-interleaved** — format koji očekuje RNNoise
- Koristi `AVAudioConverter` ili `AudioConverterRef`
- Prealocirani bufferi; nema alokacije u real-time putanji

### 3.4 Noise Engine (C-04)

- **RNNoise** — recurrent neural network, lagan, real-time na CPU
- Wrapper: `NoiseProcessor.mm` (Objective-C++) — most između Swift-a i C API-a `rnnoise_create / rnnoise_process_frame`
- Frame: 10 ms @ 48 kHz = 480 samples (RNNoise default) — provjeriti
- Modovi mapiraju na različite `denoise strength` ili post-gain:
  - Light: `0.3`
  - Balanced: `0.6`
  - Maximum: `0.9` + agresivniji VAD threshold
- **Budućnost:** DeepFilterNet / Core ML kao zamjena za Maximum (v2.0)

### 3.5 Processing Pipeline (C-05)

```
Input PCM (48k/mono)
  → RNNoise process_frame (10ms chunks)
  → VAD (voice activity detection — iz RNNoise)
  → Suppression strength (per mode)
  → Optional: AGC (auto gain) + Limiter (spreči clipping)
  → Output PCM
```

- Worker thread: `DispatchQueue` ili `pthread` sa real-time prioritetom (`THREAD_TIME_CONSTRAINT_POLICY`)
- Nema Swift ARC u hot path-u ako je moguće — koristi `UnsafeMutablePointer<Float>`

### 3.6 Ring Buffers (C-06)

- **Lock-free SPSC** (single producer, single consumer) — npr. `TPCircularBuffer` ili custom na bazi `std::atomic`
- Dva buffera:
  - `InputRing` : callback → worker
  - `OutputRing` : worker → virtual driver
- Veličina: dovoljno za 100–200 ms (npr. 8192–16384 samples) da apsorbuje jitter
- Prealocirani na startu; `reset()` na device change

### 3.7 Virtual Audio Device (C-07)

- **Audio Server Driver Plug-in** — `.driver` bundle u `/Library/Audio/Plug-Ins/HAL/`
- Implementira `AudioServerPlugInDriverInterface`
- Ključne operacije:
  - `CreateDevice` — kreira CleanMic input device
  - `DoIOOperation` — isporučuje obrađeni PCM klijentima (čita iz OutputRing)
  - Shared memory / Mach port / XPC za komunikaciju app ↔ driver
- **Najkompleksniji dio** — zahtijeva spike u Fazi 2 prije bilo kakvog UI poliranja

### 3.8 Device Monitor (C-08)

- Sluša:
  - `kAudioHardwarePropertyDevices`
  - `kAudioDevicePropertyDeviceIsAlive`
  - `kAudioDevicePropertyNominalSampleRate`
  - `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`
- Na događaju: pauzira pipeline → re-enumerate → reconfigure → resume

### 3.9 Diagnostics (C-09)

- **Šta se mjeri (bez audio sadržaja):**
  - CPU % (worker thread)
  - Buffer underrun/overrun count
  - Frame processing time (µs)
  - End-to-end latency (ms)
  - Device change count, wake count
- **Gdje:** In-memory + opcioni log file (rotating, bez PCM-a)
- **Zašto:** Soak test i field debugging

---

## 4. Tehnološki stack (preporučeni)

| Sloj | Tehnologija | Razlog |
|------|-------------|--------|
| UI | Swift + SwiftUI | Native menu-bar, brz razvoj |
| Audio capture | AVAudioEngine + Core Audio | Low-level kontrola + fallback |
| Noise suppression | RNNoise | Dokazan, lagan, real-time |
| Native bridge | Objective-C++ / C++ | Swift ↔ C interop |
| Virtual input | Audio Server Driver Plug-in | Jedini način za sistemski mic |
| State/settings | UserDefaults + lightweight file | Bez servera |
| Packaging | Xcode + Developer ID + notarization | Distribucija |
| Future AI | DeepFilterNet / Core ML | Za Maximum v2.0 |

---

## 5. Dijagram komponenti (logički)

```
┌─────────────────────────────────────────────────┐
│                CleanMic.app                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  UI      │  │ Settings │  │ DeviceMonitor│  │
│  │ MenuBar  │◄─┤  Store   │◄─┤  Listener    │  │
│  └────┬─────┘  └──────────┘  └──────┬───────┘  │
│       │                             │          │
│  ┌────▼─────────────────────────────▼──────┐   │
│  │         AudioEngine (Capture)           │   │
│  └────┬──────────────────────┬─────────────┘   │
└───────┼──────────────────────┼─────────────────┘
        │                      │
   InputRing              OutputRing
        │                      │
┌───────▼──────┐        ┌──────▼───────┐
│  Processing  │        │ VirtualDriver│
│  Worker      │───────►│ CleanMic HAL │
│  RNNoise     │        │              │
└──────────────┘        └──────┬───────┘
                               │
                        ┌──────▼───────┐
                        │  Client Apps │
                        └──────────────┘
```

---

## 6. Komunikacija App ↔ Driver

Opcije (odabrati u spike-u Faza 2):

| Mehanizam | Pros | Cons |
|-----------|------|------|
| **Shared memory (mmap)** | Najbrže, low-latency | Kompleksnije, sync |
| **Mach port / MIG** | Apple native, brzo | Više boilerplate-a |
| **XPC** | Sigurnije, modernije | Veći overhead |
| **TPCircularBuffer + shared mem** | Dokazano u audio svijetu | Custom |

**Preporuka:** Početi sa shared memory + lock-free buffer (kao BlackHole / Soundflower pristup), evaluirati XPC ako je dovoljno brzo.

---

## 7. Predložena struktura repozitorija (detaljno)

```
CleanMic/
├── App/
│   ├── UI/
│   │   ├── MenuBarView.swift
│   │   ├── ContentView.swift
│   │   └── LevelMeterView.swift
│   ├── Settings/
│   │   ├── SettingsView.swift
│   │   └── SettingsStore.swift
│   └── DeviceMonitor/
│       ├── DeviceMonitor.swift
│       └── DeviceListener.swift
├── AudioEngine/
│   ├── Capture/
│   │   ├── AudioCapture.swift
│   │   └── FormatConverter.swift
│   ├── RingBuffer/
│   │   ├── RingBuffer.hpp
│   │   └── RingBuffer.cpp
│   ├── Processing/
│   │   ├── ProcessingWorker.swift
│   │   └── AudioProcessor.swift
│   └── Metrics/
│       ├── Metrics.swift
│       └── Telemetry.swift
├── NoiseEngine/
│   ├── RNNoise/
│   │   ├── rnnoise/ (submodule)
│   │   └── NoiseProcessor.h/mm
│   └── DenoiserProtocol.swift
├── VirtualDriver/
│   └── CleanMicDriver/
│       ├── CleanMicDriver.cpp
│       ├── CleanMicDevice.cpp
│       ├── Info.plist
│       └── CleanMicDriver.driver/
├── Installer/
│   ├── scripts/
│   ├── entitlements.plist
│   └── Notarization.md
├── Tests/
│   ├── AudioEngineTests/
│   ├── NoiseEngineTests/
│   └── IntegrationTests/
└── Docs/
```

---

## 8. Odluke koje treba donijeti u Fazi 0 (Spike)

| # | Odluka | Kriterijum |
|---|--------|------------|
| D-01 | AVAudioEngine vs direktni HAL IOProc | Ko daje stabilniji callback na device change? |
| D-02 | Veličina ring buffera | Mjerenje underrun-a pri 20/30/50 ms |
| D-03 | RNNoise frame handling | Offline test: kvalitet vs latencija |
| D-04 | App↔Driver IPC | Latencija <5ms dodatno, stabilnost 2h |
| D-05 | Minimalna macOS verzija | API dostupnost (MenuBarExtra vs NSStatusItem) |

---

**Sledeći dokument:** `PRD-03-Audio-Engine.md` — detalji pipeline-a i real-time sigurnosti
