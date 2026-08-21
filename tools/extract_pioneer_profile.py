#!/usr/bin/env python3
"""Extract Pioneer mixer-select profiles from PioneerDDJSetup.framework.

Parses the Mach-O data tables (not an otool disassembly). Values are those
the official Setting Utility would send. No USB writes are performed.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys

DEFAULT_BINARY = (
    "/Library/Frameworks/PioneerDDJSetup.framework/Versions/A/PioneerDDJSetup"
)

# From _CheckUSBAudio / Get* tables in PioneerDDJSetup x86_64.
# VID is always 0x08e4 in that framework.
KNOWN_DEVICES = [
    {
        "name": "DJM-900nexus",
        "vendor_id": 0x08E4,
        "product_id": 0x0158,
        "text": "_DJM800NEXT_TEXT",
        "conv": "__convTable_900plus",
        "channels": 4,
        "text_stride": 8,
        "conv_stride": 8,
        "get_length": 5,
    },
    {
        "name": "DJM-T1",
        "vendor_id": 0x08E4,
        "product_id": 0x015E,
        "text": "_DJMMID_TEXT",
        "conv": "__convTable_MID",
        "channels": 3,
        "text_stride": 6,
        "conv_stride": 6,
        "get_length": 3,
    },
    {
        "name": "DJM-900SRT",
        "vendor_id": 0x08E4,
        "product_id": 0x0188,
        "text": "_DJM900SRT_TEXT",
        "conv": "__convTable_900SRT",
        "channels": 4,
        "text_stride": 8,
        "conv_stride": 8,
        "get_length": 6,
    },
    {
        "name": "Pioneer DDJ-SZ",
        "vendor_id": 0x08E4,
        "product_id": 0x0191,
        "text": "_DDJSZ_TEXT",
        "conv": "__convTable_SZ",
        "channels": 5,
        "text_stride": 10,
        "conv_stride": 8,
        "get_length": 6,
    },
]


def read_file(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


def fat_slice_x86_64(data: bytes) -> bytes:
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        nfat = struct.unpack(">I", data[4:8])[0]
        for i in range(nfat):
            off = 8 + i * 20
            cputype, _, offset, size, _ = struct.unpack(">IIIII", data[off : off + 20])
            if cputype == 0x01000007:
                return data[offset : offset + size]
        raise SystemExit("no x86_64 slice in binary")
    if struct.unpack("<I", data[:4])[0] == 0xFEEDFACF:
        return data
    raise SystemExit("unsupported Mach-O / fat magic")


def parse_sections(mach: bytes) -> list[tuple[str, int, int, int]]:
    _magic, _cputype, _cpusub, _ftype, ncmds, _sz, _flags, _res = struct.unpack(
        "<IIIIIIII", mach[:32]
    )
    pos = 32
    sections: list[tuple[str, int, int, int]] = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", mach, pos)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", mach, pos + 64)[0]
            sp = pos + 72
            for _s in range(nsects):
                sectname = mach[sp : sp + 16].split(b"\x00", 1)[0].decode()
                addr, size, fileoff = struct.unpack_from("<QQI", mach, sp + 32)
                sections.append((sectname, addr, size, fileoff))
                sp += 80
        pos += cmdsize
    return sections


def vm_to_off(sections, addr: int) -> int:
    for _name, saddr, ssize, soff in sections:
        if saddr <= addr < saddr + ssize:
            return soff + (addr - saddr)
    raise KeyError(f"address 0x{addr:x} not in a mapped section")


def parse_symbols(mach: bytes) -> dict[str, int]:
    _magic, _cputype, _cpusub, _ftype, ncmds, _sz, _flags, _res = struct.unpack(
        "<IIIIIIII", mach[:32]
    )
    pos = 32
    symoff = nsyms = stroff = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", mach, pos)
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, _strsize = struct.unpack_from("<IIII", mach, pos + 8)
        pos += cmdsize
    symbols = {}
    for i in range(nsyms):
        n_strx, _type, _sect, _desc, n_value = struct.unpack_from(
            "<IBBHQ", mach, symoff + i * 16
        )
        name = mach[stroff + n_strx :].split(b"\x00", 1)[0].decode("utf-8", "replace")
        if name:
            symbols[name] = n_value
    return symbols


def read_cstr(mach: bytes, addr: int) -> str | None:
    if addr <= 0 or addr >= len(mach):
        return None
    end = mach.find(b"\x00", addr)
    return mach[addr:end].decode("utf-8", "replace")


def cfstring_at(mach: bytes, addr: int) -> str | None:
    if addr + 32 > len(mach):
        return None
    _isa, _flags, strp, _length = struct.unpack_from("<QqQq", mach, addr)
    return read_cstr(mach, strp)


def load_input_audio_text(mach: bytes, sections, symbols: dict[str, int]) -> list[str]:
    base = symbols["_InputAudioText"]
    off = vm_to_off(sections, base)
    labels = []
    for i in range(64):
        ptr = struct.unpack_from("<Q", mach, off + i * 8)[0]
        text = cfstring_at(mach, ptr)
        if text is None:
            break
        labels.append(text)
    return labels


def extract_device(mach, sections, symbols, labels, spec: dict) -> dict:
    text_off = vm_to_off(sections, symbols[spec["text"]])
    conv_off = vm_to_off(sections, symbols[spec["conv"]])
    slots = []
    dvs = []
    none_index = labels.index("None") if "None" in labels else -1

    for channel in range(spec["channels"]):
        options = []
        for opt in range(spec["text_stride"]):
            text_idx = struct.unpack_from("<i", mach, text_off + (channel * spec["text_stride"] + opt) * 4)[0]
            if text_idx < 0 or text_idx >= len(labels):
                continue
            if none_index >= 0 and text_idx == none_index:
                continue
            name = labels[text_idx]
            if name == "None":
                continue
            wvalue = struct.unpack_from(
                "<H", mach, conv_off + (channel * spec["conv_stride"] + opt) * 2
            )[0]
            options.append({"index": opt, "label": name, "wValue": f"0x{wvalue:04x}"})

        slot_id = "USB 9-10" if channel == 4 else f"CH{channel + 1}"
        slots.append({"id": slot_id, "labels": [item["label"] for item in options]})

        phono = next((item for item in options if "Control Tone PHONO" in item["label"]), None)
        if phono is None:
            phono = next((item for item in options if "Timecode PHONO" in item["label"]), None)
        if phono:
            label = phono["label"]
            if label.startswith("CH") and " " in label:
                label = label.split(" ", 1)[1]
            dvs.append(
                {
                    "slot": slot_id,
                    "label": label,
                    "wValue": phono["wValue"],
                    "expect_index": phono["index"],
                }
            )

    return {
        "name": spec["name"],
        "vendor_id": f"0x{spec['vendor_id']:04x}",
        "product_id": f"0x{spec['product_id']:04x}",
        "protocol": "pioneer_mixer_select",
        "source": "PioneerDDJSetup.framework",
        "get": {
            "bmRequestType": "0xC0",
            "bRequest": "0x00",
            "wValue": "0x0000",
            "wIndex": "0x8002",
            "wLength": spec["get_length"],
            "channel_byte_offset": 1,
        },
        "set": {
            "bmRequestType": "0x40",
            "bRequest": "0x03",
            "wIndex": "0x8002",
            "wLength": 0,
        },
        "firmware": {
            "bmRequestType": "0xC0",
            "bRequest": "0x00",
            "wValue": "0x0000",
            "wIndex": "0x8001",
            "wLength": 2,
        },
        "slots": slots,
        "dvs": dvs,
    }


def extract_all(binary_path: str) -> list[dict]:
    mach = fat_slice_x86_64(read_file(binary_path))
    sections = parse_sections(mach)
    symbols = parse_symbols(mach)
    required = ["_InputAudioText"] + [d["text"] for d in KNOWN_DEVICES] + [d["conv"] for d in KNOWN_DEVICES]
    missing = [name for name in required if name not in symbols]
    if missing:
        raise SystemExit(f"missing symbols: {', '.join(missing)}")
    labels = load_input_audio_text(mach, sections, symbols)
    return [extract_device(mach, sections, symbols, labels, spec) for spec in KNOWN_DEVICES]


def search_binaries() -> list[str]:
    candidates = [DEFAULT_BINARY]
    extra_roots = [
        "/Library/Frameworks",
        "/Applications/Pioneer",
        "/Applications",
    ]
    for root in extra_roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
            for name in filenames:
                lower = name.lower()
                if "pioneerddjsetup" in lower or "ddjsetup" in lower:
                    candidates.append(os.path.join(dirpath, name))
            if dirpath.count(os.sep) - root.count(os.sep) > 5:
                dirnames.clear()
    seen = set()
    unique = []
    for path in candidates:
        if os.path.isfile(path) and path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=DEFAULT_BINARY, help="PioneerDDJSetup binary")
    parser.add_argument("--pid", help="only emit this product id (e.g. 0x0191)")
    parser.add_argument("--list", action="store_true", help="list recovered devices")
    parser.add_argument("--search", action="store_true", help="search typical Pioneer install paths")
    args = parser.parse_args()

    binaries = search_binaries() if args.search else [args.binary]
    profiles: list[dict] = []
    errors: list[str] = []
    for path in binaries:
        try:
            profiles.extend(extract_all(path))
        except SystemExit as exc:
            errors.append(f"{path}: {exc}")
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{path}: {exc}")

    if args.pid:
        wanted = int(args.pid, 0)
        profiles = [p for p in profiles if int(p["product_id"], 0) == wanted]

    if args.list:
        for profile in profiles:
            dvs = ", ".join(f"{e['slot']}={e['wValue']}" for e in profile.get("dvs", []))
            print(f"{profile['name']}  {profile['vendor_id']}:{profile['product_id']}  DVS[{dvs}]")
        if errors:
            print("warnings:", file=sys.stderr)
            for line in errors:
                print(f"  {line}", file=sys.stderr)
        return 0 if profiles else 1

    json.dump(profiles if not args.pid else (profiles[0] if profiles else {}), sys.stdout, indent=2)
    sys.stdout.write("\n")
    if not profiles:
        for line in errors:
            print(line, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
