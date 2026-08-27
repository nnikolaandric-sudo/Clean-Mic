# ADR-001 — Izbor audio stacka

- Datum: 27.08.2026
- Status: Proposed (odlučiti u Fazi 0)

## Kontekst
Treba odabrati između AVAudioEngine (viši nivo) i direktnog HAL IOProc (niži nivo) za capture.

## Opcije
- A) AVAudioEngine tap — brži spike, manje kontrole
- B) HAL IOProc — više kontrole, više koda

## Odluka
TODO nakon spike-a Faza 0 — uporediti stabilnost na device change, latenciju, CPU.

## Posljedice
Apstrakcija `AudioCapture` mora podržati oba backenda.
