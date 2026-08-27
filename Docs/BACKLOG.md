# CleanMic — Backlog (Task Breakdown)

> Detaljan backlog izveden iz PRD-00..PRD-07 i plana `CleanMic_Plan_Aplikacije.docx`.  
> Svaki task ima ID, fazu, prioritet i acceptance criteria.

---

## Faza 0 — Spike (1–2 sedmice)

| ID | Task | Prioritet | AC |
|----|------|-----------|----|
| 0.1 | Kreirati SwiftUI menu-bar projekt (Xcode) | P0 | `CleanMic.xcodeproj` se builda, menu-bar ikona vidljiva |
| 0.2 | Listanje i izbor audio input uređaja | P0 | Dropdown prikazuje sve inpute, refresh na plug |
| 0.3 | AVAudioEngine capture → PCM dump | P0 | WAV snimljen, playback radi |
| 0.4 | Format converter → 48k/mono/Float32 | P0 | Test sa 44.1k i 48k, nema aliasinga |
| 0.5 | RNNoise submodule + C wrapper | P0 | `rnnoise_create/process/destroy` poziv radi |
| 0.6 | Objective-C++ bridge `NoiseProcessor.mm` | P0 | Swift poziva `processFrame` |
| 0.7 | Offline test: WAV → RNNoise → WAV | P0 | AB slušni test, ventilator smanjen |
| 0.8 | Real-time: mic → RNNoise → file (bez drivera) | P0 | 30s snimak, nema dropova |
| 0.9 | Mjerenje latencije i CPU | P0 | Dokumentovano: X ms, Y% |
| 0.10 | ADR: AVAudioEngine vs HAL, buffer size | P1 | Odluka dokumentovana u `Docs/Architecture/` |

---

## Faza 1 — Audio Engine (2–3 sedmice)

| ID | Task | Prioritet | AC |
|----|------|-----------|----|
| 1.1 | Lock-free RingBuffer (C++) | P0 | Unit test: SPSC 2h bez race (TSan) |
| 1.2 | InputRing + OutputRing integracija | P0 | Callback ↔ worker komunkacija radi |
| 1.3 | Processing worker (visok prioritet thread) | P0 | RNNoise van callbacka, nema blockinga |
| 1.4 | Modovi Light/Balanced/Maximum | P0 | Svaki mod različit strength, testirano |
| 1.5 | VAD + gain + limiter | P1 | Nema clippinga, glas konzistentan |
| 1.6 | Level meters (input/processed) | P0 | Real-time bar u test UI |
| 1.7 | DeviceMonitor (Core Audio listener) | P0 | Detektuje plug/unplug/rate change |
| 1.8 | Auto-reconnect na promjenu uređaja | P0 | Switch <2s, bez restarta |
| 1.9 | Metrics (CPU, underrun, latency) | P1 | Log bez audio sadržaja |
| 1.10 | Before/after CLI alat | P1 | Snima bypass + processed WAV |

---

## Faza 2 — Virtual Driver (3–4 sedmice) ⚠️ Najrizičnije

| ID | Task | Prioritet | AC |
|----|------|-----------|----|
| 2.1 | Fork NullAudio → CleanMic.driver skeleton | P0 | Builda se, `system_profiler` ga vidi |
| 2.2 | Driver isporučuje tišinu / sine 440Hz | P0 | `ffmpeg -i :CleanMic` snima ton |
| 2.3 | Shared memory IPC (mmap) | P0 | App piše, driver čita isti segment |
| 2.4 | OutputRing → shared mem → driver DoIO | P0 | Zoom čuje processed signal |
| 2.5 | Test: Zoom / Meet / Teams / Discord | P0 | 4 appa rade, 5 min poziv svaki |
| 2.6 | Multi-client podrška | P1 | 2 appa istovremeno čitaju isti mic |
| 2.7 | Format handling (samo 48k/mono za MVP) | P0 | Klijent dobija ispravan format |
| 2.8 | Install skripta (copy + killall coreaudiod) | P0 | Clean install na test Macu |
| 2.9 | Uninstall skripta | P0 | Nema tragova nakon uklanjanja |
| 2.10 | Driver signing (Developer ID) | P1 | Gatekeeper ne blokira |

---

## Faza 3 — MVP UI (1–2 sedmice)

