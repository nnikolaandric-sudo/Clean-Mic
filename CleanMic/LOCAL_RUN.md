# CleanMic — Lokalno pokretanje (Faza 0.5 — pravi RNNoise)

> ✅ **Radi lokalno** — testirano 27.08.2026 na macOS 26.5.1 (M1, CLT 16.0, Swift 6.0.3)
> **Faza 0.5 završena:** mock `NoiseProcessor` zamenjen pravim `xiph/rnnoise` C lib-om (`rnnoise_create`/`rnnoise_process_frame`) kroz `RNNoiseBridge.c` + `librnnoise.a` (14 MB). Flat-build preko `scripts/build.sh` — radi bez Xcode, samo CLT.

## Brzi start

```bash
# C++ demo (najstabilnije, radi bez Xcode) — još uvek mock (ne diran u 0.5)
./CleanMic/bin/cleanmic-demo all
./CleanMic/bin/cleanmic-demo list
./CleanMic/bin/cleanmic-demo offline
./CleanMic/bin/cleanmic-demo test-rings

# Swift CLI (Faza 0.5 — AVAudioEngine + **pravi RNNoise**)
./CleanMic/bin/cleanmic-cli help
./CleanMic/bin/cleanmic-cli list
./CleanMic/bin/cleanmic-cli test-rings
./CleanMic/bin/cleanmic-cli process /tmp/cleanmic_synthetic_in.wav /tmp/out.wav --mode balanced
./CleanMic/bin/cleanmic-cli record 5 /tmp/raw.wav
./CleanMic/bin/cleanmic-cli record-processed 5 /tmp/clean.wav --mode balanced

# SwiftUI Menu-bar App (GUI)
open CleanMic/bin/CleanMic.app
```

## Šta je testirano (Faza 0.5 — pravi RNNoise)

| Komanda | Status | Napomena |
|---------|--------|----------|
| `cleanmic-demo list` | ✅ | CoreAudio C — 1 input uređaj (MacBook Pro mic) |
| `cleanmic-demo test-rings` | ✅ | 5000 iteracija, lock-free SPSC |
| `cleanmic-demo offline` | ✅ | 2s synthetic 440Hz+noise → 3 moda, avg 0.012ms/frame (mock, ne RNNoise) |
| `cleanmic-demo realtime` | ✅ | 2s InputRing→Worker→OutputRing, 0 overruns, 0.018ms avg (mock) |
| `cleanmic-cli list` | ✅ | AVAudioEngine inputNode 1ch 48k Float32, permission ok |
| `cleanmic-cli test-rings` | ✅ | Swift RingBuffer, 5000 iteracija |
| `cleanmic-cli process` (RNNoise) | ✅ | WAV 2s → 200 frameova, 32ms total, avg **0.16ms**/frame, max 1.8ms (prvi frame init jitter) |
| `cleanmic-cli record 3` | ✅ | 3s snimak 144k frames, Float32 48k |
| `cleanmic-cli record-processed 2` (RNNoise) | ✅ | **230 frameova, avg 0.32ms, max 1.00ms, 0 over/underrun** — RNNoise C lib (14 MB) |

Fajlovi se snimaju u `/tmp/*.wav` — preslušaj sa `afplay`.
`[NoiseProcessor] init mode=Balanced (RNNoise C lib, frameSize=480)` u logu potvrđuje da je pravi RNNoise aktivan (hard fail ako lib nije linkovan).

## Build (ponovno kompajliranje)

```bash
# Bez Xcode, samo Command Line Tools — universal (arm64 + x86_64), macOS 13+
./CleanMic/scripts/build.sh                 # -> CleanMic/bin/
ARCHS=arm64 ./CleanMic/scripts/build.sh     # samo Apple Silicon (brže)
./CleanMic/scripts/make-dmg.sh              # -> CleanMic/dist/CleanMic-<verzija>.dmg
./CleanMic/bin/cleanmic-cli selftest        # offline provjera builda
```

`build.sh` kopira Core + target u jedan modul i zove `swiftc` po arhitekturi,
pa `lipo` spaja u universal binarku. SwiftPM bez punog Xcode-a ne zna napraviti
universal build, zato flat-copy. Verzija je u `CleanMic/VERSION`.

Raniji workaround (patchovan SDK u `/tmp` + VFS overlay za CLT 16.0 / Swift
6.0.3) više nije potreban i uklonjen je — testirano 05.10.2026 sa Swift 6.3.3
i SDK-om 26.5.

