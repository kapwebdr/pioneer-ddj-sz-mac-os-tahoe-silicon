# ddj-sz-routing

Native macOS CLI that restores **Serato DVS routing** on a Pioneer **DDJ-SZ**.

On current macOS (including Apple Silicon / macOS Tahoe), Pioneer’s old DDJ-SZ Setting Utility no longer works. Audio, MIDI and the controller still work, but USB inputs CH3/CH4 are not switched to **Control Tone PHONO**. Serato then shows a dead DVS scope even though the hardware PHONO preamp and the deck VU meter are fine.

This tool sends the same USB vendor control transfers that the official Setting Utility used to send. It does **not** replace the audio driver, does **not** use Rosetta, and does **not** link against `PioneerDDJSetup.framework`.

**Default action: set CH3 and CH4 to Control Tone PHONO.**

---

## Why this exists

- The DDJ-SZ is otherwise usable under modern macOS + Serato DJ Pro.
- DVS (Control Vinyl / Control CD) needs the mixer to route the timecode signal into the USB inputs Serato listens to.
- Pioneer only shipped that setting in an Intel-only utility / framework. Under Tahoe the utility reports a driver-configuration error and cannot change the routing.
- Replacing the whole Pioneer USB audio driver would be fragile and is out of scope.
- If CH3/CH4 can be set to Control Tone PHONO again, DVS works with the hardware you already own.

This project is a small, native ARM64-friendly utility for that one setting. Nothing else.

---

## What it does

| Command | Effect |
|---|---|
| `ddj-sz-routing` or `ddj-sz-routing dvs` | Apply the DVS writes from the connected device profile (CH3+CH4 on a DDJ-SZ) |
| `ddj-sz-routing status` | Read and print the current USB input routing |
| `ddj-sz-routing learn` | Guided wizard to snapshot a device and save a per-device profile |
| `ddj-sz-routing help` | Show usage |

The DDJ-SZ profile is built in (`VID 0x08E4`, `PID 0x0191`). Other controllers can be added as JSON profiles. The tool does not flash firmware and does not invent USB writes.

---

## Prerequisites

- macOS on Apple Silicon or Intel (native build, no Rosetta)
- A Pioneer **DDJ-SZ** connected over USB
- Pioneer **DDJ-SZ USB audio driver** already installed (the same one Serato uses)
- [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) (`clang`, `make`)
- Serato DJ Pro if you want to verify DVS after applying the routing

Root is not required in the usual case. Close Serato first if the USB request is rejected.

---

## Build

```bash
xcode-select --install   # if clang / make are missing
make
```

This produces a native binary named `ddj-sz-routing` (`arm64` on Apple Silicon, `x86_64` on Intel).

Optional install:

```bash
sudo make install        # copies to /usr/local/bin
# or
make install PREFIX="$HOME/.local"
```

Check the binary:

```bash
file ./ddj-sz-routing
# expected on Apple Silicon: Mach-O 64-bit executable arm64
```

---

## Usage

The DDJ-SZ can use **CH3 and CH4** as DVS decks. This tool always sets **both**.

### Apply DVS routing

1. Power on the DDJ-SZ and plug it into the Mac over USB.
2. Quit Serato DJ Pro if it is open (safer; not always required).
3. From the project directory:

```bash
./ddj-sz-routing
```

That is the default command. `./ddj-sz-routing dvs` does the same thing.

4. Open Serato DJ Pro → **Setup** → **CD/Vinyl**.
5. Put a Serato Control Vinyl on a deck wired to **CH3 PHONO** (and CH4 if you use two DVS decks).
6. Start the platter and check the scope / run calibration on decks 3 and 4.

On success the tool prints `[DVS]` next to CH3 and CH4.

### Check current routing (no write)

```bash
./ddj-sz-routing status
```

Use this to see whether CH3/CH4 are already on Control Tone PHONO, or after a reboot to see if the setting survived.

### When to run it again

You do **not** need a login item or a launch daemon.

- Running the tool several times is safe. It writes the same two values again (idempotent). No firmware change, no stacked settings.
- If the **DDJ-SZ stays powered** (its own PSU) while the Mac reboots, the routing often stays put. You can confirm with `status`.
- If the **controller is powered off**, unplugged, or loses USB power, it usually falls back to a non-DVS USB source. Serato’s scopes go silent even though the hardware VU still moves. Run `./ddj-sz-routing` again after the SZ is back.
- Practical rule: run it when you power up the DDJ-SZ and DVS is dead. Skip it when `status` already shows `[DVS]` on CH3 and CH4.

### Learn / generate a profile from Pioneer’s official tables

`learn` does **not** guess USB values and does **not** need an `otool` disassembly dump. It reads the same Mach-O tables that `otool -arch x86_64 -tvV` would only show as code: `__convTable_*`, `_*_TEXT`, `_InputAudioText`.

