# PRD-06 — Nefunkcionalni Zahtjevi, Test Plan i Rizici

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |

---

## 1. Nefunkcionalni zahtjevi (NFR)

### 1.1 Latencija

| Metrika | Cilj | Maksimalno prihvatljivo | Kako mjeriti |
|---------|------|-------------------------|--------------|
| Dodatna end-to-end latencija | ≤ 20 ms | ≤ 30 ms | Loopback impuls test |
| RNNoise processing po frameu | ≤ 5 ms | ≤ 8 ms | `mach_absolute_time` |
| Device switch recovery | < 1 s | < 2 s | Stopwatch + log |
| Mode switch | < 100 ms | < 200 ms | Bez klika u audio-u |

**Metod mjerenja latencije:**
- Generiši kratak impuls (click) na fizičkom inputu (npr. preko kabla)
- Snimi vrijeme ulaska u InputRing i izlaska iz OutputRing-a
- Razlika = pipeline latencija
- Alternativa: `AVAudioEngine` manual rendering + timestamp

### 1.2 Stabilnost

| Metrika | Cilj |
|---------|------|
| Bez čujnih dropova / 2h | 0 dropova |
| Bez pucketanja / progresivnog drifta | 0 |
| Bez crasha / 4h soak | 0 |
| Buffer underrun / 2h | 0 (tolerancija: ≤1 sa tišinom, ne drop) |
| Memory leak / 4h | 0 (footprint rast <1 MB) |

### 1.3 CPU i memorija

| Metrika | Cilj (Balanced, M1) | Mjerenje |
|---------|---------------------|----------|
| CPU (Balanced) | < 5% single core | Activity Monitor / `powermetrics` |
| CPU (Maximum) | < 10% single core | Isto |
| CPU idle (app u pozadini, mic OFF) | < 1% | Isto |
| Memorija (RSS) | < 100 MB | `footprint` |
| Battery drain / 1h poziva | < 5% dodatno vs bez CleanMic | `pmset -g batt` + test |

- Prealocirani bufferi; nema rasta memorije tokom rada
- Testirati na **M1, M2, M3** i **Intel** (ako podržano)

### 1.4 Privatnost

| Zahtjev | Detalj |
|---------|--------|
| Audio ostaje lokalno | Nema network requesta sa PCM sadržajem |
| Nema snimanja po defaultu | Snimanje samo ako korisnik eksplicitno uključi (debug) |
| Telemetry bez sadržaja | Samo metrike (CPU, underrun, device change), ne audio |
| Privacy policy | Jasno navodi local-only, link u Settings → About |

### 1.5 Kompatibilnost

| Kategorija | Prioritet | Test uređaji |
|------------|-----------|--------------|
| macOS verzije | P0: 14 Sonoma, 13 Ventura | P1: 15 Sequoia |
| Apple Silicon | P0: M1/M2/M3 | P1: M4 |
| Intel | P2: samo ako tržište traži | Test na jednom Intel Macu |
| Mikrofoni | P0: MacBook built-in, AirPods Pro, USB-C mic | P1: USB dock, AirPods Max |
| Klijentske app | P0: Zoom, Meet (Chrome), Teams, Discord | P1: Slack, FaceTime, OBS |

### 1.6 Recovery

| Scenario | Očekivano |
|----------|-----------|
| Sleep/wake | Auto recovery <2s, bez ručne intervencije |
| Bluetooth disconnect/reconnect | Auto fallback na sljedeći mic |
| Promjena sample ratea | Auto reconfigure convertera |
| `coreaudiod` restart | Driver se ponovo učita, app se re-kači |
| Processing greška | Fail-safe bypass (neobrađeni signal) + indikator |

---

## 2. Test plan

### 2.1 Audio kvalitet