| ID | Task | Prioritet | AC |
|----|------|-----------|----|
| 3.1 | Menu-bar dropdown (SwiftUI) | P0 | ON/OFF, input, mode, metri |
| 3.2 | Input dropdown (fizički mic-ovi) | P0 | Auto-refresh, switch bez restarta |
| 3.3 | Mode radio (Light/Balanced/Max) | P0 | Live switch, bez klika |
| 3.4 | Level meters u menu baru | P0 | Real-time, 60fps |
| 3.5 | Menu-bar ikona stanja (ON/OFF/error) | P1 | Različite ikone po stanju |
| 3.6 | Settings window (General/Audio/About) | P0 | Svi tabovi rade |
| 3.7 | Permission onboarding (4 koraka) | P0 | Test na clean Macu, <2 min |
| 3.8 | Privacy indikator "Local only" | P0 | Uvijek vidljiv + tooltip |
| 3.9 | Launch at login | P1 | Opciono, radi nakon reboota |
| 3.10 | Error stanja (no mic, no driver, no perm) | P1 | Jasne poruke + akcije |

---

## Faza 4 — Stabilizacija (2 sedmice)

| ID | Task | Prioritet | AC |
|----|------|-----------|----|
| 4.1 | Sleep/wake recovery | P0 | 10x test, svaki <2s |
| 4.2 | Bluetooth AirPods 20x disconnect/reconnect | P0 | Auto fallback svaki put |
| 4.3 | USB mic + dock handling | P1 | Plug/unplug tokom poziva |
| 4.4 | Soak test 2h (0 dropova) | P0 | Metrics log, CPU flat |
| 4.5 | Soak test 4h (memory leak) | P0 | Footprint rast <1 MB |
| 4.6 | Sample rate change (Audio MIDI Setup) | P1 | 5x, bez dropa |
| 4.7 | `killall coreaudiod` recovery | P1 | 5x, auto re-attach |
| 4.8 | Fail-safe bypass (worker crash) | P0 | Neobrađeni signal ili greška, ne crash |
| 4.9 | CPU/battery optimizacija | P1 | Balanced <5% na M1 |
| 4.10 | Bugfix P0 iz prethodnih faza | P0 | Svi P0 zatvoreni |

---

## Faza 5 — Distribucija (1 sedmica)

| ID | Task | Prioritet | AC |
|----|------|-----------|----|
| 5.1 | Code signing (app + driver) | P0 | Developer ID, entitlements |
| 5.2 | Notarization (`notarytool`) | P0 | Pass na Apple serveru |
| 5.3 | PKG/DMG installer | P0 | Test na 2 clean Maca |
| 5.4 | Update strategija | P1 | Dokumentovana |
| 5.5 | Privacy policy | P0 | Link u Settings → About |
| 5.6 | Basic analytics (bez audio, opt-in) | P2 | Samo metrike, nema PCM-a |
| 5.7 | Beta sa 5–10 korisnika | P0 | Feedback + bug list |
| 5.8 | README + Docs final | P1 | Svi PRD-ovi ažurirani |
| 5.9 | Release build | P0 | Tag `v1.0.0`, archive |
| 5.10 | Go/No-go odluka | P0 | Definition of Done ispunjen |

---

## Nakon MVP-a (Backlog za v1.1+)

| ID | Feature | Verzija |
|----|---------|---------|
| B-01 | Auto mode (bira mod prema buci) | v1.1 |
| B-02 | Presets: Office / Café / Home | v1.1 |
| B-03 | AGC + limiter finije | v1.2 |
| B-04 | Global hotkey (toggle) | v1.1 |
| B-05 | Per-app profili | v2.x |
| B-06 | Echo cancellation (AEC) | v1.5 |
| B-07 | DeepFilterNet / Core ML (Maximum AI) | v2.0 |
| B-08 | Personal voice model | v2.x |
| B-09 | Windows verzija | v2.x |
| B-10 | Enterprise / MDM | Business |

---

## Kako koristiti ovaj backlog

- Svaki task je **1–2 dana** rada (osim 2.3 i 2.4 — 3–5 dana)
- Prioritet P0 = mora za MVP, P1 = treba, P2 = može kasnije
- Task je done kada je AC ispunjen **i** testiran prema PRD-06
