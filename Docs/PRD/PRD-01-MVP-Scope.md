# PRD-01 — MVP Scope, Use Case-ovi i Funkcionalni Zahtjevi

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |
| Zavisnost | PRD-00-Overview.md |

---

## 1. MVP Scope — Šta ulazi / ne ulazi

### 1.1 Ulazi u MVP (Must Have)

| # | Funkcionalnost | Prioritet |
|---|----------------|-----------|
| F-01 | Izbor fizičkog mikrofona (lista dostupnih inputa) | P0 |
| F-02 | Noise cancellation ON/OFF bez prekida virtualnog uređaja | P0 |
| F-03 | 3 nivoa obrade: **Light / Balanced / Maximum** | P0 |
| F-04 | RNNoise real-time obrada (48 kHz / Mono / Float32) | P0 |
| F-05 | Virtualni mikrofon **"CleanMic"** vidljiv sistemski | P0 |
| F-06 | Menu-bar aplikacija (ne dock-only) | P0 |
| F-07 | Input / Processed level metri (vizuelno) | P0 |
| F-08 | Automatsko ponovno povezivanje nakon promjene uređaja | P0 |
| F-09 | Local processing + privacy indikator "Local only" | P0 |
| F-10 | Microphone permission onboarding | P0 |
| F-11 | Sleep/wake & Bluetooth reconnect handling | P1 |
| F-12 | Fail-safe: bypass neobrađenog signala ili jasan error | P1 |

### 1.2 Ne ulazi u MVP (Explicit Non-Scope)

| # | Funkcionalnost | Planirano za |
|---|----------------|--------------|
| N-01 | Vlastiti trenirani AI model | v2.0 |
| N-02 | Cloud processing | Nikad (osim opcioni hibrid) |
| N-03 | Mobilne verzije (iOS/Android) | v3.0+ |
| N-04 | Windows verzija | v2.x |
| N-05 | Meeting recorder / transkripcija / sažeci | v1.5+ |
| N-06 | Studio editor / DAW features | Out of scope |
| N-07 | Enterprise admin portal / MDM | Business tier |
| N-08 | Acoustic Echo Cancellation (AEC) | v1.5 |
| N-09 | Personal voice model | v2.x |

> **Pravilo:** Svaki zahtjev koji nije u 1.1 tabeli je automatski odbijen za MVP osim ako se ne prođe change-request proces.

---

## 2. Primarni Use Case-ovi

### UC-01 — Remote sastanak iz bučnog okruženja
- **Akter:** Remote radnik u kafiću / open-space / kući sa bukom
- **Precondition:** CleanMic instaliran, izabran fizički mic
- **Flow:**
  1. Korisnik otvara Zoom/Meet/Teams
  2. Bira `CleanMic` kao mikrofon
  3. Uključuje Balanced mode
  4. Sagovornici čuju primarno njegov glas, buka potisnuta
- **Success:** Sagovornik ocjenjuje poziv kao "čist" bez da korisnik mijenja ponašanje
- **Edge:** Ako obrada zakaže → fail-safe bypass, indikator upozorenja

### UC-02 — Laptop bez headseta
- **Akter:** Korisnik na MacBook ugrađenom mikrofonu + zvučnici
- **Flow:** Isto kao UC-01, ali bez eksternog hardvera
- **Success:** Ventilator/klima tipkanje značajno smanjeno
- **Known limitation:** Echo od zvučnika nije u MVP scope-u — dokumentovati

### UC-03 — Pozivi iz browsera
- **Akter:** Korisnik u Chrome/Safari (Google Meet web, Discord web, Whereby)
- **Flow:** Browser vidi CleanMic kao standardni input
- **Success:** Radi bez dodatne konfiguracije browsera

### UC-04 — Streaming / podcast (light)
- **Akter:** Kreator sadržaja sa osnovnom bukom (ventilator, klima)
- **Flow:** Bira CleanMic u OBS / QuickTime
- **Success:** Čišćenje ambijentalne buke bez gate hardvera

### UC-05 — Promjena uređaja u toku poziva
- **Akter:** Korisnik prebacuje sa MacBook mic na AirPods / USB mic
- **Flow:**
  1. Tokom poziva isključi AirPods
  2. Sistem mijenja default input
  3. CleanMic detektuje promjenu, re-konektuje se automatski
  4. Poziv se nastavlja bez restarta appa
- **Success:** <2 sec recovery, bez dropa virtualnog uređaja

---

## 3. Funkcionalni zahtjevi (detaljno)

### 3.1 Dozvole i onboarding (F-10)

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| FR-01 | App traži microphone permission na prvom startu | Sistemski dialog + objašnjenje zašto je potrebno |
| FR-02 | Ako je dozvola odbijena, prikazuje upute kako omogućiti | Link ka System Settings → Privacy → Microphone |
| FR-03 | Onboarding prikazuje izbor mikrofona + test metar | Korisnik vidi input level prije nego što uđe u poziv |
| FR-04 | Driver instalacija traži odobrenje | Jasna poruka šta se instalira i zašto |

