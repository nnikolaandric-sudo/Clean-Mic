# PRD-00 — CleanMic Overview: Vizija i Ciljevi Proizvoda

| Polje | Vrijednost |
|-------|------------|
| **Proizvod** | CleanMic |
| **Platforma** | macOS (Apple Silicon primarno, Intel opciono) |
| **Verzija dokumenta** | v1.0 |
| **Datum** | 27.08.2026 |
| **Status** | Draft → Review |
| **Autor** | CleanMic Team (na osnovu CleanMic_Plan_Aplikacije.docx) |
| **Tip** | Standalone, lokalna, low-latency aplikacija sa virtualnim mikrofonom |

---

## 1. Sažetak proizvoda (Executive Summary)

**CleanMic** je macOS aplikacija za **real-time uklanjanje pozadinske buke** iz mikrofonskog signala.

- Korisnik u bilo kojoj komunikacijskoj aplikaciji bira **"CleanMic"** kao mikrofon i dobija očišćeni govor bez dodatne konfiguracije.
- Primarni tehnički izazov **NIJE** AI model — već **pouzdana Core Audio integracija**: virtualni audio uređaj, bufferi, lifecycle promjena fizičkih uređaja.
- MVP je **potpuno lokalni proizvod**: jednostavan za instalaciju, minimalna latencija, stabilan audio pipeline.
- Preporučeni stack: **Swift/SwiftUI + AVAudioEngine/Core Audio + RNNoise (C/C++ wrapper) + Audio Server Driver Plug-in**.

> **Ključna rečenica:** CleanMic preuzima zvuk sa fizičkog mikrofona, obrađuje ga lokalno i isporučuje očišćeni signal u virtualni input `CleanMic` vidljiv u Zoom/Meet/Teams/Discord/Browser.

---

## 2. Problem

- Remote rad iz **kafića, open-space kancelarija, kuće** — sagovornici čuju ventilator, klimu, tipkanje, saobraćaj, tuđe razgovore.
- Ugrađeni MacBook mikrofon bez headseta daje loš SNR.
- Postojeća rješenja su često cloud-based (latencija, privatnost), skupa, ili zahtijevaju kompleksnu konfiguraciju.
- Korisnici žele **"jedan klik"** rješenje koje radi svuda.

## 3. Ciljna grupa

| Segment | Opis |
|---------|------|
| **Remote profesionalci** | 25-45 god, daily Zoom/Meet/Teams, rade iz kuće/kafića |
| **Freelanceri / konsultanti** | Česti pozivi sa klijentima, bez profesionalnog studija |
| **Podcasteri / streameri (light)** | Trebaju osnovno čišćenje bez hardverskog gate-a |
| **Enterprise (kasnije)** | Timovi kojima treba konzistentan kvalitet poziva |

**Primarno:** Individualni macOS korisnik na Apple Silicon.

## 4. Vizija i principi

| Princip | Opis |
|---------|------|
| **Jedan klik** | Noise cancellation ON/OFF bez tehničkog podešavanja |
| **Radi svuda** | Pojavljuje se kao standardni mikrofon u svim appovima |
| **Low latency** | Dodatna latencija ≤ 20–30 ms, neprimjetna u razgovoru |
| **Local-first** | Bez slanja govora na server; privatnost kao feature |
| **Niska potrošnja** | Višesatni sastanci bez grijanja / battery draina |
| **Jednostavan UI** | Menu-bar, 2 klika do svega |

## 5. Ciljevi proizvoda (Product Goals)

### 5.1 Business ciljevi (MVP)

- Validirati da korisnici **percipiraju razliku** (ventilator/klima test) bez narušavanja govora.
- Postići **stabilan audio pipeline** 2+ sata bez dropova — preduvjet za bilo koji growth.
- Omogućiti **distribuciju bez ručnih koraka** osim standardnih macOS dozvola (signing + notarization).
- Dokazati da je **Core Audio HAL driver** izvodljiv kao održiv proizvod, ne samo demo.

### 5.2 Korisnički ciljevi (User Goals)

- Uključiti CleanMic za **<10 sekundi** od instalacije.
- Zaboraviti da CleanMic postoji — radi u pozadini, ne prekida poziv ni pri promjeni uređaja.
- Imati **povjerenje u privatnost**: indikator "Local only".

### 5.3 Tehnički ciljevi

- End-to-end dodatna latencija: **≤ 20–30 ms** (cilj, mjeriti precizno).
- CPU u Balanced modu: **niska i predvidiva** potrošnja na M1/M2/M3.
- Nula memory leak-a; prealocirani bufferi; bez alokacija u audio callbacku.
- Recovery nakon sleep/wake, Bluetooth reconnect, promjena sample ratea.

## 6. Non-Goals (Šta MVP NIJE)

- Nije mobilna aplikacija.
- Nije Windows aplikacija.
- Nije cloud AI / transkripcija / sažeci sastanaka.
- Nije studio editor / DAW.
- Nije echo cancellation za speakerphone (poseban problem, v1.5).
- Nije vlastiti trenirani model u MVP-u (koristi RNNoise).

## 7. Mjerila uspjeha (Success Metrics)

| Metrika | MVP cilj | Kako mjeriti |
|---------|----------|--------------|
| **Perceived noise reduction** | >70% korisnika čuje razliku na ventilator testu | A/B listening test |
| **Stabilnost** | 0 čujnih dropova / 2h | Soak test + underrun counter |
| **Latencija** | ≤ 30 ms dodatno | Loopback mjerenje |
| **CPU Balanced** | Predvidiva, niska (npr. <5-8% na M1) | Activity Monitor / Instruments |
| **Install success** | >90% bez supporta | Installer telemetry (bez audio sadržaja) |
| **Retention** | Korisnik ostavlja CleanMic kao default mic | Settings telemetry |

## 8. Pretpostavke i ograničenja

- **Pretpostavka:** RNNoise je dovoljan za MVP kvalitet (kontinuirana buka).
- **Pretpostavka:** Korisnik ima macOS 13+ na Apple Silicon (Ventura+).
- **Ograničenje:** Driver zahtijeva korisničku dozvolu + eventualno restart Core Audio servisa.
- **Ograničenje:** Echo cancellation nije u scope-u MVP-a — dokumentovati kao known limitation.

## 9. Rizici (visoki nivo)

1. **Virtualni driver** — najkompleksniji dio; zahtijeva HAL ekspertizu.
2. **Real-time sigurnost** — blocking u callbacku = pucketanje.
3. **Distribucija** — signing/notarization/installer mora biti dizajniran od početka.
4. **Device switching** — Bluetooth/USB mijenjaju format u hodu.

Detaljno u `PRD-06-NFR-Test-Plan.md`.

## 10. Veze ka ostalim PRD dokumentima

- `PRD-01-MVP-Scope.md` — Šta ulazi / ne ulazi u MVP, use case-ovi, funkcionalni zahtjevi
- `PRD-02-Architecture.md` — Arhitektura i komponente
- `PRD-03-Audio-Engine.md` — Audio pipeline detaljno
- `PRD-04-Virtual-Driver.md` — Virtualni mikrofon spec
- `PRD-05-UX-UI.md` — UX i ekrani
- `PRD-06-NFR-Test-Plan.md` — NFR, test plan, rizici
- `PRD-07-Roadmap.md` — Roadmap, faze, DoD

---

**Sledeći korak:** Review ovog dokumenta → zaključavanje scope-a u PRD-01.
