#!/usr/bin/env python3
"""Merge a language's translations into Localizable.xcstrings.

Reads a JSON file of {english key: translation} and writes it into the catalog
under the given language code. Keys absent from the catalog are reported rather
than silently added, because a key that doesn't match the source exactly is a
translation that will never be used.

  python3 Tools/apply-translations.py bg Tools/translations/bg.json
"""
import json
import pathlib
import sys

CATALOG = pathlib.Path("FitnessTracker/Resources/Localizable.xcstrings")


def main(language: str, payload: pathlib.Path) -> int:
    catalog = json.loads(CATALOG.read_text())
    translations = json.loads(payload.read_text())

    unknown = [k for k in translations if k not in catalog["strings"]]
    applied = 0
    for key, value in translations.items():
        entry = catalog["strings"].get(key)
        if entry is None or not value:
            continue
        entry.setdefault("localizations", {})[language] = {
            "stringUnit": {"state": "translated", "value": value}
        }
        applied += 1

    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")

    total = len(catalog["strings"])
    done = sum(1 for e in catalog["strings"].values()
               if language in e.get("localizations", {}))
    print(f"{language}: applied {applied}, now {done}/{total} "
          f"({done * 100 // total}%)")
    if unknown:
        print(f"  {len(unknown)} keys not in the catalog:")
        for key in unknown[:10]:
            print(f"    {key!r}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], pathlib.Path(sys.argv[2])))