| # | Scenarij | Očekivano |
|---|----------|-----------|
| AQ-01 | Ventilator / klima (konstantna buka) | Smanjenje >12 dB, glas prirodan |
| AQ-02 | Tipkanje tastature | Perkusivni transienti potisnuti, bez gutanja govora |
| AQ-03 | Saobraćaj kroz prozor | Niskofrekventna buka smanjena |
| AQ-04 | Govor drugih u pozadini | Blago potisnut (RNNoise nije speaker separation) — dokumentovati |
| AQ-05 | Kafić / open-space mix | Balanced jasno bolji od OFF |
| AQ-06 | Tiha soba (nema buke) | Nema degradacije glasa vs OFF (AB test) |

**Metod:**
- Snimi WAV prije/poslije, poslušaj AB, izmjeri SNR
- Subjektivni MOS test sa 5+ slušalaca (1–5 ocjena)
- PESQ / STOI ako ima referentni čist signal

### 2.2 Kompatibilnost (uređaji)

| # | Uređaj | Test |
|---|--------|------|
| C-01 | MacBook built-in | Default test |
| C-02 | AirPods Pro (Bluetooth) | Pair → koristi → disconnect → reconnect |
| C-03 | USB mikrofon (npr. Blue Yeti) | Plug → auto detect → poziv |
| C-04 | USB-C dock sa audio | Dock in/out tokom poziva |
| C-05 | AirPods Max | Isto kao C-02 |

### 2.3 Kompatibilnost (aplikacije)

| # | App | Test |
|---|-----|------|
| A-01 | Zoom | Settings → Audio → Input = CleanMic → poziv |
| A-02 | Google Meet (Chrome + Safari) | Meet → Settings → Microphone = CleanMic |
| A-03 | Microsoft Teams | Devices → Microphone = CleanMic |
| A-04 | Discord | Voice → Input = CleanMic |
| A-05 | Slack Huddle | Isto |
| A-06 | QuickTime / OBS | Snimanje sa CleanMic |

- Za svaki: 5 min poziv, provjera da nema dropova, da level metar radi

### 2.4 Stabilnost (soak / lifecycle)

| # | Test | Trajanje | Prolaz |
|---|------|----------|--------|
| S-01 | Kontinuirani poziv | 2h | 0 dropova, CPU stabilan |
| S-02 | Kontinuirani poziv | 4h | Isto, memory ne raste |
| S-03 | Sleep/wake ciklus | 10x | Auto recovery svaki put |
| S-04 | Promjena inputa tokom poziva | 20x | Svaki put <2s, bez crasha |
| S-05 | Bluetooth disconnect/reconnect | 20x | Auto fallback |
| S-06 | Promjena sample ratea (Audio MIDI Setup) | 5x | Reconfigure bez dropa |
| S-07 | `sudo killall coreaudiod` tokom rada | 5x | Driver + app se oporave |

### 2.5 Performanse

| # | Metrika | Alat |
|---|---------|------|
| P-01 | CPU usage | Instruments → Time Profiler, Activity Monitor |
| P-02 | Memory growth | Instruments → Allocations, `leaks` |
| P-03 | Buffer underrun/overrun | In-app counter (Metrics) |
| P-04 | Frame processing time | `mach_absolute_time` log |
| P-05 | End-to-end latency | Loopback impuls test |
| P-06 | Battery | `powermetrics --samplers smc` |

### 2.6 Instalacija i distribucija

| # | Test | Očekivano |
|---|------|-----------|
| I-01 | Clean install na novom Macu | CleanMic vidljiv nakon <2 min |
| I-02 | Update sa stare verzije | Stari driver zamijenjen, bez restarta Maca |
| I-03 | Uninstall | CleanMic nestaje, nema ostataka |
| I-04 | Gatekeeper / notarization | Nema "unidentified developer" upozorenja |
| I-05 | Bez admin lozinke | Jasna poruka zašto je potrebna |

---

## 3. Alati za testiranje

