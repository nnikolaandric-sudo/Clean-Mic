# CleanMic — Snimanje → Transkripcija → Izvještaj

Snimak (očišćen RNNoise-om) ide na OpenRouter **`elevenlabs/scribe-v2`**
(transkript), a zatim **`openai/gpt-6-luna`** (GPT-6 Luna, default — može se
promijeniti) pravi izvještaj: Sažetak + Ključne tačke + Akcije, pa puni transkript.

## Kako radi

- **Snima dok ga ne zaustaviš.** Nema izbora trajanja. Jedan klik pokreće, drugi
  zaustavlja i čuva. 16-bit WAV 48 kHz mono, oko 350 MB po satu, do ~12 h u
  jednom fajlu. Header fajla se osvježava svakih par sekundi, pa snimak ostaje
  čitljiv i ako aplikacija padne ili se Mac ugasi.
- **Sastanci sa slušalicama.** Mikrofon čuje samo ono što uđe u sobu. Sa zvučnicima to
  uključuje i glasove ostalih učesnika, ali sa slušalicama ne — oni idu direktno u uši, pa bi
  transkript imao samo tebe. Zato CleanMic uz slušalice (Bluetooth, USB, priključak) uz
  mikrofon snima i ono što računar pušta i miješa ga u isti snimak. Na zvučnicima to ne radi
  (isti glas bi stigao dvaput, kao jeka). Uživo u prostoriji nema razlike: radi mikrofon.
  Podešavanja → Opšte → **Zvuk iz računara**: Automatski (default) / Uvijek / Nikad.
  Traži macOS 14.2+ i jednu dozvolu: **Screen & System Audio Recording**. Prvo podizanje
  nakon instalacije/ažuriranja traje ~5 s (macOS provjerava dozvolu), zato to aplikacija
  odradi čim vidi slušalice, prije sastanka. Snima se SVE što računar pušta (i muzika,
  i zvuk obavijesti), ne samo aplikacija za sastanak.
- **Ažuriranje.** CleanMic sam provjerava GitHub Releases (poslije pokretanja i svakih 6 h).
  Kad nađe novu verziju, **sam je preuzme, provjeri potpis izdanja i instalira** čim ne snimaš
  i ne radi transkript/izvještaj (nikad usred posla), pa se restartuje. Ključ i podešavanja
  ostaju. Ne šalje ništa o tebi. Zupčanik → O aplikaciji: *Provjeri ažuriranja*, te zasebno
  gašenje automatske provjere i samoinstalacije (tada kartica nudi *Ažuriraj sada*).
  - Svako izdanje je potpisano (Ed25519); ako se potpis ne poklapa, ništa se ne instalira.
  - Stara verzija se zamjenjuje tek kad je nova preuzeta i provjerena; ako zamjena zakaže,
    vraća se stara. Dnevnik: `~/Library/Logs/CleanMic/update.log`.
  - Radi samo kad je CleanMic u Applications (ne direktno sa diska) i kad imaš pravo upisa
    tamo; inače ostaje ručno (*Preuzmi*). Nakon svakog ažuriranja macOS može ponovo pitati
    za dozvolu za mikrofon (novi potpis aplikacije).
  - **Za izdavanje:** `./scripts/make-dmg.sh` potpiše DMG (`.dmg.sig`) ključem iz
    `~/.config/cleanmic/update_signing_key` — **sačuvaj kopiju tog fajla**; bez njega postojeće
    instalacije ne mogu primati automatska ažuriranja. Uz izdanje na GitHub idu **oba** fajla.
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
  izvještaj). Ako izabrani model ne odgovori, proba se jeftin rezervni
  (GPT-6 Luna, DeepSeek Chat, GPT-4o mini, Gemini 2.5 Flash Lite).

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

# Drugi model za izvještaj (bilo koji OpenRouter ID):
./CleanMic/bin/cleanmic-cli models                 # ponuđeni modeli sa cijenama
./CleanMic/bin/cleanmic-cli models claude          # pretraga svih modela na OpenRouteru
./CleanMic/bin/cleanmic-cli report sastanak.transcript.txt --report-model anthropic/claude-haiku-4.5

