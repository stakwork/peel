#!/usr/bin/env python3
"""Judges a list journey from the probe files its drive wrote.

    scripts/journeys/evaluate.py <out dir> <drive file>

The drive file names what to judge in `// check:` lines, one per probe:

    // check: <probe> [hold=<list>] [land=<where>[@<list>]] [from=grow|resize] [more=<n>] [narrows=<s>]

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
  the list's height or 24 pt, or wholly in view in a list too
  short to scroll); or at `anchor` (the reference's reading row
  back where it was, within 1 pt).
- from=grow: the reference is instead the last frame before the held
  list's rows first grew (older history arriving), not before the first step.
- from=arrive: the last frame before the newest row laid out in the held
  list became another (a message arriving), after the first step.
- from=resize: the last frame before a row laid out in the held list
  changed height (a picture sizing itself late), after the first step.
- more: the last frame's list (the held one, else the chat) has over <n> rows.
- still=target: from the reference, the message gone to (a jump's target)
  stays within 1 pt of where it was, in every frame it is laid out.
- keep=<n>[@<list>]: the row <n>th from the newest laid out at the
  reference (1, the newest) keeps its top within 1 pt in every frame it
  is laid out, and is still there at the end (the same row, not one in
  its place); with opens=yes, it is also taller at the end (opened in place).
- narrows: the chat's list narrows once in all, no sooner than <s> seconds
  after the first step (the panel's slide in ended first).
- overscroll=bottom|top[@<list>]: the drive's `overscroll` step pushed the
  list past that end and let go. From the reference, how far past it is
  must grow with the push, frame by frame, to within 10% of the push, then
  shrink back, never once moving against the gesture or the ease back (by
  over 0.5 pt) nor more than 12 pt in a frame; the last frame flush at
  that end again.
- slide=<list>: a side panel slid in and out with that list in it, as one
  piece. In every frame the list is drawn, the panel is drawn in the window
  (never the list without it: before its slide in, or left behind after
  its slide out), and the list sits where it does in the panel at rest
  (the frame with the panel furthest in), within 1 pt across. The panel is
  where its mark is drawn (`ListProbe.drawnPanel`), not where it is laid
  out.
- Always: no blank frame (a list with rows hidden, or none in view) in
  any list, at any time.

Prints PASS or FAIL per check with the numbers; exits 1 if any failed.
"""
import json
import os
import re
import sys

