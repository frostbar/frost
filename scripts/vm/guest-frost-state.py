"""Print Frost's persisted state in the guest as one JSON object (for scripts/vm/vm-upgrade-test.sh).

Run inside the guest: /usr/bin/python3 -I guest-frost-state.py

- "cache": every entry of the image disk cache (~/Library/Caches/dev.frost.Frost/items/<stem>.json + .png): the
  file stem, bundle ID, identity key (None for entries written before identity keys existed, which have a window
  title instead), title, whether the PNG exists, and the capture / last-seen times.
- "titles": the window title last seen with each identity ("itemTitles.v1": bundle ID -> title -> key). Window titles
  are the apps' autosave names, the same in every Frost version, so they link the keys of two versions.
- "sections" / "known": the remembered sections ("itemSections.v2", else the title-keyed "itemSections.v1") and the
  seen icons ("knownItemIdentities.v2", else "knownItemIdentities"), as stored.
- "defaults": the other keys of the domain with short values (Preferred Positions, preferences).
Formats are read leniently: a version that stores something differently shows up as missing data, not as an error.
"""

import glob
import json
import os
import plistlib
import subprocess

DOMAIN = "dev.frost.Frost"
CACHE = os.path.expanduser("~/Library/Caches/dev.frost.Frost/items")


def read_defaults():
    output = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True).stdout
    try:
        return plistlib.loads(output) if output else {}
    except Exception:
        return {}


def decode(value):
    if isinstance(value, (bytes, bytearray)):
        try:
            return json.loads(value)
        except ValueError:
            return None
    return value


def main():
    defaults = read_defaults()
    cache = []
    for path in sorted(glob.glob(os.path.join(CACHE, "*.json"))):
        stem = os.path.basename(path)[: -len(".json")]
        try:
            with open(path, encoding="utf-8") as handle:
                metadata = json.load(handle)
        except (OSError, ValueError):
            metadata = {}
        cache.append({
            "stem": stem,
            "bundleID": metadata.get("bundleID"),
            "key": metadata.get("key"),
            "title": metadata.get("title"),
            "appearance": metadata.get("appearance"),
            "png": os.path.exists(os.path.join(CACHE, stem + ".png")),
            "capturedAt": metadata.get("capturedAt"),
            "lastSeen": metadata.get("lastSeen"),
        })
    orphans = [os.path.basename(p) for p in glob.glob(os.path.join(CACHE, "*.png"))
               if not os.path.exists(p[: -len(".png")] + ".json")]

    titles = {}
    for entry in decode(defaults.get("itemTitles.v1")) or []:
        if isinstance(entry, dict) and "title" in entry:
            titles.setdefault(entry.get("bundleID", "?"), {})[entry["title"]] = entry.get("key")

    sections = decode(defaults.get("itemSections.v2"))
    sections_format = "itemSections.v2"
    if sections is None:
        sections, sections_format = decode(defaults.get("itemSections.v1")), "itemSections.v1"
    known = decode(defaults.get("knownItemIdentities.v2"))
    if known is None:
        known = decode(defaults.get("knownItemIdentities"))

    short = {key: value for key, value in defaults.items()
             if isinstance(value, (str, int, float, bool)) and len(str(value)) < 200}
    print(json.dumps({
        "cache": cache,
        "orphanPNGs": orphans,
        "titles": titles,
        "sections": sections or [],
        "sectionsFormat": sections_format if sections else None,
        "known": known or [],
        "defaults": short,
    }, sort_keys=True, default=str))


main()
