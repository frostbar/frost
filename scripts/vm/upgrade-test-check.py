"""Assertions of scripts/vm/vm-upgrade-test.sh, run on the host over the JSON the guest probes printed.

  python3 -I upgrade-test-check.py seed RUN_DIR --expect visible=A,B hidden=C always-hidden=D
      The previous release ran with the seeded layout: every seeded item is in its section (old-sections.json) and the
      previous release stored state and cached images (old-state.json). A failure here is a test setup problem.
  python3 -I upgrade-test-check.py upgrade RUN_DIR --live FILiveHelp,FILiveDesc --grace 60 --pid PID
      The build under test kept the layout and migrated the stored state (new-sections.json, new-state.json,
      new-log.txt against the old-*.json files).

Prints one line per finding ("FAIL ...", "ok ...", "note ...") and exits 1 when any check failed.

Items are matched across versions by window title (the apps' autosave names, e.g. FIExtra0): they are the same in
every Frost version, while identity keys changed format between versions. The window title last seen with each key is
in Frost's "itemTitles.v1"; entries from before identity keys existed carry the title themselves.
"""

import argparse
import datetime
import json
import os
import re
import sys

failures = []


def fail(message):
    failures.append(message)
    print(f"FAIL {message}")


def ok(message):
    print(f"ok   {message}")


def note(message):
    print(f"note {message}")


def load(run_dir, name):
    with open(os.path.join(run_dir, name), encoding="utf-8") as handle:
        return json.load(handle)


def without_digits(key):
    return re.sub(r"\d+", "#", key or "")


def titled_cache(state):
    """Cache entries with the window title of their item (None when the state doesn't say).

    The title map holds the key each item had last, so an entry cached under an earlier live number (FILiveDesc at
    another temperature) is matched to the one item of its app whose last key differs from it only in digits.
    """
    by_key, by_loose = {}, {}
    for bundle, titles in state.get("titles", {}).items():
        for title, key in titles.items():
            by_key[(bundle, key)] = title
            by_loose.setdefault((bundle, without_digits(key)), set()).add(title)
    entries = []
    for entry in state.get("cache", []):
        bundle, key = entry.get("bundleID"), entry.get("key")
        title = entry.get("title") or by_key.get((bundle, key))
        if title is None and len(by_loose.get((bundle, without_digits(key)), ())) == 1:
            (title,) = by_loose[(bundle, without_digits(key))]
        entries.append(dict(entry, itemTitle=title))
    return entries


def check_seed(args):
    sections = load(args.run_dir, "old-sections.json")["sections"]
    state = load(args.run_dir, "old-state.json")
    for spec in args.expect:
        section, _, names = spec.partition("=")
        for name in filter(None, names.split(",")):
            actual = sections.get(name)
            if actual != section:
                fail(f"seeded layout: {name} is {actual or 'missing'}, expected {section}")
    if not failures:
        ok(f"seeded layout in place under the previous release ({len(sections)} items)")
    fake = [e for e in titled_cache(state) if (e.get("bundleID") or "").startswith("dev.frost.FakeItems") and e["png"]]
    if not fake:
        fail("the previous release cached no images of the test items (Screen Recording missing, or the Frost Bar "
             "didn't open?)")
    else:
        ok(f"the previous release cached {len(fake)} image(s) of test items")
    if not state.get("sections"):
        fail("the previous release stored no remembered sections")
    else:
        ok(f"the previous release remembered {len(state['sections'])} section(s) ({state.get('sectionsFormat')})")


