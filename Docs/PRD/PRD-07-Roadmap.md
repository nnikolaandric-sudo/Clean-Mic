# PRD-07 — Roadmap, Faze Razvoja i Sprint Plan

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |

---

## 1. Pregled faza

```
Faza 0 — Spike (1–2 sedmice)     → Dokazati da pipeline može raditi
Faza 1 — Audio Engine (2–3 sed)  → Stabilan real-time engine
Faza 2 — Virtual Driver (3–4 sed)→ CleanMic vidljiv sistemski
Faza 3 — MVP UI (1–2 sed)        → Menu-bar + onboarding
Faza 4 — Stabilizacija (2 sed)   → Edge case-evi, soak
Faza 5 — Distribucija (1 sed)    → Signing, installer, release
         ─────────────────────────────────
         Ukupno: ~10–14 sedmica do MVP
```

---

## 2. Detalj faza

### Faza 0 — Tehnički Spike (Cilj: de-risk najveće nepoznanice)

**Trajanje:** 1–2 sedmice  
**Tim:** 1 audio inženjer + 1 Swift dev

| # | Task | Done kada |
|---|------|-----------|
| 0.1 | Capture mikrofona preko AVAudioEngine — PCM dump | WAV snimljen, čuje se |
| 0.2 | Format normalizacija → 48k/mono/Float32 | Converter radi za 44.1k i 48k |
| 0.3 | RNNoise wrapper (C → Obj-C++ → Swift) | Offline WAV in/out radi |
| 0.4 | Offline test: ventilator WAV kroz RNNoise | Čuje se razlika, nema artefakata |
| 0.5 | Real-time test: mic → RNNoise → slušalice (bez drivera) | Radi sa <30ms, CPU izmjeren |
| 0.6 | Mjerenje processing vremena po frameu | <8ms na M1, dokumentovano |
| 0.7 | Odluke D-01..D-05 (AVAudioEngine vs HAL, buffer size) | ADR dokument |

**Exit kriterijum:** Možemo reći "RNNoise pipeline radi real-time na M1 sa X ms latencije i Y% CPU".

### Faza 1 — Audio Engine (Stabilan pipeline)

**Trajanje:** 2–3 sedmice

| # | Task | Done kada |
|---|------|-----------|
| 1.1 | Ring bufferi (lock-free SPSC, prealocirani) | Stress test 2h bez underruna |
| 1.2 | Dedicated processing thread (visok prioritet) | Worker ne blokira callback |
| 1.3 | Noise modes (Light/Balanced/Max) | Svaki mod ima različit strength |
| 1.4 | Level meters (input/processed) | Real-time bar u test UI |
| 1.5 | Device change handling (DeviceMonitor) | Switch mic-a bez restarta |
| 1.6 | Metrics (CPU, underrun, latency) | Log bez audio sadržaja |
| 1.7 | Before/after test alat | CLI koji snima oba WAV-a |

**Exit kriterijum:** 2h loopback test (mic → processed → file) bez dropova.

### Faza 2 — Virtualni Mikrofon (Najkompleksniji)

**Trajanje:** 3–4 sedmice  
**Rizik:** Najveći — može produžiti fazu

| # | Task | Done kada |
|---|------|-----------|
| 2.1 | Fork Apple NullAudio → minimalni CleanMic.driver | Driver vidljiv u `system_profiler` |
| 2.2 | Driver isporučuje tišinu / test ton | `ffmpeg -i :CleanMic` snima ton |
| 2.3 | Shared memory / IPC app ↔ driver | App piše, driver čita isti buffer |
| 2.4 | Povezati OutputRing → driver → klijent | Zoom vidi CleanMic i čuje processed |
| 2.5 | Test u Zoom/Meet/Teams/Discord | 4 appa rade |
| 2.6 | Install/uninstall flow (PKG + killall coreaudiod) | Clean install/uninstall na test Macu |
| 2.7 | Multi-client (više appova istovremeno) | Svi dobijaju isti PCM |

**Exit kriterijum:** CleanMic radi kao mic u 4 appa, 30 min poziv bez dropa.

### Faza 3 — MVP UI (Menu-bar + Onboarding)

**Trajanje:** 1–2 sedmice

| # | Task | Done kada |
|---|------|-----------|
| 3.1 | SwiftUI menu-bar app (MenuBarExtra) | Ikona + dropdown rade |
| 3.2 | Settings window (General/Audio/About) | Svi tabovi rade |
| 3.3 | Input selector (dropdown fizičkih mic-ova) | Auto-refresh na plug/unplug |
| 3.4 | ON/OFF + mode switch (live) | Bez prekida poziva |
| 3.5 | Level meters u menu baru | Real-time |
| 3.6 | Permission onboarding flow (4 koraka) | Testiran na clean Macu |
| 3.7 | Privacy indikator + copy | "Local only" vidljiv |

**Exit kriterijum:** Novi korisnik može instalirati i koristiti CleanMic bez uputa za <2 min.

### Faza 4 — Stabilizacija (Edge case-evi)

**Trajanje:** 2 sedmice

