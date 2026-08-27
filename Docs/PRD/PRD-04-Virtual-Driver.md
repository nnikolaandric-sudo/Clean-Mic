# PRD-04 — Virtual Audio Driver Specifikacija (CleanMic HAL Driver)

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |
| Kritičnost | **P0 — Najveći tehnički rizik proizvoda** |

---

## 1. Cilj

Kreirati **virtualni audio input uređaj** pod nazivom **"CleanMic"** koji se u macOS sistemu ponaša kao fizički mikrofon i isporučuje obrađeni (denoised) PCM klijentima (Zoom, Meet, Teams, Discord, browser).

**Uspjeh =** Korisnik vidi `CleanMic` u `System Settings → Sound → Input` i u svim appovima bez dodatne konfiguracije, i uređaj ostaje stabilan kroz sleep/wake i promjene fizičkog mikrofona.

---

## 2. Tehnologija — Audio Server Driver Plug-in

### 2.1 Šta je HAL Plug-in?

- macOS **Core Audio HAL** (Hardware Abstraction Layer) učitava plug-inove iz `/Library/Audio/Plug-Ins/HAL/` na boot / na `coreaudiod` restart
- Plug-in je bundle sa ekstenzijom `.driver` koji implementira `AudioServerPlugInDriverInterface`
- Nije kernel extension (kext) — radi u user space-u kao dio `coreaudiod` procesa

### 2.2 Zašto je ovo najteži dio?

- Dokumentacija je oskudna, primjeri su rijetki (Apple `NullAudio` sample, BlackHole, Soundflower)
- Lifecycle je vezan za `coreaudiod` — crash drivera ruši audio servis
- Komunikacija **app ↔ driver** mora biti IPC (driver živi u drugom procesu)
- Instalacija zahtijeva **admin privilegije** + restart audio servisa
- Signing i notarization moraju biti ispravni da bi driver bio učitan

---

## 3. Funkcionalni zahtjevi

| ID | Zahtjev | Kriterijum prihvatanja |
|----|---------|------------------------|
| VD-01 | Uređaj se zove `CleanMic` | Vidljiv kao `CleanMic` u svim appovima |
| VD-02 | Tip: Input only, 1 kanal (mono), 48 kHz, Float32 | `kAudioDevicePropertyStreamConfiguration` vraća 1 input stream |
| VD-03 | Vidljiv odmah nakon instalacije (nakon coreaudiod restarta) | Bez restarta Maca (samo `sudo killall coreaudiod` ili reboot) |
| VD-04 | Ostaje vidljiv dok je instaliran | Ne nestaje nakon sleep/wake |
| VD-05 | Uninstall ga potpuno uklanja | `rm -rf /Library/Audio/Plug-Ins/HAL/CleanMic.driver` + restart |
| VD-06 | Isporučuje obrađeni PCM iz OutputRing-a | Klijent čita denoised signal, ne tišinu |
| VD-07 | Ako nema podataka u OutputRing-u → isporuči tišinu, ne crash | Underrun handling |
| VD-08 | Podržava promjenu sample ratea ako klijent traži (44.1k vs 48k) | Resampling u driveru ili fiksno 48k sa konverzijom |

---

## 4. Arhitektura drivera

### 4.1 Komponente

```
CleanMic.driver (bundle)
├── Info.plist
├── CleanMicDriver.cpp/h    # AudioServerPlugInDriverInterface impl
├── CleanMicDevice.cpp/h    # Device + Stream + Controls
└── IPC.cpp/h               # Komunikacija sa appom
```

### 4.2 Ključni interfejsi koje treba implementirati

| Funkcija | Opis |
|----------|------|
| `Initialize` | Inicijalizacija plug-ina, kreiranje device-a |
| `CreateDevice` | Kreira CleanMic virtual device |
| `DestroyDevice` | Uklanja device |
| `AddDeviceClient` / `RemoveDeviceClient` | Klijent (Zoom) se kači/otkači |
| `DoIOOperation` | **Najvažnije** — klijent traži PCM, driver čita iz OutputRing-a |
| `GetPropertyData` / `SetPropertyData` | Upiti o formatu, kontroli |
| `GetZeroTimeStamp` | Timing |

### 4.3 Device model

- **1 Device:** `CleanMic`
  - **1 Input Stream:** mono, 48 kHz, Float32
  - **0 Output Streams** (samo input u MVP-u)
  - **Controls:** Volume (fiksno 1.0), Mute (opciono)

---

## 5. App ↔ Driver komunikacija (IPC)

### 5.1 Problem

- App živi u `CleanMic.app` procesu
- Driver živi u `coreaudiod` procesu
- Moraju dijeliti **OutputRing PCM buffer**

### 5.2 Opcije

| Mehanizam | Latencija | Kompleksnost | Sigurnost | Preporuka |
|-----------|-----------|--------------|-----------|-----------|
| **Shared memory (mmap + shm_open)** | ~0.1 ms | Srednja | Niža | ✅ Preporučeno za MVP |
| Mach port | ~0.2 ms | Visoka | Srednja | Alternativa |
| XPC | ~1-2 ms | Niža | Visoka | Ako shared mem prekompleksno |
| UNIX domain socket | ~1 ms | Niža | Srednja | Fallback |

### 5.3 Preporučeni pristup — Shared Memory

