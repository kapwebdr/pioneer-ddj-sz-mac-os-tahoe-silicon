# ddj-sz-routing

Made with love by **Damien RICHARD / Kapweb**.

**The DDJ-SZ is not dead. Pioneer just stopped showing up.**

A 4-channel battle mixer, real PHONO preamps, two DVS decks, and a chassis that still feels like a tank. Audio, MIDI and the controller still work on a current Mac — including Apple Silicon and macOS Tahoe. What died is the one tiny switch Serato needs: USB inputs CH3 and CH4 set to **Control Tone PHONO**.

Without that, the needles move, the hardware VU moves, and Serato’s DVS scope sits at 0%. The vinyl is talking. The Mac is listening to the wrong source.

Pioneer’s **DDJ-SZ Setting Utility** was Intel-only. On Tahoe it throws a driver-configuration error and cannot change the routing. They do not maintain that stack anymore. This project is a small native macOS tool that sends the **same official USB routing** the Setting Utility used to send — so this hardware can keep playing.

It does not replace the audio driver. It does not need Rosetta. It does not load `PioneerDDJSetup.framework`. It does not invent USB writes.

---

## The problem, in plain language

| What still works | What is broken |
|---|---|
| USB audio in Serato | DVS scopes on decks 3 / 4 |
| MIDI / pads / platters | Pioneer Setting Utility (Intel, unmaintained) |
| Hardware PHONO preamp + VU | USB input source stuck on something else (often Cross Fader / MIC) |

DVS is not “the vinyl signal into the mixer”. That already works. DVS is “the mixer must copy **Control Tone PHONO** onto the USB channels Serato watches”. That copy was a vendor USB control transfer, hidden inside an x86 framework Pioneer no longer ships for Apple Silicon.

This tool restores **that** setting. Nothing else.

If CH3/CH4 really switch to Control Tone PHONO and Serato is still silent, the leftover problem is the old Pioneer HAL audio driver. That driver is out of scope — rewriting it is a different project.

---

## Quick start

```bash
xcode-select --install   # once, if clang / make are missing
make
./ddj-sz-routing status  # read current USB routing (no write)
./ddj-sz-routing         # apply DVS: CH3 + CH4 → Control Tone PHONO
```

Then: Serato DJ Pro → **Setup** → **CD/Vinyl**. Control vinyl on a deck wired to **CH3 PHONO** (and CH4 if you use two DVS decks). Spin. Calibrate.

On Apple Silicon the binary is native `arm64`. No Rosetta.

```bash
sudo make install                 # /usr/local/bin
# or
make install PREFIX="$HOME/.local"
```

---

## Commands

| Command | What it does |
|---|---|
| `ddj-sz-routing` or `dvs` | Apply the DVS writes from the connected device profile |
| `ddj-sz-routing status` | Read and print current USB input routing |
| `ddj-sz-routing learn` | Extract official Pioneer tables, match the plugged-in device, write a profile |
| `ddj-sz-routing learn extract` | Write a profile for every device found in PioneerDDJSetup |
| `ddj-sz-routing help` | Usage |

The DDJ-SZ profile is built in (`VID 0x08E4`, `PID 0x0191`). Root is usually not required. Quit Serato first if a USB request is rejected.

---

## Daily use (DDJ-SZ)

1. Power the DDJ-SZ from its own PSU and plug USB into the Mac.
2. Prefer quitting Serato before the first run of the night.
3. Run `./ddj-sz-routing` (or `ddj-sz-routing` if installed).
4. Open Serato → Setup → CD/Vinyl and calibrate decks 3 / 4.

**When to run it again**

- Safe to run as many times as you want. Same two official values. No firmware flash, no stacked settings.
- If the **SZ stays powered** while the Mac reboots, routing often survives. Check with `status`.
- If the **SZ is powered off**, unplugged, or loses USB, it usually forgets DVS. Hardware VU still moves; Serato goes mute. Run the tool again after power-up.
- Rule of thumb: if DVS is dead after you powered the mixer, run it. If `status` already shows `[DVS]` on CH3 and CH4, skip it.

No login item. No launchd. You run it when you sit down at the decks.

### What success looks like