### 3.2 Izbor uređaja (F-01, F-08)

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| FR-05 | Lista svih fizičkih input uređaja | AVAudioEngine / Core Audio enumeration, refresh na promjenu |
| FR-06 | Promjena inputa bez restarta appa | Switch <1s, bez prekida virtualnog uređaja |
| FR-07 | Pamti zadnji izbor | UserDefaults, restore nakon relaunch |
| FR-08 | Auto-reconnect nakon unplug/reconnect | Detekcija preko DeviceMonitor, auto fallback na default |
| FR-09 | Hendlovanje sleep/wake | Nakon wake, pipeline se automatski oporavlja |

### 3.3 Noise cancellation kontrole (F-02, F-03)

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| FR-10 | ON/OFF toggle | Odmah primjenjivo, bez restarta poziva |
| FR-11 | 3 moda: Light / Balanced / Maximum | Svaki mod ima definisan RNNoise threshold / gain |
| FR-12 | Mod se može mijenjati u toku poziva | Glatka tranzicija, bez klika |
| FR-13 | Default mod = Balanced | Objašnjeno u UI |

**Definisanje modova (inicijalni prijedlog):**
- **Light:** Blaga supresija, max očuvanje glasa, za tihu kancelariju
- **Balanced:** Preporučeni default, za kafić/open-space
- **Maximum:** Agresivno, za ventilator/saobraćaj (moguć blagi artifact na glasu)

### 3.4 Virtualni mikrofon (F-05)

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| FR-14 | Uređaj se zove `CleanMic` | Vidljiv u System Settings → Sound → Input |
| FR-15 | Vidljiv u Zoom/Meet/Teams/Discord/Browser | Testiran u 4+ appa |
| FR-16 | Ostaje vidljiv dok je driver instaliran | Ne nestaje nakon sleepa |
| FR-17 | Uninstall uklanja uređaj čisto | Bez ostataka u Core Audio |

### 3.5 Level metri i status (F-07, F-09)

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| FR-18 | Input level metar (pre obrade) | Real-time bar, 0–100% |
| FR-19 | Processed level metar (poslije obrade) | Real-time bar |
| FR-20 | Privacy indikator "Local only" | Uvijek vidljiv u UI |
| FR-21 | Status: ON/OFF, mod, izabrani mic | U menu-bar dropdown |

### 3.6 Greške i fail-safe (F-12)

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| FR-22 | Ako processing thread padne → bypass | Neobrađeni signal ide dalje ili se prikazuje greška |
| FR-23 | Ako je CPU preopterećen → degradacija | Log + indikator, ne crash |
| FR-24 | Buffer underrun/overrun se broji | Metrics, bez čujnog artefakta ako je moguće |
| FR-25 | Nema snimanja sadržaja po defaultu | Eksplicitno u privacy policy |

---

## 4. Korisničke priče (User Stories)

```
US-01: Kao remote radnik, želim jednim klikom uključiti čišćenje buke
       da sagovornici ne čuju kafić oko mene.
       AC: ON/OFF u menu baru, <2 klika.

US-02: Kao korisnik MacBook-a bez slušalica, želim da ventilator bude potisnut
       a da moj glas ostane prirodan.
       AC: Balanced mode smanjuje ventilator >12dB bez značajnog voice distortion-a.

US-03: Kao korisnik koji mijenja AirPods tokom poziva, želim da se CleanMic
       automatski prebaci bez prekida poziva.
       AC: Auto-reconnect <2s, bez ručne intervencije.

US-04: Kao korisnik koji brine o privatnosti, želim garanciju da se govor ne šalje na server.
       AC: "Local only" indikator + privacy policy + nema network requesta sa audio sadržajem.

US-05: Kao novi korisnik, želim da instalacija prođe bez terminala.
       AC: DMG/PKG installer, signing + notarization, samo standardne dozvole.
```

---

## 5. Zavisnosti

- PRD-03 (Audio Engine) — mora biti stabilan prije VirtualDriver-a
- PRD-04 (Virtual Driver) — blokira testiranje u Zoom/Teams
- PRD-05 (UX) — zavisi od FR-01..FR-21

## 6. Otvorena pitanja

| # | Pitanje | Vlasnik | Rok |
|---|---------|---------|-----|
| Q-01 | Da li podržati Intel Mac u MVP-u? | Product | Prije Faze 2 |
| Q-02 | Minimalna macOS verzija (13 vs 14)? | Eng | Spike Faza 0 |
| Q-03 | Da li Maximum mode treba biti RNNoise ili DeepFilterNet-lite? | Eng | Nakon mjerenja |

---

**Sledeći dokument:** `PRD-02-Architecture.md`