| # | Task | Done kada |
|---|------|-----------|
| 4.1 | Sleep/wake handling | 10x test, auto recovery |
| 4.2 | Bluetooth (AirPods) — disconnect/reconnect | 20x test |
| 4.3 | USB mikrofoni + dock | Plug/unplug tokom poziva |
| 4.4 | Long-running soak (2–4h) | 0 dropova, memory flat |
| 4.5 | Crash/underrun diagnostics | Log + indikator u UI |
| 4.6 | Fail-safe bypass | Ako worker padne → neobrađeni signal |
| 4.7 | Bugfixing iz Faza 0–3 | Svi P0 bugovi zatvoreni |

**Exit kriterijum:** Svi testovi iz PRD-06 prolaze.

### Faza 5 — Distribucija (Release)

**Trajanje:** 1 sedmica

| # | Task | Done kada |
|---|------|-----------|
| 5.1 | Code signing (Developer ID) | App + driver potpisani |
| 5.2 | Notarization | `notarytool` pass |
| 5.3 | Installer (PKG/DMG) + update strategija | Test na 2 clean Maca |
| 5.4 | Privacy policy + basic analytics (bez audio) | Dokument + implementacija |
| 5.5 | Beta sa 5–10 korisnika | Feedback prikupljen |
| 5.6 | Release build + docs | README, PRD final |

**Exit kriterijum:** Definition of Done (PRD-06 §5) ispunjen.

---

## 3. Gantt (pojednostavljeno)

```
Sedmica: 1  2  3  4  5  6  7  8  9  10 11 12 13 14
Faza 0   ████
Faza 1       ██████
Faza 2             ████████
Faza 3                     ████
Faza 4                         ████
Faza 5                             ██
```

---

## 4. Prvi razvojni sprint (detalj — naredne 2 sedmice)

> **Cilj sprinta:** Dokazati stabilan audio engine (Faza 0 + početak Faze 1).

| Dan | Task |
|-----|------|
| 1 | Kreirati SwiftUI menu-bar projekt, listanje input uređaja |
| 2 | AVAudioEngine capture → PCM dump → WAV file |
| 3 | Format converter (48k/mono/Float32), test sa 44.1k i 48k |
| 4 | RNNoise submodule + C wrapper, offline test (WAV in → WAV out) |
| 5 | Ring buffer (lock-free), unit test |
| 6 | Processing worker + RNNoise real-time (mic → processed → file) |
| 7 | Before/after alat + mjerenje latencije/CPU |
| 8 | DeviceMonitor — detekcija promjene uređaja |
| 9 | Test sa AirPods + USB mic |
| 10 | Review, odluke D-01..D-05, plan za Fazu 2 |

**Demo na kraju sprinta:** "Pričam u MacBook mic u bučnoj sobi, snimak prije/poslije pokazuje potiskivanje ventilatora, CPU X%, latencija Y ms."

---

## 5. Roadmap nakon MVP-a

| Verzija | Fokus | Funkcionalnosti |
|---------|-------|-----------------|
| **v1.1** | Quality | Bolji strength control, auto mode, presets (Office/Café/Home) |
| **v1.2** | Voice processing | VAD, AGC, limiter — finije podešavanje glasa |
| **v1.5** | Echo cancellation | AEC uz far-end referencu (za zvučnike) |
| **v2.0** | Maximum AI | DeepFilterNet / Core ML — veći kvalitet na Apple Silicon |
| **v2.x** | Personal voice | Model koji daje prioritet glasu vlasnika, odbacuje druge govornike |
| **Business** | Enterprise | Teams deployment, MDM, licensing, compliance paket |

---

## 6. Tim i uloge (pretpostavka za MVP)

| Uloga | Odgovornost | Faze |
|-------|-------------|------|
| **Audio/C++ inženjer** | Core Audio, RNNoise, driver, ring bufferi | 0,1,2,4 |
| **Swift/SwiftUI dev** | App, UI, DeviceMonitor, installer | 0,3,4,5 |
| **QA** | Test plan, soak, device matrix | 4,5 |
| **Product/Design** | PRD, UX, copy, beta | Sve |

- Za MVP dovoljan **1 senior audio dev + 1 Swift dev** (ili 1 full-stack sa audio iskustvom)
- Driver može zahtijevati eksternog konsultanta za HAL

---

## 7. Milestones i odluke

| Milestone | Datum (relativno) | Odluka |
|-----------|-------------------|--------|
| M-01 Spike done | Kraj sedmice 2 | Da li je RNNoise dovoljan ili treba DeepFilterNet? |
| M-02 Engine done | Kraj sedmice 5 | Da li je latencija <30ms? Da li je CPU OK? |
| M-03 Driver done | Kraj sedmice 9 | Da li driver radi u 4 appa? |
| M-04 UI done | Kraj sedmice 11 | Da li novi korisnik može bez pomoći? |
| M-05 Stabilizacija | Kraj sedmice 13 | Da li prolazi Definition of Done? |
| M-06 Release | Sedmica 14 | Go / No-go za public beta |

---

## 8. Kako pratiti progres

- Svaka faza ima **Exit kriterijum** — ne prelazi se dalje dok nije ispunjen
- Nedeljni demo: snimak prije/poslije + metrike
- Bloker = bilo koji P0 bug ili neispunjen NFR

---

**Sledeći dokument:** `BACKLOG.md` — detaljan task breakdown
