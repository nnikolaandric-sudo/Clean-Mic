# PRD-05 — UX/UI Specifikacija

| Polje | Vrijednost |
|-------|------------|
| Verzija | v1.0 |
| Datum | 27.08.2026 |
| Status | Draft |
| Platforma | macOS 13+ (Ventura+) |

---

## 1. UX Principi

| Princip | Objašnjenje |
|---------|-------------|
| **2 klika do svega** | Menu-bar verzija omogućava ON/OFF, promjenu moda i izbor inputa u max 2 klika |
| **Ne ometaj poziv** | Nema modalnih dijaloga tokom poziva; sve promjene su live |
| **Jasna povratna informacija** | Level metri pokazuju da mic radi i da obrada radi |
| **Privatnost na prvom mjestu** | "Local only" indikator uvijek vidljiv |
| **Fail gracefully** | Greške su objašnjene ljudskim jezikom sa akcijom |

---

## 2. Aplikacija — tip

- **Menu-bar app (NSMenuBarExtra / NSStatusItem)** — primarni interfejs
- **Settings window** — sekundarni, za onboarding i napredno
- **Nema Dock ikone po defaultu** (opciono u Settings)
- **Launch at login** — opciono, pita na onboarding-u

---

## 3. Ekrani i stanja

### 3.1 Menu-bar dropdown (glavni UI)

```
┌─────────────────────────────────┐
│  ● CleanMic ON          [toggle]│  ← ON/OFF (P0)
├─────────────────────────────────┤
│  Input                          │
│  ▾ MacBook Microphone           │  ← dropdown fizičkih mic-ova
├─────────────────────────────────┤
│  Mode                           │
│  ○ Light                        │
│  ● Balanced            (default)│
│  ○ Maximum                      │
├─────────────────────────────────┤
│  Input level    ███████████░░   │  ← real-time
│  Processed      ██████████████░ │  ← real-time
├─────────────────────────────────┤
│  Virtual mic: CleanMic  ✓       │
│  Privacy: Local only   🔒       │
├─────────────────────────────────┤
│  Settings...                    │
│  Quit                           │
└─────────────────────────────────┘
```

**Spec:**

| Element | Tip | Ponašanje |
|---------|-----|-----------|
| ON/OFF toggle | Switch | Odmah primjenjivo, animacija 200ms |
| Input dropdown | NSPopUpButton | Lista `AVAudioEngine` inputa, auto-refresh |
| Mode radio | Radio group | Light/Balanced/Maximum, default Balanced |
| Input level | Bar (0–100%) | Zelena → žuta → crvena (clipping) |
| Processed level | Bar | Isto, ali nakon obrade |
| Virtual mic status | Label + check | ✓ = vidljiv, ⚠ = nije instaliran |
| Privacy | Label + lock | Uvijek "Local only" + tooltip |

**Interakcije:**

- Klik na menu-bar ikonu → otvara dropdown
- Promjena inputa → pipeline re-init, bez zatvaranja dropdowna
- Promjena moda → instant, bez prekida
- Hover na Privacy → tooltip: "Audio se obrađuje lokalno na vašem Macu. Ne šalje se na server."

### 3.2 Menu-bar ikona — stanja

| Stanje | Ikona | Opis |
|--------|-------|------|
| ON, Balanced | ● (plava/zeleno) | Normalno |
| ON, Light | ◐ (svijetlo) | Blaga obrada |
| ON, Maximum | ● (narandžasto) | Agresivno |
| OFF (bypass) | ○ (siva) | CleanMic vidljiv ali ne obrađuje |
| Error / no mic | ⚠ (crvena) | Nema inputa ili driver nije instaliran |
| Muted (ako dodamo) | 🔇 | Opciono |

### 3.3 Onboarding flow (prvi start)

```
Step 1: Welcome
┌─────────────────────────────────┐
│  CleanMic                       │
│  Čist glas u svakom pozivu.     │
│  Lokalno. Brzo. Privatno.       │
│                                 │
│  [Nastavi]                      │
└─────────────────────────────────┘

Step 2: Microphone Permission
┌─────────────────────────────────┐
│  Dozvola za mikrofon             │
│  CleanMic treba pristup mikrofonu│
│  da bi uklonio buku.            │
│  Audio ostaje na vašem Macu.    │
│                                 │
│  [Dozvoli pristup]  → sistemski │
│                       dialog    │
└─────────────────────────────────┘
  ↓ ako odbijeno:
┌─────────────────────────────────┐
│  Dozvola odbijena                │
│  Idite na System Settings →     │
│  Privacy → Microphone →         │
│  uključite CleanMic             │
│  [Otvori Settings] [Pokušaj opet]│
└─────────────────────────────────┘

Step 3: Driver Install
┌─────────────────────────────────┐
│  Instaliraj CleanMic mikrofon   │
│  Kreiramo virtualni mikrofon    │
│  "CleanMic" vidljiv u Zoomu itd.│
│                                 │
│  Potrebna je admin lozinka.     │
│  [Instaliraj]                   │
└─────────────────────────────────┘

Step 4: Choose Input + Test
┌─────────────────────────────────┐
│  Izaberite mikrofon              │
│  ▾ MacBook Microphone            │
│                                 │
│  Probajte — pričajte:            │
│  Input:     ████████░░           │
│  Processed: ██████████           │
│                                 │
│  Mode: ○ Light ● Balanced ○ Max │
│  [Završi] [Testiraj u QuickTime]│
└─────────────────────────────────┘
```

