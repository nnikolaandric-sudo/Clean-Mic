# CleanMic — macOS aplikacija za uklanjanje pozadinske buke

> Standalone, lokalna i low-latency aplikacija koja kreira virtualni mikrofon `CleanMic` za Zoom, Google Meet, Microsoft Teams, Discord i druge aplikacije.

## Osnovna ideja

Aplikacija preuzima zvuk sa fizičkog mikrofona, obrađuje ga u realnom vremenu i šalje očišćeni signal u virtualni audio input pod nazivom **"CleanMic"**. Sve se izvršava **lokalno na Macu**, bez slanja govora na server.

## Dokumentacija

| Dokument | Opis |
|----------|------|
| [PRD Overview](Docs/PRD/PRD-00-Overview.md) | Vizija, ciljevi, sažetak proizvoda |
| [MVP Scope](Docs/PRD/PRD-01-MVP-Scope.md) | Scope, use case-ovi, funkcionalni zahtjevi |
| [Arhitektura](Docs/PRD/PRD-02-Architecture.md) | Tehnička arhitektura i komponente |
| [Audio Engine](Docs/PRD/PRD-03-Audio-Engine.md) | Audio pipeline, ring bufferi, processing |
| [Virtual Driver](Docs/PRD/PRD-04-Virtual-Driver.md) | CleanMic virtualni mikrofon driver |
| [UX/UI Spec](Docs/PRD/PRD-05-UX-UI.md) | UX, ekrani, flow |
| [NFR & Test Plan](Docs/PRD/PRD-06-NFR-Test-Plan.md) | Nefunkcionalni zahtjevi i test plan |
| [Roadmap](Docs/PRD/PRD-07-Roadmap.md) | Faze, sprintovi, Definition of Done |
| [Backlog](Docs/BACKLOG.md) | Task breakdown po fazama |

Originalni plan: `CleanMic_Plan_Aplikacije.docx` (v1.0)

## Stack

- **UI:** Swift + SwiftUI (menu-bar aplikacija)
- **Audio:** AVAudioEngine + Core Audio
- **Denoising:** RNNoise (C/C++ wrapper preko Objective-C++)
- **Virtual Device:** Audio Server Driver Plug-in (HAL)
- **Packaging:** Xcode + Developer ID + Notarization

## Struktura repozitorija

```
CleanMic/
├── App/                 # SwiftUI app, menu-bar, settings, DeviceMonitor
├── AudioEngine/         # Capture, RingBuffer, Processing, Metrics
├── NoiseEngine/         # RNNoise wrapper + NoiseProcessor
├── VirtualDriver/       # CleanMicDriver (Audio Server Plugin)
├── Installer/           # Signing, notarization, installer
├── Tests/               # Unit & integration testovi
└── Docs/                # Dokumentacija
Docs/
├── PRD/                 # PRD dokumenti (00-07)
├── Architecture/         # Dijagrami
└── Design/              # UX mockups
```

## Brzi start (nakon setup-a)

```bash
# Faza 0 — spike
open CleanMic/CleanMic.xcodeproj
# Build & Run -> testiraj capture + RNNoise offline
```

## Status

🚧 **Faza 0 — Inicijalizacija** — PRD dokumenti kreirani, repo struktura postavljena.

Pogledaj [Roadmap](Docs/PRD/PRD-07-Roadmap.md) za plan razvoja.

## Privatnost

Audio se obrađuje isključivo lokalno. Nema cloud upload-a govora u MVP-u.

## Licenca

Proprietary — Valens / CleanMic Team
