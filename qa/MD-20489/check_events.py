#!/usr/bin/env python3
"""
MD-20489 - AN-* helper.

Extracts home_page_* events out of the captured logs and reports what the
analytics sheet asks about:

  * which parameter keys each event actually carries, per event name
  * header_name vs header_type - which one the build sends
  * duplicate shown-events: the same event with the same parameters fired twice
    with nothing in between, i.e. a re-send without a visible change
  * the order of filter_select / *_shown events, so value vs filter_value and the
    position numbering can be checked by eye against new_events

The parameter grammar is deliberately loose, because the build's exact log format
is only known once the first real line is in hand. It accepts key=value,
"key":"value", key: value and key => value. If the real format differs, the one
place to adjust is PARAM_RE.

Usage:
    python check_events.py logs/                 # every *.events.log
    python check_events.py logs/F-2.events.log   # one file
    python check_events.py logs/ --json out.json
"""

import argparse
import json
import re
import sys
from collections import Counter, OrderedDict
from pathlib import Path

EVENT_RE = re.compile(r"\b(home_page_[A-Za-z0-9_]+)")

PARAM_RE = re.compile(
    r"""(?P<key>[A-Za-z_][A-Za-z0-9_]*)       # key
        \s*(?:=>|[:=])\s*                     # = : or =>
        (?P<val>"[^"]*"|'[^']*'|[^,;}\s]+)    # quoted or bare value
    """,
    re.VERBOSE,
)

# Keys that are part of the logcat prelude, not the event payload.
NOISE_KEYS = {"pid", "tid", "uid", "time", "level", "tag", "thread"}

SHOWN_EVENTS = ("filter_shown", "header_shown", "group_shown")


def parse_line(line):
    m = EVENT_RE.search(line)
    if not m:
        return None
    name = m.group(1)
    tail = line[m.end():]
    params = OrderedDict()
    for pm in PARAM_RE.finditer(tail):
        key = pm.group("key")
        if key in NOISE_KEYS or key == name:
            continue
        val = pm.group("val").strip("\"'")
        if key not in params:
            params[key] = val
    tag = None
    tm = re.match(r"^\S+\s+\S+\s+\d+\s+\d+\s+\w\s+([^:]+):", line)
    if tm:
        tag = tm.group(1).strip()
    return {"event": name, "params": params, "tag": tag, "raw": line.rstrip()}


def collect(paths):
    events = []
    for p in paths:
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            print(f"WARNING: cannot read {p}: {e}", file=sys.stderr)
            continue
        for line in text.splitlines():
            ev = parse_line(line)
            if ev:
                ev["source"] = p.name
                events.append(ev)
    return events


def find_duplicate_shown(events):
    """Same shown-event, same params, nothing in between - per source file."""
    dups = []
    by_source = {}
    for ev in events:
        by_source.setdefault(ev["source"], []).append(ev)

    for source, evs in by_source.items():
        prev = None
        for ev in evs:
            short = ev["event"].replace("home_page_", "")
            if any(short.endswith(s) or short == s for s in SHOWN_EVENTS):
                sig = (ev["event"], tuple(sorted(ev["params"].items())))
                if prev and prev[0] == sig:
                    prev = (sig, prev[1] + 1, prev[2])
                    dups.append({
                        "source": source,
                        "event": ev["event"],
                        "params": dict(ev["params"]),
                        "raw": ev["raw"],
                    })
                else:
                    prev = (sig, 1, ev)
            else:
                prev = None  # a non-shown event in between breaks the run
    return dups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", help="logs directory or a single log file")
    ap.add_argument("--json", help="write the parsed events to this file")
    args = ap.parse_args()

    t = Path(args.target)
    if t.is_dir():
        paths = sorted(t.glob("*.events.log")) or sorted(t.glob("*.log"))
    elif t.is_file():
        paths = [t]
    else:
        print(f"ERROR: not found: {t}", file=sys.stderr)
        return 1
    if not paths:
        print(f"ERROR: no log files under {t}", file=sys.stderr)
        return 1

    events = collect(paths)
    print("=" * 78)
    print(f"files scanned : {len(paths)}")
    print(f"home_page_* events found : {len(events)}")
    if not events:
        print("\nNothing to check. Either the tag filter missed the events or the")
        print("build logs them under a different name - run Find-AnalyticsTag first.")
        return 0

    tags = Counter(e["tag"] for e in events if e["tag"])
    if tags:
        print("\nlogcat tag(s) carrying the events:")
        for tag, n in tags.most_common():
            print(f"  {tag:<40} {n}")

    print("\n" + "=" * 78)
    print("EVENT NAMES AND THEIR PARAMETER KEYS")
    print("=" * 78)
    by_name = {}
    for e in events:
        by_name.setdefault(e["event"], []).append(e)
    for name in sorted(by_name):
        evs = by_name[name]
        keysets = Counter(tuple(e["params"].keys()) for e in evs)
        print(f"\n{name}  ({len(evs)} occurrence(s))")
        for ks, n in keysets.most_common():
            print(f"    [{n:>3}x] {', '.join(ks) if ks else '<no params parsed>'}")
        print(f"    first: {evs[0]['raw'][:150]}")

    # header_name vs header_type - the explicit question in the task.
    print("\n" + "=" * 78)
    print("header_name VS header_type")
    print("=" * 78)
    seen_name = sorted({k for e in events for k in e["params"] if k == "header_name"})
    seen_type = sorted({k for e in events for k in e["params"] if k == "header_type"})
    hdr_like = sorted({k for e in events for k in e["params"] if k.startswith("header")})
    print(f"  header_name present : {'YES' if seen_name else 'no'}")
    print(f"  header_type present : {'YES' if seen_type else 'no'}")
    print(f"  all header* keys    : {', '.join(hdr_like) if hdr_like else '<none>'}")
    if seen_name and seen_type:
        print("  -> both appear; check which event uses which, this is a likely bug.")
    elif not seen_name and not seen_type:
        print("  -> neither parsed; confirm by eye in the raw log before reporting.")

    print("\n" + "=" * 78)
    print("DUPLICATE SHOWN-EVENTS (same params, nothing in between)")
    print("=" * 78)
    dups = find_duplicate_shown(events)
    if not dups:
        print("  none found")
    else:
        for d in dups:
            print(f"  [{d['source']}] {d['event']} {d['params']}")
            print(f"      {d['raw'][:150]}")
        print(f"\n  {len(dups)} repeat(s) - each is a shown-event re-sent without a change.")

    print("\n" + "=" * 78)
    print("SEQUENCE PER FILE (for the value / filter_value / position check)")
    print("=" * 78)
    for p in paths:
        evs = [e for e in events if e["source"] == p.name]
        if not evs:
            continue
        print(f"\n--- {p.name} ({len(evs)} event(s))")
        for i, e in enumerate(evs, 1):
            parts = ", ".join(f"{k}={v}" for k, v in e["params"].items())
            print(f"  {i:>3}. {e['event']:<32} {parts}")

    if args.json:
        payload = [{"source": e["source"], "event": e["event"],
                    "tag": e["tag"], "params": dict(e["params"])} for e in events]
        Path(args.json).write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                                   encoding="utf-8")
        print(f"\nJSON written: {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