MOVE = 1.0
# The most a rubber band moves in a frame, pushed or easing back.
STRIDE = 12.0


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
    ok, notes = True, []
    if options.get("from") == "grow":
        kind = options.get("hold", "chat")
        first = newest(samples[0], kind)
        grew = next((s for s in samples if first and newest(s, kind) and newest(s, kind)["rows"] > first["rows"]), None)
        if grew is None:
            ok = False
            notes.append(f"{kind} never grew from {first['rows'] if first else 0} rows")
        else:
            start = grew["t"]
            notes.append(f"{kind} grew from {first['rows']} to {newest(grew, kind)['rows']} rows")
    if options.get("from") == "arrive":
        kind = options.get("hold", "chat")

        def last_row(s):
            now = newest(s, kind)
            return max(now["laidOut"], key=lambda r: r["index"])["row"] if now and now["laidOut"] else None

        was = next((last_row(s) for s in reversed(samples) if s["t"] < start), None)
        came = next((s for s in samples if s["t"] >= start and last_row(s) not in (None, was)), None)
        if came is None:
            ok = False
            notes.append(f"no new row came at the end of {kind}")
        else:
            start = came["t"]
            notes.append(f"a row came at {start - samples[0]['t']:.2f} s")
    if options.get("from") == "resize":
        kind = options.get("hold", "chat")
        resized, last = None, None
        for s in samples:
            now = newest(s, kind)
            if now is None:
                continue
            if last is not None and s["t"] > start and now["list"] == last["list"]:
                was = {r["row"]: r["height"] for r in last["laidOut"]}
                if any(r["row"] in was and abs(r["height"] - was[r["row"]]) > MOVE for r in now["laidOut"]):
                    resized = s
                    break
            last = now
        if resized is None:
            ok = False
            notes.append(f"no row in {kind} changed height")
        else:
            start = resized["t"]
            notes.append(f"a row resized at {start - samples[0]['t']:.2f} s")
    before = [s for s in samples if s["t"] < start]
    reference = before[-1] if before else samples[0]
    after = [s for s in samples if s["t"] >= reference["t"]]

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

    if options.get("still") == "target":
        kind = options.get("hold", "chat")
        ref = newest(reference, kind)
        anchor = ref.get("target") if ref else None
        if anchor is None:
            ok = False
            notes.append("the target not laid out at the reference")
        else:
            shifts = [abs(t["y"] - anchor["y"]) for t in (newest(s, kind).get("target") for s in after if newest(s, kind)) if t]
            worst = max(shifts, default=0)
            moved = sum(1 for d in shifts if d > MOVE)
            if moved:
                ok = False
            notes.append(f"target moved up to {worst:,.0f} pt in {moved} frames")

    keep = options.get("keep")
    if keep:
        nth, _, kind = keep.partition("@")
        kind = kind or "chat"
        ref = newest(reference, kind)
        laid = sorted(ref["laidOut"], key=lambda r: r["index"]) if ref else []
        if len(laid) < int(nth):
            ok = False
            notes.append(f"no row {nth} from the newest laid out in {kind} at the reference")
        else:
            row = laid[-int(nth)]
            shifts = [abs(r["y"] - row["y"]) for r in (find(newest(s, kind), row["row"]) for s in after if newest(s, kind)) if r]
            worst = max(shifts, default=0)
            moved = sum(1 for d in shifts if d > MOVE)
            final = newest(samples[-1], kind)
            grew = find(final, row["row"]) if final else None
            opened = grew is not None and grew["height"] - row["height"] > MOVE
            if moved or grew is None or (options.get("opens") == "yes" and not opened):
                ok = False
            notes.append(f"row {row['index']}'s top moved up to {worst:,.0f} pt in {moved} frames"
                         + (f", {grew['height'] - row['height']:+,.0f} pt tall" if grew else ", gone at the end"))

    narrows = options.get("narrows")
    if narrows:
        first_step = probe["events"][0]["t"] if probe["events"] else samples[0]["t"]
        widths = [(s["t"], newest(s, "chat")["width"]) for s in samples if newest(s, "chat")]
        changes = [t for (t, w), (_, was) in zip(widths[1:], widths) if abs(w - was) > MOVE]
        if len(changes) != 1:
            ok = False
            notes.append(f"chat changed width {len(changes)} times")
        elif changes[0] - first_step < float(narrows):
            ok = False
            notes.append(f"chat narrowed {changes[0] - first_step:.2f} s after the step, before the slide ended")
        else:
            notes.append(f"chat narrowed once, {changes[0] - first_step:.2f} s after the step")

    slide = options.get("slide")
    if slide:
        both = [(s, entry) for s in samples
                if s.get("panelX") is not None and (entry := newest(s, slide)) and entry.get("windowX") is not None]
        if not both:
            ok = False
            notes.append(f"no frame with the panel and the {slide} list")
        else:
            settled, at_rest = min(both, key=lambda pair: pair[0]["panelX"])
            rest = at_rest["windowX"] - settled["panelX"]
            alone, apart, worst = 0, 0, 0.0
            for sample in samples:
                entry = newest(sample, slide)
                if entry is None or not entry["visible"]:
                    continue
                panel = sample.get("panelX")
                if panel is None:
                    alone += 1
                    continue
                gap = abs(entry["windowX"] - panel - rest)
                worst = max(worst, gap)
                apart += gap > MOVE
            if alone or apart:
                ok = False
            notes.append(f"{slide} list apart from the panel by up to {worst:,.0f} pt in {apart} frames; "
                         f"drawn without the panel in {alone} frames")

    more = options.get("more")
    if more:
        kind = options.get("hold", "chat")
        last = newest(samples[-1], kind)
        if last is None or last["rows"] <= int(more):
            ok = False
            notes.append(f"{kind} ended with {last['rows'] if last else 0} rows, not over {more}")
        else:
            notes.append(f"{kind} ended with {last['rows']} rows")

    overscroll = options.get("overscroll")
    if overscroll:
        side, _, kind = overscroll.partition("@")
        kind = kind or "chat"
        push = next((e for e in probe["events"] if '"overscroll"' in e["step"]), None)
        ref = newest(reference, kind)
        if push is None or ref is None:
            ok = False
            notes.append("no overscroll step" if push is None else f"no {kind} list at the start")
        else:
            depth = abs(json.loads(push["step"])["overscroll"])

            def past(entry):
                # How far beyond the end the view is, from the reference.
                return ref["below"] - entry["below"] if side == "bottom" else ref["offset"] - entry["offset"]

            series = [past(newest(s, kind)) for s in samples if s["t"] >= push["t"] and newest(s, kind)
                      and newest(s, kind)["list"] == ref["list"]]
            peak = max(series, default=0)
            top = series.index(peak) if series else 0
            against = [b - a for a, b in zip(series[:top + 1], series[1:top + 1]) if b < a - 0.5]
            against += [a - b for a, b in zip(series[top:], series[top + 1:]) if b > a + 0.5]
            stride = max((abs(b - a) for a, b in zip(series, series[1:])), default=0)
            last = series[-1] if series else 0
            notes.append(f"pushed {peak:,.0f} of {depth:,.0f} pt past the {side}, {len(against)} frames against it, "
                         f"at most {stride:,.1f} pt a frame, ended {last:+,.1f} pt")
            if peak < depth * 0.9 or against or stride > STRIDE or abs(last) > MOVE:
                ok = False

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
                fits = last["offset"] <= MOVE and last["below"] <= MOVE
                if fits and target["y"] >= 0 and target["y"] + target["height"] <= last["container"]:
                    notes.append(f"target in view ({target['y']:,.0f} pt), the list too short to centre it")
                elif abs(off) > max(24, last["container"] * 0.1):
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
