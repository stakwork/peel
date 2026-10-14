#!/usr/bin/env python3
"""Judges a list journey from the probe files its drive wrote.

    scripts/journeys/evaluate.py <out dir> <drive file>

The drive file names what to judge in `// check:` lines, one per probe:

    // check: <probe> [hold=<list>] [land=<where>[@<list>]]

<list> is chat, thread or agent (land's defaults to chat). Each probe's
reference is its last frame before the first step taken while it ran
(for a reading row, the last such frame with a row in view).

- hold: the list must not move from the reference. At its end there, every
  frame must still be at its end (within 1 pt); scrolled up, the row at the
  top then (the reading row) must stay within 1 pt of where it was in every
  frame the list is shown, and never leave the rows laid out.
- land: the last frame must be at the list's `end`; at `divider` ("New
  messages" in the top third, or in view with the list at its end); at
  `target` (the message a jump or search went to, centred within 10% of
  the list's height or 24 pt); or at `anchor` (the reference's reading row
  back where it was, within 1 pt).
- Always: no blank frame (a list with rows hidden, or none in view) in
  any list, at any time.

Prints PASS or FAIL per check with the numbers; exits 1 if any failed.
"""
import json
import os
import re
import sys

MOVE = 1.0


def newest(sample, kind):
    lists = [entry for entry in sample["lists"] if entry["kind"] == kind]
    return max(lists, key=lambda entry: entry["list"]) if lists else None


def find(entry, row):
    for laid in entry["laidOut"]:
        if laid["row"] == row:
            return laid
    return None


def movement(reference, now, anchor):
    """How far the reading row moved on screen: by the row itself, else by
    any row laid out in both frames; None with neither."""
    laid = find(now, anchor["row"])
    if laid is not None:
        return laid["y"] - anchor["y"]
    for row in reference["laidOut"]:
        same = find(now, row["row"])
        if same is not None:
            return same["y"] - row["y"]
    return None


