#!/usr/bin/env python3
"""Every interface string in the Swift sources has a translation in each Localizable.strings.

The keys are the English text as written in the code: string literals given to SwiftUI views
(Text, Button, Toggle, Picker, Section, Tab, SecureField, help, CommandMenu, Window,
LocalizedStringKey) and String(localized:). An interpolation \\(...) becomes %@ in the key.
`--write-en` regenerates en.lproj from the keys. Exits 1 and lists what is missing.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
LOCALES = ["en", "zh-Hant", "zh-Hans"]
CALL = re.compile(r'(?:String\(localized:|LocalizedStringKey\(|\b(?:Text|Button|Toggle|Picker|Section|Tab|SecureField|CommandMenu|Window|Label|LabeledContent|TextField|ColorPicker|Link)\(|\.help\(|\.alert\()\s*"((?:[^"\\]|\\.)*)"')


def keys():
    found = set()
    for path in SOURCES.rglob("*.swift"):
        for m in CALL.finditer(path.read_text()):
            found.add(re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "%@", m.group(1)).replace('\\"', '"'))
    return found


def read_strings(path):
    if not path.exists():
        return {}
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(), re.M)
    return {k.replace('\\"', '"'): v for k, v in pairs}


def main():
    wanted = keys()
    if "--write-en" in sys.argv:
        esc = lambda s: s.replace('"', '\\"')
        lines = [f'"{esc(k)}" = "{esc(k)}";' for k in sorted(wanted)]
        out = ROOT / "Resources/en.lproj/Localizable.strings"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("/* English: generated from the code by scripts/check-strings.py --write-en */\n" + "\n".join(lines) + "\n")
    missing = 0
    for loc in LOCALES:
        have = read_strings(ROOT / f"Resources/{loc}.lproj/Localizable.strings")
        for k in sorted(wanted - have.keys()):
            print(f"{loc}: missing {k!r}")
            missing += 1
        for k in sorted(have.keys() - wanted):
            print(f"{loc}: unused {k!r}")
    print(f"{len(wanted)} keys, {missing} missing")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