On this Mac that file is usually:

`/Library/Frameworks/PioneerDDJSetup.framework/Versions/A/PioneerDDJSetup`

```bash
./ddj-sz-routing learn            # extract tables, match the plugged-in device, write its profile
./ddj-sz-routing learn extract    # write a profile for every device found in the framework
```

Steps (English):

1. Parse PioneerDDJSetup (x86_64 slice, works on Apple Silicon — no Rosetta).
2. List recovered devices and their official DVS `wValue`s.
3. If a connected USB device matches (VID/PID), that profile is saved automatically.
4. Optional read-only GET against the live controller.

Profiles:

- bundled example: `profiles/ddj-sz.json`
- generated: `~/Library/Application Support/ddj-sz-routing/profiles/<vid>_<pid>.json`

The extractor lives in `tools/extract_pioneer_profile.py` if you want JSON on stdout:

```bash
python3 tools/extract_pioneer_profile.py --list
python3 tools/extract_pioneer_profile.py --pid 0x0191
```

**What this can generate:** devices actually described in PioneerDDJSetup — DDJ-SZ, DJM-900nexus, DJM-T1, DJM-900SRT (`VID 0x08e4`). Only the DDJ-SZ path is verified live.

**What this cannot generate:** a DDJ-SZ2 profile. SZ2 is `VID 0x2b73` / `PID 0x0016` and is **not** in PioneerDDJSetup. Dumping that old framework again will never invent SZ2 writes. You would need that product’s own setup binary, then extend the extractor. Do not type random hex.

### If something fails

- `No profiled controller found` — nothing matching a known JSON profile is plugged in. Connect a DDJ-SZ, or run `learn`.
- USB control transfer error — quit Serato and retry. Root is rarely needed.
- Tool reports `[DVS]` but Serato still shows 0% — routing is done; the leftover issue is likely the old Pioneer audio driver, which this project will not replace.

---

## How it works

Pioneer’s Setting Utility configured USB input sources with a vendor control transfer:

- write: `bmRequestType=0x40`, `bRequest=0x03`, `wIndex=0x8002`, `wLength=0`
- CH3 Control Tone PHONO: `wValue=0x0303`
- CH4 Control Tone PHONO: `wValue=0x0403`

A matching GET (`bmRequestType=0xC0`, `wIndex=0x8002`, 6 bytes) reads the current option index for each USB input.

Those values come from the official Pioneer tables (`__convTable_SZ`, `_DDJSZ_TEXT`). This tool does not invent USB payloads.

On macOS it opens the device with IOKit (`IOUSBLib`, same path as Pioneer) and falls back to `IOUSBHost` if needed. It never loads the old x86 framework.

---

## Compatibility

| Item | Status |
|---|---|
| Pioneer DDJ-SZ (`VID 08e4`, `PID 0191`) | Supported (built-in profile) |
| Pioneer DDJ-SZ2 (`VID 2b73`, `PID 0016`) | Not in PioneerDDJSetup — `learn` cannot invent this profile |
| Other Pioneer-style mixers | Possible via JSON profile; protocol must be verified first |
| macOS Tahoe + Apple Silicon | Intended target |
| Serato DJ Pro DVS on CH3 / CH4 | The feature this restores |
| Replacing Pioneer’s audio driver | Explicitly out of scope |

If the tool confirms Control Tone PHONO on CH3/CH4 and Serato still shows 0% / no noise map, the remaining issue is likely the old Pioneer HAL driver on that macOS version. This project will not rewrite that driver.

---

## License

MIT. See [LICENSE](LICENSE).

Pioneer, DDJ-SZ, Serato and related names are trademarks of their owners. This project is not affiliated with AlphaTheta / Pioneer DJ or Serato.

Use at your own risk. Only the normal Setting Utility routing is changed.

---

## Français

Sur macOS récent, l’ancien DDJ-SZ Setting Utility (Intel) ne peut plus basculer CH3/CH4 en **Control Tone PHONO**. Le contrôleur et l’audio marchent, mais le DVS Serato reste muet.

`ddj-sz-routing` est un binaire natif (sans Rosetta) qui applique **directement CH3 et CH4** en Control Tone PHONO, avec les mêmes transfers USB que l’utilitaire officiel.

```bash
make
./ddj-sz-routing          # applique le profil DVS (CH3 + CH4 sur SZ)
./ddj-sz-routing status   # lecture
./ddj-sz-routing learn    # assistant profil (GET only, writes confirmées)
```

Relancer le binaire est sans danger. En général on le relance après allumage du DDJ-SZ si le DVS est muet.

Prérequis : macOS, contrôleur branché, driver audio Pioneer, Command Line Tools (`clang`, `make`).