# Slušalice na glavi, online sastanak: mikrofon + ono što računar pušta (default: auto)
./CleanMic/bin/cleanmic-cli record-processed sastanak.wav --system-audio auto
#   --system-audio always   i na zvučnicima      --system-audio never   samo mikrofon

# Provjera da zvuk iz računara stiže (pusti nešto; ispiše nivo i da li je dozvola data):
./CleanMic/bin/cleanmic-cli record-system 10 /tmp/sistem.wav

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
- **Online sastanak sa slušalicama, a u transkriptu samo ti:** zvuk iz računara nije stigao.
  Aplikacija to javi poruku nakon snimanja ("Zvuk iz računara je bio tih…"). Provjeri
  System Settings → Privacy & Security → **Screen & System Audio Recording** → CleanMic.
  U logu piše `zvuk iz računara: …` (uključen/isključen, koliko je trebalo da krene).
- **Prozor se „otvori pa nestane":** pokreni
  `CLEANMIC_DEBUG=1 CleanMic.app/Contents/MacOS/CleanMicApp` — ispisuje
  događaje prozora i aktivacije.

## Modeli

**Transkripcija:** `elevenlabs/scribe-v2`.

**Izvještaj** — bira se u **Podešavanja → Transkript → Model za izvještaj**:

| Model | ID | Cijena (ulaz / izlaz po milion tokena) |
|-------|----|----------------------------------------|
| **GPT-6 Luna** (default) | `openai/gpt-6-luna` | $0.10 / $0.50 |
| GPT-6 Luna Pro | `openai/gpt-6-luna-pro` | $0.10 / $0.50 |
| GPT-6 Sol | `openai/gpt-6-sol` | $2.00 / $10.00 |
| Claude Haiku 4.5 | `anthropic/claude-haiku-4.5` | $1.00 / $5.00 |
| Gemini 2.5 Flash Lite | `google/gemini-2.5-flash-lite` | $0.10 / $0.40 |
| DeepSeek Chat | `deepseek/deepseek-chat` | $0.26 / $1.03 |
| GPT-4o mini | `openai/gpt-4o-mini` | $0.15 / $0.60 |
| Llama 3.1 8B | `meta-llama/llama-3.1-8b-instruct` | $0.05 / $0.08 |

Cijene su sa OpenRoutera na dan 05.10.2026; trenutne: `cleanmic-cli models`.

**Drugi model…** u istom meniju prima bilo koji ID sa openrouter.ai/models.
„Provjeri i sačuvaj" prvo potvrdi da model postoji i pokaže mu cijenu — pogrešno
upisan ID se ne čuva. Polje „Koristi se" uvijek pokazuje model koji je stvarno aktivan.

Ko je do verzije 1.1 bio na starom defaultu (`deepseek/deepseek-chat`), pri prvom
pokretanju 1.2 prelazi na GPT-6 Luna. Kasniji ručni izbor se ne dira.

## Trošak (izmjereno 05.10.2026)

- `elevenlabs/scribe-v2` (novi default): trošak OpenRouter vraća u `usage.cost`
- `microsoft/mai-transcribe-2` (prethodni default, može se vratiti u Podešavanjima): ranije izmjereno **$0.10 po satu** audija ($0.0153 za 9 min)
- `openai/gpt-6-luna`: oko **pola centa** za izvještaj iz transkripta od sat
  vremena (≈21.000 tokena ulaza, ≈5.500 izlaza); kratki snimci ispod desetine centa

## Privatnost

- Denoise (RNNoise) ostaje 100% lokalno. Zvuk iz računara se ne čisti (već je čist) i ne
  napušta Mac osim kao dio snimka koji ti sam pošalješ na transkripciju.
- ☁️ **Transkripcija + izvještaj šalju snimak na OpenRouter cloud** — samo kad je
  uključena automatska transkripcija ili kad klikneš Transkribuj
  (`--transcribe` u CLI-ju). Snimak duži od 1 h uvijek prvo pita.
