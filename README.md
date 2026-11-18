# Livella

**Keep your video and music audible during calls on macOS, and lower them only while someone is speaking.**

*[Italiano più sotto](#italiano)*

When a call app starts (WhatsApp, FaceTime, Zoom, …), macOS turns every other sound down by about 30 dB and offers no setting to stop it. Livella is a small menu bar app that:

- **finds the call by itself**: the call is whichever app is using the microphone, so there is nothing to configure;
- **brings video and music back up** (about 18 of the 30 dB macOS removes, plus an optional boost);
- **lowers them only while someone speaks**: the other person, or you;
- **tells your voice from noise**: key clicks, claps, rubbing, steady background noise and other people talking further away do not trigger it.

The interface is in Italian.

> **Status: prototype.** Built and tested in one evening on one Mac (macOS 27, Apple silicon) with AirPods and WhatsApp. Other call apps and other headphones are untested. Expect rough edges.

## How it works

- A **Core Audio process tap** (macOS 14.2+) captures every app except the call, muted at the source, and Livella plays that audio back itself with its own gain. No driver, no kernel extension.
- A second, unmuted tap on the call app only *measures* when the other person speaks. The call's own audio is never touched, so the call app's echo cancellation keeps working.
- A third tap on Livella's own output measures how much macOS is lowering it, so the make-up gain is the real amount, not a guess.
- Your own voice is detected from the microphone's level (nothing is recorded or stored). A 10 ms slice counts as speech only if it is clearly above the background, close to your usual speech level, **voiced** (a regular pitch between 75 and 350 Hz, measured by autocorrelation) and lasts at least 60 ms.

## Requirements

- macOS 15 or later (built and tested on macOS 27)
- Xcode command line tools (Swift 6)

## Build and run

```bash
./build.sh
```

```bash
open Livella.app
```

The app is signed ad hoc for your Mac. On first launch, allow:

- **System Audio Recording**: needed to adjust other apps' audio. macOS has no narrower permission for this.
- **Microphone**: only if you keep "Abbassa anche quando parlo io" (also lower when I speak) on.

Because the signature changes on every build, macOS may ask for these again after you rebuild.

## Diagnostics

```bash
.build/release/Livella --probe
```

lists audio devices, the apps using the microphone and the call detected right now.

```bash
.build/release/Livella --probe-gate
```

runs the speech detector against synthetic sounds (voice, claps, rubbing, typing, other voices) and checks each result.

The log is at `~/Library/Logs/Livella/Livella.log` (device and app names and levels only, never audio).

## Known limits

- Recovers about 18 dB of the ~30 dB macOS removes, not all of it.
- A call and a video in the **same browser** cannot be told apart.
- With a Bluetooth headset's own microphone, macOS switches the headphones to low-quality "headset" mode. That is a Bluetooth limit; Livella cannot change it.
- Someone speaking loudly very close to you can still count as your voice.
- Adds about 25 ms of latency to video and music during calls.
- Reads the audio-capture permission state through a private TCC call, so it cannot ship on the Mac App Store.
- Not notarized.

## Credits

The approach was informed by two MIT-licensed projects, read while building this one:

- [Unduck](https://github.com/alecswang/unduck) by alecswang: measurements of the macOS call ducking, and the audio-capture permission handling.
- [SonicFlow](https://github.com/altuzar/sonicflow) by altuzar: per-app volume with process taps.

Written with [Claude Code](https://claude.com/claude-code).

## License

MIT. See [LICENSE](LICENSE).

---

## Italiano

**Tiene udibili video e musica durante le chiamate su macOS, e li abbassa solo mentre qualcuno parla.**

Quando parte una chiamata, macOS abbassa tutti gli altri suoni di circa 30 dB e non offre un'impostazione per evitarlo. Livella è una piccola app nella barra dei menu che:

- **trova la chiamata da sola**: è l'app che sta usando il microfono, non c'è niente da configurare;
- **riporta su video e musica** (circa 18 dei 30 dB tolti da macOS, più un aumento facoltativo);
- **li abbassa solo mentre qualcuno parla**: l'altra persona, oppure tu;
- **distingue la tua voce dai rumori**: tasti, colpi, sfregamenti, rumore di fondo e persone più lontane non la fanno scattare.

**Stato: prototipo.** Provata su un solo Mac con AirPods e WhatsApp.

**Per usarla:** esegui `./build.sh`, poi apri `Livella.app`. Al primo avvio consenti "Registrazione audio di sistema" e, se vuoi che abbassi anche quando parli tu, "Microfono". L'audio non viene mai registrato né inviato.

**Limiti:** non recupera tutto l'abbassamento; non distingue chiamata e video nello stesso browser; con il microfono delle cuffie Bluetooth l'audio resta in qualità "cuffia"; chi parla forte molto vicino a te può essere scambiato per te.