**Spec:**

- Onboarding se prikazuje samo na prvom startu ili ako je driver/mic nedostupan
- Svaki korak ima "Preskoči" osim permissiona
- Nakon završetka → menu-bar je spreman

### 3.4 Settings window

```
┌─ CleanMic Settings ─────────────────────────┐
│  General | Audio | About                    │
├────────────────────────────────────────────┤
│  [General]                                 │
│  ☑ Pokreni pri pokretanju sistema          │
│  ☑ Prikaži u Dock-u (pored menu bara)      │
│  ☐ Prikaži notifikacije o promjeni uređaja │
│                                            │
│  [Audio]                                   │
│  Input device: ▾ MacBook Microphone        │
│  Mode: ○ Light ● Balanced ○ Maximum        │
│  [ ] Auto mode (bira mod prema buci) — v1.1│
│                                            │
│  Virtual driver: ✓ Instaliran              │
│  [Reinstaliraj] [Deinstaliraj]             │
│                                            │
│  [About]                                   │
│  Verzija 1.0.0 | Privacy Policy | Logs     │
│  [Otvori log folder]                       │
└────────────────────────────────────────────┘
```

### 3.5 Greške i edge stanja

| Stanje | Poruka | Akcija |
|--------|--------|--------|
| Nema dozvole | "CleanMic nema pristup mikrofonu" | Dugme → System Settings |
| Driver nije instaliran | "CleanMic mikrofon nije pronađen" | Dugme → Instaliraj |
| Nema fizičkog mic-a | "Nijedan mikrofon nije povezan" | Lista prazna + info |
| CPU preopterećen | "Obrada usporena — prebaci na Light?" | Toast, ne blokira |
| App nije pokrenut a driver se koristi | "CleanMic app nije pokrenut — isporučuje se tišina" | Notifikacija |

---

## 4. Interakcije — ključni flow-ovi

### 4.1 Flow: Uključi CleanMic za Zoom poziv (happy path)

1. Korisnik instalirao CleanMic, prošao onboarding
2. Otvara Zoom → Settings → Audio → Microphone → bira `CleanMic`
3. U menu baru vidi da je CleanMic ON / Balanced
4. Priča — level metri se pomjeraju
5. Sagovornik čuje očišćen glas

**Vrijeme:** <10s od otvaranja Zooma

### 4.2 Flow: Promjena moda tokom poziva

1. Korisnik je u pozivu, čuje se ventilator
2. Klik na menu-bar → bira Maximum
3. Obrada se odmah mijenja, bez prekida poziva
4. Ventilator nestaje

### 4.3 Flow: AirPods se isključe tokom poziva

1. AirPods battery prazna → disconnect
2. CleanMic detektuje → automatski prebacuje na MacBook mic
3. Menu-bar input se ažurira
4. Toast: "Prebačeno na MacBook Microphone"
5. Poziv se nastavlja

---

## 5. Vizuelni dizajn (smjernice)

- **Stil:** Native macOS, SF Symbols, vibrancy, ne custom skin
- **Boje:** Sistemske (accent color), zelena za ON, siva za OFF, crvena za error
- **Tipografija:** SF Pro, 13pt za dropdown, 11pt za status
- **Ikone:** SF Symbols (`mic.fill`, `waveform`, `lock.shield`)
- **Dark/Light:** Automatski prati sistem
- **Animacije:** Suptilne (200ms ease), ne ometaju

---

## 6. Accessibility

- VoiceOver label-e za sve kontrole
- Keyboard navigacija u dropdown-u
- Kontrast prema WCAG AA
- Level metri imaju i tekstualni opis ("Input 75%")

---

## 7. Copy — ton i jezik

- Jezik: **BS/HR/SR** za MVP (lokalno tržište), EN za kasnije
- Ton: Kratko, jasno, bez tehničkog žargona
  - ✅ "Uklanja buku ventilatora i tipkanja"
  - ❌ "Primjenjuje RNNoise spektralno potiskivanje sa VAD-om"
- Privacy copy: "Vaš glas ne napušta ovaj Mac."

---

## 8. Šta NIJE u MVP UX-u

- Nema dock-only moda kao primarnog (samo opciono)
- Nema globalnih hotkey-eva (v1.1)
- Nema auto-gain slidera (v1.1)
- Nema per-app profila (v2.x)
- Nema onboarding videa — samo tekst + metri

---

## 9. Prototip preporuka

- Figma za menu-bar dropdown + onboarding (4 ekrana)
- SwiftUI preview za live iteraciju
- Testirati sa 5 korisnika: "Možeš li uključiti CleanMic za Zoom bez uputa?"

---

**Sledeći dokument:** `PRD-06-NFR-Test-Plan.md`