```
App proces                          coreaudiod proces
┌──────────────┐                   ┌──────────────┐
│ Processing   │                   │ CleanMic     │
│ Worker       │──► OutputRing ──► │ Driver       │
│ (piše PCM)   │   (mmap shared)   │ (čita PCM)  │
└──────────────┘                   └──────┬───────┘
                                          ↓ DoIOOperation
                                   ┌──────────────┐
                                   │ Zoom / Meet  │
                                   └──────────────┘
```

- Kreirati shared memory segment: `shm_open("/cleanmic_output", O_CREAT|O_RDWR, 0600)` + `mmap`
- Ring buffer header (head/tail atomics) + PCM data u shared mem
- **Sinhronizacija:** lock-free atomics, bez mutexa
- **Lifecycle:** App kreira segment na startu, driver se kači; ako app crasha, driver isporučuje tišinu

### 5.4 Prototip za validaciju (Faza 2 spike)

- **Minimalni driver:** NullAudio fork koji samo isporučuje tišinu ili test ton (sine 440Hz)
- **Zatim:** Povezati sa shared memory i čitati pravi PCM
- **Test:** `ffmpeg -f avfoundation -i ":CleanMic" -t 10 test.wav` — snimi 10s i provjeri

---

## 6. Instalacija i distribucija

### 6.1 Instalacija (MVP)

| Korak | Komanda / akcija | Privilegije |
|-------|------------------|-------------|
| 1 | Kopirati `CleanMic.driver` u `/Library/Audio/Plug-Ins/Half/` | `sudo` / admin |
| 2 | `sudo killall coreaudiod` ili reboot | admin |
| 3 | Provjera: `system_profiler SPAudioDataType` ili `SwitchAudioSource -a` | — |

- **Installer:** PKG sa `postinstall` skriptom koja radi `killall coreaudiod`
- **Alternativa:** DMG + helper tool sa `SMJobBless` za privilegovanu instalaciju

### 6.2 Signing i notarization

- Driver bundle mora biti potpisan sa **Developer ID**
- Entitlements: provjeriti da li HAL plug-in zahtijeva posebne (obično ne, ali `com.apple.security.cs.allow-unsigned-executable-memory` možda za JIT)
- Notarization: `xcrun notarytool submit CleanMic.pkg --wait`
- **Mora biti dio arhitekture od početka** — ne naknadno

### 6.3 Uninstall

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/CleanMic.driver
sudo killall coreaudiod
```
- Uninstaller skripta ili opcija u CleanMic.app → Settings → Uninstall Driver

### 6.4 Update strategija

- Sparkle ili custom updater za app
- Za driver: app detektuje novu verziju → traži admin dozvolu → zamijeni bundle → restart coreaudiod

---

## 7. Sigurnost i stabilnost

| Rizik | Mitigacija |
|-------|------------|
| Driver crash ruši `coreaudiod` | Minimalan kod u driveru; sav denoising u appu, driver samo čita PCM |
| Shared memory leak | `shm_unlink` na uninstall, `atexit` handler |
| Klijent traži drugi format (44.1k) | Driver prijavljuje samo 48k; ako klijent traži 44.1k, radi resampling ili vrati grešku |
| Više klijenata čita istovremeno | Driver mora podržati više `IOProc`-ova — čita isti PCM za sve |
| App nije pokrenut, a klijent traži mic | Driver isporučuje tišinu + app prikazuje warning "CleanMic app nije pokrenut" |

---

## 8. Test plan za driver

| # | Test | Očekivano |
|---|------|-----------|
| VD-T01 | Instalacija + `system_profiler` | CleanMic vidljiv |
| VD-T02 | Snimanje preko `ffmpeg` / QuickTime sa CleanMic | Čuje se denoised signal |
| VD-T03 | Zoom → Settings → Audio → Input = CleanMic | Radi u pozivu |
| VD-T04 | Meet (Chrome) → Settings → Microphone = CleanMic | Radi u browseru |
| VD-T05 | Teams, Discord — isto | Radi |
| VD-T06 | Sleep/wake 10x | CleanMic i dalje vidljiv |
| VD-T07 | App crash → driver i dalje vidljiv | Isporučuje tišinu, ne crasha coreaudiod |
| VD-T08 | Uninstall → provjera da nestaje | Nema tragova |
| VD-T09 | 2h poziv sa CleanMic | Nema dropova, CPU stabilan |
| VD-T10 | Više appova istovremeno koristi CleanMic | Svi dobijaju isti signal |

---

## 9. Reference implementacije

- **Apple NullAudio** — oficijelni sample HAL driver (osnova za fork)
- **BlackHole** — open-source virtual audio driver (najbolji real-world primjer)
- **Soundflower** — stariji, ali koristan za IPC ideje
- **Loopback (Rogue Amoeba)** — komercijalni, za inspiraciju UX-a (ne kopirati kod)

---

## 10. Odluke za Fazu 2 spike

| # | Pitanje | Kako odlučiti |
|---|---------|---------------|
| D-06 | Shared memory vs XPC | Mjerenje latencije + stabilnost 2h |
| D-07 | Mono vs stereo virtual device | Mono za MVP (jednostavnije), stereo kasnije ako treba |
| D-08 | Fiksni 48k vs podrška za više rateova | Fiksno 48k za MVP, resampling samo ako klijent inzistira |
| D-09 | Da li driver treba i output (loopback) ? | Ne u MVP-u — samo input |

---

**Sledeći dokument:** `PRD-05-UX-UI.md`