def judge(probe, options):
    samples = probe["samples"]
    if not samples:
        return False, ["no frames"]
    start = probe["events"][0]["t"] if probe["events"] else samples[0]["t"]
    before = [s for s in samples if s["t"] < start]
    reference = before[-1] if before else samples[0]
    after = [s for s in samples if s["t"] >= reference["t"]]
    ok, notes = True, []

    blank = {}
    for sample in samples:
        for entry in sample["lists"]:
            if entry["blank"]:
                blank[entry["kind"]] = blank.get(entry["kind"], 0) + 1
    if blank:
        ok = False
        notes.append("blank frames: " + ", ".join(f"{kind} {count}" for kind, count in sorted(blank.items())))

    def anchor_of(kind):
        # The reference's list, else (blank then) the nearest frame with a
        # row in view, before the steps first.
        for sample in [reference] + before[::-1] + after:
            entry = newest(sample, kind)
            if entry and entry.get("top"):
                return entry, entry["top"]
        return newest(reference, kind), None

    hold = options.get("hold")
    if hold:
        entry, anchor = anchor_of(hold)
        if entry is None:
            ok = False
            notes.append(f"no {hold} list at the start")
        elif entry["atEnd"]:
            off = [newest(s, hold)["below"] for s in after if newest(s, hold) and newest(s, hold)["below"] > MOVE]
            if off:
                ok = False
                notes.append(f"left its end in {len(off)} frames, by up to {max(off):,.0f} pt")
            else:
                notes.append("held at its end")
        elif anchor is None:
            ok = False
            notes.append(f"no reading row in {hold} at the start")
        else:
            moved, lost, absent, worst, lists, rows = 0, 0, 0, 0.0, {entry["list"]}, set()
            for sample in after:
                now = newest(sample, hold)
                if now is None:
                    absent += 1
                    continue
                lists.add(now["list"])
                shift = movement(entry, now, anchor)
                if shift is None:
                    lost += 1
                    if now.get("top"):
                        rows.add(now["top"]["index"])
                    if now["list"] != entry["list"]:
                        # Another list's content: its offset says nothing.
                        continue
                    # The reading row and every row around it are gone: by
                    # how far the view's top moved in the content.
                    shift = entry["offset"] - now["offset"]
                worst = max(worst, abs(shift))
                if abs(shift) > MOVE:
                    moved += 1
            if moved or lost:
                ok = False
            parts = [f"reading row (row {anchor['index']}) moved up to {worst:,.0f} pt in {moved} frames"]
            if lost:
                away = f", the list at rows {min(rows)}-{max(rows)}" if rows else ""
                parts.append(f"out of the rows laid out in {lost} frames{away}")
            if absent:
                parts.append(f"list gone {absent} frames")
            if len(lists) > 1:
                parts.append(f"list made again {len(lists) - 1}x")
            notes.append(", ".join(parts))

    land = options.get("land")
    if land:
        where, _, kind = land.partition("@")
        kind = kind or "chat"
        last = newest(samples[-1], kind)
        if last is None:
            ok = False
            notes.append(f"no {kind} list at the end")
        elif where == "end":
            if last["below"] > MOVE:
                ok = False
                notes.append(f"{kind} ended {last['below']:,.0f} pt short of its end")
            else:
                notes.append(f"{kind} landed at its end")
        elif where == "divider":
            divider = last.get("divider")
            if divider is None:
                ok = False
                notes.append("New messages not laid out at the end")
            elif 0 <= divider["y"] <= last["container"] / 3 or (last["atEnd"] and 0 <= divider["y"] < last["container"]):
                notes.append(f"New messages at {divider['y']:,.0f} pt")
            else:
                ok = False
                notes.append(f"New messages at {divider['y']:,.0f} pt of {last['container']:,.0f}")
        elif where == "target":
            target = last.get("target")
            if target is None:
                ok = False
                at = f", the list at row {last['top']['index']}" if last.get("top") else ""
                if "targetIndex" in last:
                    notes.append(f"stopped short: target (row {last['targetIndex']}) not laid out at the end{at}")
                else:
                    notes.append(f"never went: the target is not among the list's rows{at}")
            else:
                off = target["y"] + target["height"] / 2 - last["container"] / 2
                if abs(off) > max(24, last["container"] * 0.1):
                    ok = False
                    notes.append(f"target {off:+,.0f} pt from the centre")
                else:
                    notes.append(f"target centred ({off:+,.0f} pt)")
        elif where == "anchor":
            entry, anchor = anchor_of(kind)
            if entry is None or anchor is None:
                ok = False
                notes.append(f"no reading row in {kind} at the start")
            else:
                shift = movement(entry, last, anchor)
                if shift is None:
                    ok = False
                    notes.append(f"reading row (row {anchor['index']}) not laid out at the end"
                                 + (f", the list at row {last['top']['index']}" if last.get("top") else "")
                                 + f", {entry['offset'] - last['offset']:+,.0f} pt in the content")
                elif abs(shift) > MOVE:
                    ok = False
                    notes.append(f"reading row {shift:+,.0f} pt from where it was")
                else:
                    notes.append("back at the reading row")
    return ok, notes


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: scripts/journeys/evaluate.py <out dir> <drive file>")
    out, drive = sys.argv[1], sys.argv[2]
    checks = []
    with open(drive) as file:
        for line in file:
            found = re.match(r"\s*//\s*check:\s*(\S+)(.*)", line)
            if found:
                options = dict(part.split("=", 1) for part in found.group(2).split())
                checks.append((found.group(1), options))
    if not checks:
        sys.exit(f"no // check: line in {drive}")
    failed = False
    for name, options in checks:
        path = os.path.join(out, f"{name}.probe.json")
        if not os.path.exists(path):
            print(f"FAIL {name}: no probe written (see drive.log)")
            failed = True
            continue
        with open(path) as file:
            ok, notes = judge(json.load(file), options)
        print(f"{'PASS' if ok else 'FAIL'} {name}: " + "; ".join(notes))
        failed |= not ok
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