| Alat | Svrha |
|------|-------|
| `ffmpeg -f avfoundation` | Snimanje sa CleanMic za analizu |
| `SwitchAudioSource` (SoundSource) | CLI switch uređaja |
| `system_profiler SPAudioDataType` | Provjera da je driver učitan |
| `log stream --predicate 'subsystem == "com.cleanmic"'` | Logovi |
| Instruments (Time Profiler, Allocations) | Perf analiza |
| QuickTime Player | Brzi snimak/monitor |
| BlackHole (za poređenje) | Referentni virtual driver |

### Before/After test alat (custom)

- CLI ili SwiftUI alat koji:
  1. Snima 10s sa fizičkog mic-a (bypass)
  2. Snima 10s kroz pipeline (processed)
  3. Čuva oba WAV-a + prikazuje waveform / spectrogram
  4. Omogućava AB slušanje

---

## 4. Najveći tehnički rizici i mitigacije

| # | Rizik | Vjerovatnoća | Uticaj | Mitigacija |
|---|-------|--------------|--------|------------|
| R-01 | **Virtual driver HAL kompleksnost** | Visoka | Blokira proizvod | Fork NullAudio/BlackHole, spike u Fazi 2 prije UI, konsultovati Core Audio eksperta |
| R-02 | **Blocking u audio callbacku** | Visoka | Pucketanje/dropovi | Code review + static analiza, zabraniti alokacije/lockove u callbacku, test sa TSan |
| R-03 | **Latency vs quality tradeoff** | Srednja | Loš UX ako je >30ms | Mjerenje u Fazi 0, podesivi bufferi, Light mod za low-latency |
| R-04 | **Echo (speaker feedback)** | Visoka ako se koriste zvučnici | Korisnik čuje echo | Dokumentovati kao known limitation MVP-a, AEC u v1.5 sa far-end referencom |
| R-05 | **Device switching (BT/USB)** | Visoka | Crash ili tišina | DeviceMonitor + robustan recovery, test sa AirPods 20x |
| R-06 | **Distribucija (signing/notarization)** | Srednja | Korisnik ne može instalirati | Dizajnirati installer od početka, testirati na clean Macu, Developer ID |
| R-07 | **RNNoise kvalitet nedovoljan** | Srednja | Korisnik ne čuje razliku | Offline test prije Faze 1, fallback na DeepFilterNet za Maximum ako treba |
| R-08 | **Intel podrška** | Niska | Dodatni rad | Odložiti — Apple Silicon first |

---

## 5. Definition of Done za MVP (uslov za release)

> MVP je **Done** kada su **SVI** sljedeći uslovi ispunjeni:

- [ ] CleanMic se pojavljuje kao mikrofon u **Zoom, Meet, Teams, Discord** (min 4 appa)
- [ ] Noise suppression **vidljivo smanjuje** ventilator/klimu bez značajnog narušavanja glasa (AB test, 5+ slušalaca)
- [ ] **0 čujnih dropova** tokom **2h** kontinuiranog poziva (soak test)
- [ ] Promjena fizičkog mic-a **ne zahtijeva restart** appa (switch <2s)
- [ ] **Sleep/wake + Bluetooth reconnect** se automatski oporavljaju (10x test)
- [ ] **Balanced mode CPU** je prihvatljiv na M1/M2 (nema značajan battery drain)
- [ ] **Audio se ne šalje van uređaja** (provjera network logova + privacy policy)
- [ ] **Installer + signing + notarization** prolaze na clean Macu bez ručnih koraka osim standardnih dozvola
- [ ] **Uninstall** ostavlja sistem čist

---

## 6. Izvještavanje

- Svaki test ima **Test Report** (pass/fail + log + WAV ako je audio test)
- Soak testovi se snimaju sa `Metrics` logom (CPU, underrun)
- Bugovi se prijavljuju sa: koraci za reprodukciju, uređaj, macOS verzija, log

---

**Sledeći dokument:** `PRD-07-Roadmap.md`