### RNNoise build detalji

- Izvor: `CleanMic/Vendor/rnnoise` (git submodule `https://github.com/xiph/rnnoise.git`)
- Model: `rnnoise_data.c` (78 MB) + `rnnoise_data_little.c` preuzeti automatski kroz `scripts/build-rnnoise.sh` (curl + tar) ako nedostaju — ne zahteva `autoconf`/`automake`.
- Kompajlira se kao `librnnoise.a` (14 MB) sa `clang -O3 -DRNNOISE_BUILD` bez `autotools`; izvori su eksplicitno navedeni iz `vendor/rnnoise/Makefile.am` (`RNNOISE_SOURCES`).
- Bridge: `Sources/CleanMicCore/include/RNNoiseBridge.h` + `Sources/CleanMicCore/RNNoiseBridge.c` (`cm_rnnoise_*` C API). Swift ga poziva preko `@_silgen_name` bez bridging header-a.
- `NoiseProcessor.swift` sada koristi `cm_rnnoise_process_frame` direktno; VAD (0..1) dolazi iz RNNoise-a. `CleanMicMode` (light/balanced/maximum) samo menja post-gain i VAD gate, ne VAD threshold.

## Struktura

```
CleanMic/
├── bin/
│   ├── cleanmic-cli    # Swift CLI (AVAudioEngine, RingBuffer, **pravi RNNoise**)
│   ├── cleanmic-demo   # C++ demo (CoreAudio C, mock — ne diran)
│   └── CleanMicApp     # SwiftUI MenuBarExtra (GUI)
├── Vendor/
│   └── rnnoise/        # git submodule xiph/rnnoise + build/librnnoise.a (14 MB, .gitignore)
├── Sources/
│   ├── CleanMicCore/   # RingBuffer, DeviceLister, FormatConverter, AudioCapture, **NoiseProcessor (RNNoise)**, RNNoiseBridge.{h,c}, ProcessingEngine, WAVWriter, Metrics
│   ├── CleanMicCLI/    # CLI main.swift
│   ├── CleanMicApp/    # SwiftUI App
│   └── CleanMicClangDemo/ # C++ demo
├── scripts/
│   ├── build.sh          # universal build svih binarki + .app bundle
│   ├── build-rnnoise.sh  # RNNoise C lib po arhitekturi (curl model ako treba, clang bez autotools)
│   ├── make-app-bundle.sh# Info.plist + ikona + ad-hoc potpis
│   ├── make-dmg.sh       # build + DMG u dist/
│   ├── make-icon.swift   # generiše Resources/AppIcon.icns
│   └── run.sh            # quick run helper
├── Resources/AppIcon.icns
├── VERSION
└── Package.swift       # swift-tools-version 6.0, radi sa Xcode (unsafeFlags -L Vendor/rnnoise)
```

## Modovi (mjereno, ne procijenjeno)

Modovi se razlikuju po **wet/dry miksu** — koliko RNNoise izlaza ide u finalni
signal. Ranije su se razlikovali samo po izlaznom gainu, sto mijenja glasnocu
ali ne i odnos govora prema buci, pa su sva tri moda davala identican SNR.

Mjereno na govoru sa pink bukom (ulaz: SNR 7.5 dB):

| Mod | wet | SNR | govor | buka | granice | pod pauze | pumpanje |
|-----|-----|-----|-------|------|---------|-----------|----------|
| Light | 0.55 | 13.5 dB | −2.5 dB | −8.6 dB | 0.78x | −39.9 dB | 3.3 dB |
| Balanced | 0.85 | 13.3 dB | −2.0 dB | −7.8 dB | 0.91x | −44.1 dB | 4.8 dB |
| Maximum | 0.95 | 13.1 dB | −1.6 dB | −7.2 dB | 1.05x | −46.8 dB | 5.6 dB |

Ljestvica je kompromis, ne "sve bolje udesno": Light je najstabilniji i najvjerniji
glasu, Maximum ima najtise pauze ali najvise pumpanja.

"granice frameova" = srednji skok signala tacno na granici 480-uzorackog framea
podijeljen srednjim skokom svuda; 1.0 znaci da se granice ne razlikuju od
ostatka signala. Ispod 1.0 je pozeljno.

### Adaptivni dry gate

