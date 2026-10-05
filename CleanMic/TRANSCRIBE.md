# CleanMic — Snimanje → Transkripcija → Izvještaj

Snimak (očišćen RNNoise-om) ide na OpenRouter **`microsoft/mai-transcribe-2`**
(transkript), a zatim jeftin model (**`deepseek/deepseek-chat`**) pravi izvještaj:
Sažetak + Ključne tačke + Akcije, pa puni transkript.

## Kako radi

- **Snima dok ga ne zaustaviš.** Nema izbora trajanja. Jedan klik pokreće, drugi
  zaustavlja i čuva. 16-bit WAV 48 kHz mono, oko 350 MB po satu, do ~12 h u
  jednom fajlu. Header fajla se osvježava svakih par sekundi, pa snimak ostaje
  čitljiv i ako aplikacija padne ili se Mac ugasi.
- **Promjena mikrofona usred snimanja** (slušalice, AirPods, dock, buđenje iz
  sleepa) ne prekida snimak — capture se sam ponovo podigne.
- **Snimak duži od 1 h** se ne šalje sam: prvo se traži potvrda, uz procjenu
  troška i trajanja obrade. Kraći snimci idu automatski (ako je uključeno).
- **Dugi snimci**: audio se svodi na 16 kHz mono i dijeli na dijelove ≤160 s,
  rez je na najtišem mjestu da ne presiječe riječ. Dijelovi idu 3 paralelno,
  svaki sa do 6 pokušaja (provider često vrati 429/502). Dio u kojem niko ne
  govori vraća prazan tekst i ne obara cijeli transkript.
- **Izvještaj**: model piše samo sažetak; transkript se dodaje lokalno, cijeli.
  Transkript preko ~45.000 znakova ide dio po dio (bilješke → završni
  izvještaj). Ako izabrani model padne, proba se sljedeći sa liste.

## Ključ

Ključ se čita ovim redom:
1. `--api-key` flag
2. env `OPENROUTER_API_KEY`
3. fajl `~/.config/cleanmic/openrouter_key` (aplikacija ga tu upisuje, chmod 600)
4. UserDefaults (GUI)

U aplikaciji: zupčanik → **Podešavanja… → Transkript** → unesi → **Sačuvaj**
(**Provjeri** pokazuje da li ključ radi i koliko je kredita ostalo).
Ključ se unosi jednom po Macu — ne putuje sa aplikacijom.

```bash
./CleanMic/bin/cleanmic-cli set-key sk-or-v1-...
./CleanMic/bin/cleanmic-cli check-key
```

## GUI (CleanMic.app)

1. Klik na ikonu u menu baru → **Pokreni snimanje**. U menu baru teče vrijeme.
2. **Zaustavi i sačuvaj** → fajl je u `~/Downloads/CleanMic/`
   (folder se mijenja u Podešavanjima).
3. Ako je uključeno „Transkribuj i napravi izvještaj kad zaustavim", obrada
   kreće sama; inače klikni **Transkribuj i napravi izvještaj**.
4. **Otvori izvještaj** prikazuje sažetak i transkript u prozoru aplikacije.
   Meni `⋯`: ponovo napravi izvještaj (bez ponovne transkripcije) ili ponovo
   transkribuj.
5. Zupčanik → **Otvori postojeći snimak…** učitava raniji snimak (i onaj sa
   drugog Maca) — transkript/izvještaj pored njega se prepoznaju.

## CLI

```bash
# Snimi dok ne pritisneš Enter / Ctrl+C, pa transkribuj + izvještaj:
./CleanMic/bin/cleanmic-cli record-processed sastanak.wav --transcribe --language sr

# Snimi tačno 15 s:
./CleanMic/bin/cleanmic-cli record-processed 15 /tmp/clean.wav --mode balanced

# Transkribuj postojeći fajl (wav, m4a, mp3, aiff…):
./CleanMic/bin/cleanmic-cli transcribe sastanak.wav --language sr
./CleanMic/bin/cleanmic-cli transcribe sastanak.wav --no-report      # samo transkript
./CleanMic/bin/cleanmic-cli transcribe dugi.wav --yes                # >1 h bez pitanja

# Samo izvještaj iz postojećeg transkripta (ne naplaćuje transkripciju ponovo):
./CleanMic/bin/cleanmic-cli report sastanak.transcript.txt --language sr

# Drugi model za izvještaj:
./CleanMic/bin/cleanmic-cli report sastanak.transcript.txt --report-model openai/gpt-4o-mini

# Offline denoise postojećeg WAV-a:
./CleanMic/bin/cleanmic-cli process /tmp/raw.wav /tmp/clean.wav --mode balanced
```

Jezik: `--language sr|hr|bs|en` ili izostavi za auto-detect. Izvještaj se piše
na izabranom jeziku (`en` → engleski naslovi sekcija).

## Izlazni fajlovi (pored snimka)

| Fajl | Sadržaj |
|------|---------|
| `<ime>.transcript.txt` | transkript; dugi snimci: pasusi sa `[HH:MM:SS]` |
| `<ime>.transcript.json` | sirovi OpenRouter odgovori (usage/cost) |
| `<ime>.izvjestaj.md` | Sažetak + Ključne tačke + Akcije + puni transkript |

Privremeni fajlovi (16 kHz kopija, dijelovi) idu u sistemski temp folder i
brišu se nakon obrade.

## Kad nešto ne radi

- **Log:** `~/Library/Logs/CleanMic/cleanmic.log` (Podešavanja → Opšte →
  Prikaži log). Piše svaki dio, pokušaj, HTTP status, model i broj tokena —
  bez ključa i bez sadržaja snimka. CLI: dodaj `--verbose`.
- **Izvještaj nije uspio, transkript jeste:** `⋯` → Ponovo napravi izvještaj,
  ili `cleanmic-cli report <ime>.transcript.txt`.
- **Provjera builda na novom Macu:** `cleanmic-cli selftest` (offline, 12 provjera).
- **Prozor se „otvori pa nestane":** pokreni
  `CLEANMIC_DEBUG=1 CleanMic.app/Contents/MacOS/CleanMicApp` — ispisuje
  događaje prozora i aktivacije.

## Trošak (izmjereno 05.10.2026)

- `microsoft/mai-transcribe-2`: **$0.10 po satu** audija ($0.0153 za 9 min)
- `deepseek/deepseek-chat`: ispod jednog centa po izvještaju, i za sat transkripta

## Modeli za izvještaj

`deepseek/deepseek-chat` (default), `openai/gpt-4o-mini`,
`google/gemini-2.5-flash-lite`, `meta-llama/llama-3.1-8b-instruct`.
`google/gemini-flash-1.5-8b` je uklonjen — OpenRouter ga više ne nudi.

## Privatnost

- Denoise (RNNoise) ostaje 100% lokalno.
- ☁️ **Transkripcija + izvještaj šalju snimak na OpenRouter cloud** — samo kad je
  uključena automatska transkripcija ili kad klikneš Transkribuj
  (`--transcribe` u CLI-ju). Snimak duži od 1 h uvijek prvo pita.