```
Pioneer DDJ-SZ  VID 0x08e4  PID 0x0191
Setting DVS routing:
  CH3 Control Tone PHONO  wValue 0x0303
  CH4 Control Tone PHONO  wValue 0x0403
USB input routing:
  CH3         CH3 Control Tone PHONO  [DVS]
  CH4         CH4 Control Tone PHONO  [DVS]
```

Then Serato’s scopes should move.

### What it looks like when it did not stick

```
warning: writes were sent but GET did not confirm the expected DVS indexes.
```

USB accepted the write. The mixer still reports the old source (often **Cross Fader B**). DVS is **not** applied. Reloading Serato will not fix that. See [Known limits](#known-limits).

---

## Learn: other Pioneer-era mixers

`learn` never guesses payloads. It parses the Mach-O tables inside the official Setting Utility binary — the same data a human would hunt with:

```bash
otool -arch x86_64 -tvV \
  "/Library/Frameworks/PioneerDDJSetup.framework/Versions/A/PioneerDDJSetup"
```

You do not need that dump. The extractor reads `__convTable_*`, `_*_TEXT` and `_InputAudioText` directly (x86_64 slice, works on Apple Silicon).

```bash
./ddj-sz-routing learn            # match the USB device that is plugged in
./ddj-sz-routing learn extract    # export every device the framework still knows
```

Or JSON on stdout:

```bash
python3 tools/extract_pioneer_profile.py --list
python3 tools/extract_pioneer_profile.py --pid 0x0191
```

Profiles land in:

- bundled example: `profiles/ddj-sz.json`
- generated: `~/Library/Application Support/ddj-sz-routing/profiles/<vid>_<pid>.json`

`dvs` writes only when the profile contains non-zero official `wValue`s.

**Can generate:** devices actually described in PioneerDDJSetup — DDJ-SZ, DJM-900nexus, DJM-T1, DJM-900SRT (`VID 0x08e4`). Only the DDJ-SZ path is verified live.

**Cannot generate:** a DDJ-SZ2 profile. SZ2 is `VID 0x2b73` / `PID 0x0016`. That mixer is not in PioneerDDJSetup. Dumping the old framework again will never invent SZ2 writes. You would need that product’s own setup binary, then extend the extractor. Do not type random hex.

---

## How it works

Pioneer’s Setting Utility used a vendor control transfer:

| | |
|---|---|
| Write | `bmRequestType=0x40`, `bRequest=0x03`, `wIndex=0x8002`, `wLength=0` |
| CH3 Control Tone PHONO | `wValue=0x0303` |
| CH4 Control Tone PHONO | `wValue=0x0403` |
| Read | `bmRequestType=0xC0`, `wIndex=0x8002`, 6 bytes (option index per USB input) |

Values come from Pioneer’s own tables. The tool opens the device with IOKit (`IOUSBLib`, same path as Pioneer) and falls back to `IOUSBHost`. It never links the old x86 framework.

---

## Known limits

- **Routing write may not stick.** The tool can send the official SET and still read Cross Fader / MIC afterwards. That warning is real: DVS is not on. This is the current hard edge — not a fake success.
- **Not a new audio driver.** If routing shows `[DVS]` and Serato stays at 0%, the old Pioneer HAL driver is the next suspect. This repo will not rewrite it.
- **No firmware updates.** No flashing, no “repair”, no guessed vendor commands.
- **DDJ-SZ2 is a different product.** Different vendor ID, different software stack. Out of scope until its own official tables are found.

---

## Compatibility

| Item | Status |
|---|---|
| Pioneer DDJ-SZ (`VID 08e4`, `PID 0191`) | Supported (built-in profile) |
| Pioneer DDJ-SZ2 (`VID 2b73`, `PID 0016`) | Not in PioneerDDJSetup — `learn` cannot invent it |
| Other Pioneer-style mixers in that framework | Extractable; unverified live |
| macOS Tahoe + Apple Silicon | Intended target |
| Serato DJ Pro DVS on CH3 / CH4 | The feature this restores |
| Replacing Pioneer’s audio driver | Out of scope |

**Need:** macOS, DDJ-SZ on USB, Pioneer **DDJ-SZ USB audio** driver already installed (the one Serato uses), [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/).

**Tested and validated only on:** MacBook with Apple M3, macOS Tahoe 26.5.2, Pioneer DDJ-SZ, Serato DJ Pro 4.0.9. Other Macs, macOS versions, mixers or Serato builds are untested.

---

## License

MIT. See [LICENSE](LICENSE).

Pioneer, DDJ-SZ, Serato and related names are trademarks of their owners. This project is not affiliated with AlphaTheta / Pioneer DJ or Serato.

Use at your own risk. Only the normal Setting Utility routing is changed.

Made with love by Damien RICHARD / Kapweb.

---

## Français

**Le DDJ-SZ n’est pas mort. Pioneer a juste arrêté de le suivre.**

Table de mixage 4 voies, vrais préamps PHONO, deux platines DVS — le genre de machine qu’on ne jette pas. Sur un Mac actuel (Apple Silicon, macOS Tahoe), l’audio, le MIDI et le contrôleur marchent encore. Ce qui a cassé, c’est **un seul interrupteur** : les entrées USB CH3 / CH4 en **Control Tone PHONO**.

Sans ça, les aiguilles bougent, les VU hardware bougent, et le scope DVS de Serato reste à 0 %. Le vinyle parle. Le Mac écoute la mauvaise source.

L’ancien **DDJ-SZ Setting Utility** est Intel only. Sous Tahoe il affiche une erreur de configuration driver et ne peut plus changer le routage. Pioneer ne maintient plus cette pile. Ce projet est un petit outil natif macOS qui renvoie **les mêmes transfers USB officiels** que l’utilitaire — pour continuer à jouer sur ce matériel.

Pas de nouveau driver audio. Pas de Rosetta. Pas de lien contre `PioneerDDJSetup.framework`. Pas de valeurs USB inventées.

### Le problème

| Ça marche encore | Ça ne marche plus |
|---|---|
| Audio USB dans Serato | Scopes DVS decks 3 / 4 |
| MIDI / pads / platines | Setting Utility Pioneer (Intel, abandonné) |
| Préamp PHONO + VU hardware | Source USB coincée (souvent Cross Fader / MIC) |

Le DVS, ce n’est pas « le signal vinyle dans la table ». Ça, c’est déjà bon. C’est « la table doit copier **Control Tone PHONO** sur les voies USB que Serato écoute ». Cette copie était un vendor USB control, coincé dans un framework x86 que Pioneer ne livre plus pour Apple Silicon.

Cet outil restaure **ça**. Rien d’autre.

Si CH3/CH4 sont vraiment en Control Tone PHONO et que Serato reste muet, le reste est probablement l’ancien driver audio HAL Pioneer. Réécrire ce driver est hors sujet.

### Utilisation

```bash
xcode-select --install   # une fois, si clang / make manquent
make
./ddj-sz-routing status  # lecture du routage USB (aucune écriture)
./ddj-sz-routing         # DVS : CH3 + CH4 → Control Tone PHONO
```

Puis Serato → **Setup** → **CD/Vinyl**. Vinyle de contrôle sur une platine branchée en **CH3 PHONO** (et CH4 pour deux decks DVS). Tourner. Calibrer.

```bash
./ddj-sz-routing learn            # extraire les tables officielles, matcher l’USB branché
./ddj-sz-routing learn extract    # exporter tous les appareils encore décrits dans le framework
```

Relancer le binaire est sans danger. En pratique : après allumage du SZ, si le DVS est muet. Inutile si `status` montre déjà `[DVS]` sur CH3 et CH4.

Si tu vois `writes were sent but GET did not confirm` : le write USB est parti, la table n’a **pas** basculé. Ce n’est pas un succès. Relancer Serato ne suffit pas.

`learn` ne devine rien. Il lit les tables du framework officiel (`PioneerDDJSetup`). Ça couvre le SZ et quelques DJM de la même époque. **Pas le DDJ-SZ2** (`VID 0x2b73`) — autre produit, autre stack. On n’invente pas ses writes.

Prérequis : macOS, DDJ-SZ branché, driver audio Pioneer déjà installé, Command Line Tools (`clang`, `make`).

**Testé et validé uniquement sur :** Mac Apple M3, macOS Tahoe 26.5.2, Pioneer DDJ-SZ, Serato DJ Pro 4.0.9. Tout autre Mac, version de macOS, table ou build Serato n’a pas été testé.