Dry signal postoji da vrati prirodnost glasu. U pauzama nema glasa da se vraca,
pa dry tamo samo vraca buku — i to je bilo jedino sto je ogranicavalo koliko
tihe pauze mogu biti. Sada se dry gasi srazmjerno kad je RNNoise izlaz tih,
sa pragom **relativnim** na tekuci nivo (ne apsolutnim, da ne zavisi od toga
koliko je glasno snimljeno). Na light modu: SNR 10.6 → 13.5 dB, buka −5.6 →
−8.6 dB, uz nepromijenjen govor. Na cistoj buci: −16.5 → −25.5 dB.

Dry je usput radio i kao **comfort noise** — stalan tihi sum koji maskira to
sto RNNoise sam modulira svoj izlaz. Kad se pusti da padne na nulu, ta se
modulacija ogoli i cuje kao pumpanje. Zato dry ima donju granicu (0.20):

| floor | SNR | skok nivoa izmedju pauznih frameova |
|-------|-----|-------------------------------------|
| bez gatea | 10.6 dB | 1.4 dB |
| 0.00 | 13.7 dB | 6.3 dB (pumpa) |
| **0.20** | **13.5 dB** | **3.3 dB** |
| 0.50 | 12.8 dB | 2.3 dB |

### Zagrijavanje modela

Prvi `rnnoise_process_frame` kosta **17.6 ms** umjesto ~0.6 ms — tada se 14.7 MB
tezina modela stvarno ucitava u memoriju. Na realtime niti to je propusten
frame (izmjereno 53.85 ms na zivom mikrofonu, uz 10 ms budzeta). `NoiseProcessor`
sada prodje 3 framea tisine pri inicijalizaciji i resetuje RNN stanje.

Ostaje **sporadican skok od ~48 ms na hladnom startu procesa** — otprilike 1 od
6 pokretanja. Nije u audio kodu: javlja se i u offline putu koji nema ni niti ni
sleep, dok tijesna C petlja od 2000 frameova ima max 4.1 ms. Vjerovatno je
rijec o pokretanju procesa i rasporedu po jezgrima. U zivim testovima ga je ring
buffer apsorbovao — 0 underruna i 0 overruna u svakom pokretanju.

Dvije stvari koje su mjerenjem odbacene:

- **wet = 1.00 (cisti RNNoise)** je losiji od 0.95 i po potiskivanju buke
  (−6.9 dB) i po granicama (1.10x). Zato maximum nije 1.0.
- **VAD gate** je uklonjen. RNNoise VAD u pauzama ostaje visok (prosjek 0.655),
  pa je gate okidao samo tamo gdje je RNNoise vec utisao signal. Sa pragom 0.80
  i atenuacijom 0.90 okine na 102 od 655 frameova, a rezultat je identican do
  jedne decimale.

RNNoise izlaz kasni **337 uzoraka (7.02 ms)** za ulazom — izmjereno unakrsnom
korelacijom. Dry grana u miksu se kasni za isto toliko; bez toga se mijesaju
dvije verzije istog signala pomjerene u vremenu (comb filter), sto je mjerljivo
kvarilo granice frameova (1.64x umjesto 0.77x).

Tuning ovih brojeva je radjen na sintetickom signalu (`say` TTS + pink buka).
Za tvoj glas u tvom prostoru provjeri sa `record-processed` i podesi `wetMix`
u `Sources/CleanMicCore/NoiseProcessor.swift`.

## Sledeći koraci (PRD)

- [x] 0.5 — RNNoise C lib submodule + C bridge (zamena mock-a) — **gotovo 27.08.2026**
- [ ] 0.9 — Latencija & CPU merenje na M1 (detaljniji bench, Instruments)
- [ ] 1.1 — Lock-free C++ RingBuffer final
- [ ] 2.x — Virtual driver (HAL plugin, najrizičnije)

## Privatnost

Denoise (RNNoise) je isključivo lokalan. Transkripcija i izvještaj šalju snimak
na OpenRouter — vidi [TRANSCRIBE.md](TRANSCRIBE.md).

## Napomena o Xcode

`xcodebuild` trenutno nije dostupan (`CommandLineTools` je active). Za puni `xcodebuild` + notarization instaliraj Xcode:
```bash
xcode-select --install
# ili App Store → Xcode
sudo xcode-select -s /Applications/Xcode.app
```
