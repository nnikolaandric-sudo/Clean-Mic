# CleanMic — instalacija na Mac

Radi na macOS 13 (Ventura) i novijem, Apple Silicon i Intel (universal).

## 1. Preuzmi i instaliraj

1. Preuzmi `CleanMic-<verzija>.dmg` sa
   [stranice Releases](https://github.com/nnikolaandric-sudo/Clean-Mic/releases/latest).
2. Otvori DMG i prevuci **CleanMic** u **Applications**.

## 2. Prvo pokretanje (jednom po Macu)

Aplikacija je potpisana ad-hoc, ne Apple Developer ID-om, i nije notarizovana.
Zato je macOS Gatekeeper pri prvom pokretanju blokira:

1. Dvaput klikni CleanMic u Applications → poruka da Apple ne može provjeriti
   aplikaciju → **Done / Gotovo**.
2. **System Settings → Privacy & Security** → na dnu „CleanMic was blocked…" →
   **Open Anyway** → potvrdi.

Ili u Terminalu:

```bash
xattr -dr com.apple.quarantine /Applications/CleanMic.app
```

```bash
open /Applications/CleanMic.app
```

Da ovaj korak nestane, potreban je Apple Developer nalog ($99 godišnje):
potpis „Developer ID Application" + notarizacija (`xcrun notarytool`).

## 3. Dozvole

- **Mikrofon** — pita pri prvom snimanju.
- **Downloads folder** — pita pri prvom čuvanju (snimci idu u `~/Downloads/CleanMic`).

Ad-hoc potpis znači da macOS dozvolu za mikrofon veže za tačno taj build:
nakon instalacije nove verzije pitaće ponovo.

## 4. OpenRouter ključ

Zupčanik → **Podešavanja… → Transkript** → unesi ključ (`sk-or-…`) → **Sačuvaj**.
Ključ ostaje samo na tom Macu (`~/.config/cleanmic/openrouter_key`), pa se na
svakom laptopu unosi jednom.

## Nova verzija

Zatvori CleanMic (zupčanik → Izađi), prevuci novu verziju preko stare u
Applications, pa ponovi korak 2. Podešavanja i ključ ostaju.

## Build iz izvornog koda

Dovoljni su Command Line Tools (`xcode-select --install`), bez punog Xcode-a.

```bash
git clone --recurse-submodules https://github.com/nnikolaandric-sudo/Clean-Mic.git
```

```bash
cd Clean-Mic && ./CleanMic/scripts/make-dmg.sh
```

Rezultat: `CleanMic/dist/CleanMic-<verzija>.dmg`. Prvi build preuzima RNNoise
model (~60 MB). Verzija se mijenja u `CleanMic/VERSION`.