def check_sections(old, new):
    old_sections, new_sections = old["sections"], new["sections"]
    moved = []
    for title, section in sorted(old_sections.items()):
        if title not in new_sections:
            fail(f"section: {title} ({section}) is no longer in the menu bar")
        elif new_sections[title] != section:
            moved.append(title)
            fail(f"section: {title} moved from {section} to {new_sections[title]}")
    for title in sorted(set(new_sections) - set(old_sections)):
        note(f"section: {title} ({new_sections[title]}) is new in the menu bar")
    if not moved and all(t in new_sections for t in old_sections):
        counts = {}
        for section in old_sections.values():
            counts[section] = counts.get(section, 0) + 1
        ok("sections unchanged: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))


def check_windows(new):
    if new.get("windows"):
        fail(f"Frost window(s) open after the upgrade (onboarding or Settings reappeared?): {new['windows']}")
    else:
        ok("no Frost window opened by itself (onboarding didn't reappear)")


def check_cache(old_state, new_state, live):
    old_entries, new_entries = titled_cache(old_state), titled_cache(new_state)
    new_titles = new_state.get("titles", {})
    new_stems = {e["stem"] for e in new_entries}
    present = {(e.get("bundleID"), e.get("key")) for e in new_entries if e["png"]}
    unchanged = migrated = stale = 0
    for entry in old_entries:
        bundle, title = entry.get("bundleID"), entry.get("itemTitle")
        if not entry["png"] or not bundle or not bundle.startswith("dev.frost.FakeItems"):
            continue
        if title is None:
            note(f"cache: old entry {entry['stem']} has no known item; not checked")
            continue
        new_key = new_titles.get(bundle, {}).get(title)
        if new_key is None:
            note(f"cache: the build under test never recorded {title}; its old entry is not checked")
            continue
        old_key = entry.get("key")
        has_image = (bundle, new_key) in present
        if old_key == new_key:
            unchanged += 1
            if not has_image:
                fail(f"cache: the image of {title} (key unchanged) is gone")
            continue
        left_over = entry["stem"] in new_stems
        if title in live:
            # A live number in the key: the old entry can only be moved while the item shows the number it had when
            # it was captured, so an entry left under it is expected; the item is captured again under its new key.
            if left_over:
                stale += 1
            if not has_image:
                note(f"cache: {title} (live numbers) has no image under its new key yet")
            continue
        if left_over:
            fail(f"cache: {title}'s image is still under its old key {old_key!r} (stem {entry['stem']}), not "
                 f"migrated to {new_key!r}")
        elif not has_image:
            fail(f"cache: {title}'s image under the old key {old_key!r} is gone but none exists under {new_key!r}")
        else:
            migrated += 1
    orphans = new_state.get("orphanPNGs") or []
    if orphans:
        fail(f"cache: {len(orphans)} image(s) without metadata: {orphans[:5]}")
    summary = (f"{len(old_entries)} entries before, {len(new_entries)} after; {migrated} moved to new keys, "
               f"{unchanged} unchanged, {stale} stale live-number entries left (expected)")
    if any(m.startswith("cache:") for m in failures):
        note("cache: " + summary)
    else:
        ok("cache migrated: " + summary)


LOG_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) +\S+ +Frost\[(\d+):")


def check_log(run_dir, pid, grace):
    with open(os.path.join(run_dir, "new-log.txt"), encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    start = None
    churn = []
    presented = refreshed = False
    for line in lines:
        match = LOG_LINE.match(line)
        if not match or (pid and match.group(2) != str(pid)):
            continue
        time = datetime.datetime.strptime(match.group(1)[:23], "%Y-%m-%d %H:%M:%S.%f")
        if start is None and re.search(r"Frost \S+ launched", line):
            start = time
        if "remembered section(s) to the items' current identities" in line:
            churn.append((time, line))
        presented |= "Frost Bar presented" in line
        refreshed |= "live refresh cycle:" in line
    if start is None:
        fail("log: no 'Frost … launched' line from the build under test (did it start?)")
        return
    late = [(t, l) for t, l in churn if (t - start).total_seconds() > grace]
    early = len(churn) - len(late)
    if late:
        fail(f"log: remembered sections re-keyed {len(late)} time(s) after the first {grace:.0f} s (churn), e.g. "
             f"+{(late[0][0] - start).total_seconds():.0f} s: {late[0][1].split('] ', 1)[-1]}")
    else:
        ok(f"no section re-keying after the first {grace:.0f} s ({early} migration message(s) before)")
    if not presented:
        fail("log: the Frost Bar didn't open after the upgrade (click on the snowflake not handled?)")
    elif not refreshed:
        fail("log: the Frost Bar opened but never refreshed its images (Screen Recording or Accessibility missing "
             "after the upgrade?)")
    else:
        ok("the Frost Bar opened and refreshed its images (Accessibility and Screen Recording in effect)")


def check_upgrade(args):
    old, new = load(args.run_dir, "old-sections.json"), load(args.run_dir, "new-sections.json")
    check_sections(old, new)
    check_windows(new)
    check_cache(load(args.run_dir, "old-state.json"), load(args.run_dir, "new-state.json"),
                set(filter(None, args.live.split(","))))
    check_log(args.run_dir, args.pid, args.grace)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    seed = sub.add_parser("seed")
    seed.add_argument("run_dir")
    seed.add_argument("--expect", nargs="+", default=[])
    upgrade = sub.add_parser("upgrade")
    upgrade.add_argument("run_dir")
    upgrade.add_argument("--live", default="")
    upgrade.add_argument("--grace", type=float, default=60)
    upgrade.add_argument("--pid", default="")
    args = parser.parse_args()
    (check_seed if args.command == "seed" else check_upgrade)(args)
    sys.exit(1 if failures else 0)


main()
