#!/usr/bin/env python3
"""
MD-20489 - F-2 oracle.

Reads ilya_rudenko1_v11_fixed.json and prints, per country of the filter, which
sections the screen is supposed to show and which positions the analytics events
are supposed to carry:

  header_position  - index of a header among the visible headers
  group_position   - running index of a hashtag group among the visible groups,
                     headers not counted, renumbered after filtering so there
                     are no gaps

Both 0-based and 1-based are printed: the spec sheet decides which one is right,
and that is exactly the kind of off-by-one this tab is likely to get wrong.

Usage:
    python analyze_config.py path\\to\\ilya_rudenko1_v11_fixed.json
    python analyze_config.py config.json --country US      # one country
    python analyze_config.py config.json --csv expected.csv
"""

import argparse
import csv
import json
import sys


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def get_home(cfg):
    """tabs[0].content[0].options.home, but say clearly what was found instead."""
    try:
        tab = cfg["tabs"][0]
    except (KeyError, IndexError, TypeError):
        die(f"no tabs[0]; top-level keys = {list(cfg)[:20]}")
    try:
        content0 = tab["content"][0]
    except (KeyError, IndexError, TypeError):
        die(f"no tabs[0].content[0]; tab keys = {list(tab)[:20]}")
    options = content0.get("options")
    if not isinstance(options, dict):
        die(f"no tabs[0].content[0].options; content[0] keys = {list(content0)[:20]}")
    home = options.get("home")
    if home is None:
        die(f"no options.home; options keys = {list(options)[:20]}")
    if isinstance(home, dict):
        # Some builds wrap the list one level deeper.
        for key in ("sections", "content", "items"):
            if isinstance(home.get(key), list):
                return home[key]
        die(f"options.home is a dict without a section list; keys = {list(home)[:20]}")
    if not isinstance(home, list):
        die(f"options.home has unexpected type {type(home).__name__}")
    return home


def get_filter_countries(cfg):
    """filters.countries, pinned through content_filters."""
    filters = cfg.get("filters") or {}
    raw = filters.get("countries")
    if raw is None:
        die(f"no filters.countries; filters keys = {list(filters)[:20]}")

    countries = []
    if isinstance(raw, dict):
        # e.g. {"values": [...]} or {"US": "United States", ...}
        for key in ("values", "items", "list"):
            if isinstance(raw.get(key), list):
                raw = raw[key]
                break
        else:
            raw = [{"code": k, "title": v} for k, v in raw.items()]
    for i, item in enumerate(raw):
        if isinstance(item, str):
            countries.append({"pos": i, "code": item, "title": item})
        elif isinstance(item, dict):
            code = (item.get("code") or item.get("id") or item.get("country")
                    or item.get("value") or item.get("name"))
            title = item.get("title") or item.get("label") or item.get("name") or code
            countries.append({"pos": i, "code": code, "title": title})
        else:
            die(f"filters.countries[{i}] has unexpected type {type(item).__name__}")
    return countries


def section_countries(section):
    """extra.countries, normalised. None means 'no restriction'."""
    extra = section.get("extra") or {}
    raw = extra.get("countries")
    if raw is None:
        return None
    if isinstance(raw, str):
        raw = [c.strip() for c in raw.split(",") if c.strip()]
    if not raw:
        return None  # present but empty - treated as unrestricted, flagged below
    out = []
    for item in raw:
        if isinstance(item, dict):
            out.append(item.get("code") or item.get("id") or item.get("value"))
        else:
            out.append(str(item))
    return out


def section_label(section, idx):
    for key in ("title", "name", "header_name", "header_type", "text", "id"):
        v = section.get(key)
        if isinstance(v, str) and v.strip():
            return v
    extra = section.get("extra") or {}
    for key in ("title", "name", "hashtag", "group_name"):
        v = extra.get(key)
        if isinstance(v, str) and v.strip():
            return v
    return f"<section #{idx} type={section.get('type')}>"


def visible_for(sections, code):
    """Sections visible for one country, with header/group positions assigned."""
    rows = []
    header_i = 0
    group_i = 0
    for idx, s in enumerate(sections):
        allowed = section_countries(s)
        if allowed is not None and code not in allowed:
            continue
        stype = s.get("type")
        row = {
            "config_index": idx,
            "type": stype,
            "label": section_label(s, idx),
            "header_position_0": "",
            "header_position_1": "",
            "group_position_0": "",
            "group_position_1": "",
            "content_size": (s.get("content_size")
                             or (s.get("extra") or {}).get("content_size") or ""),
            "unrestricted": allowed is None,
        }
        if stype == "header":
            row["header_position_0"] = header_i
            row["header_position_1"] = header_i + 1
            header_i += 1
        elif stype == "list":
            # group_position: groups only, continuous, no gaps after filtering.
            row["group_position_0"] = group_i
            row["group_position_1"] = group_i + 1
            group_i += 1
        rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--country", help="only this country code")
    ap.add_argument("--csv", help="also write a flat CSV of the expectations")
    args = ap.parse_args()

    try:
        with open(args.config, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        die(f"file not found: {args.config}")
    except json.JSONDecodeError as e:
        die(f"invalid JSON: {e}")

    sections = get_home(cfg)
    countries = get_filter_countries(cfg)

    headers = [s for s in sections if s.get("type") == "header"]
    lists_ = [s for s in sections if s.get("type") == "list"]
    other = [s for s in sections if s.get("type") not in ("header", "list")]

    print("=" * 78)
    print("CONFIG SUMMARY")
    print("=" * 78)
    print(f"sections total      : {len(sections)}")
    print(f"  type=header       : {len(headers)}")
    print(f"  type=list         : {len(lists_)}")
    if other:
        print(f"  other types       : {len(other)} -> "
              f"{sorted({str(s.get('type')) for s in other})}")
    print(f"filter countries    : {len(countries)} -> "
          f"{', '.join(str(c['code']) for c in countries)}")

    unrestricted = [section_label(s, i) for i, s in enumerate(sections)
                    if section_countries(s) is None]
    if unrestricted:
        print()
        print("NOTE: these sections have no extra.countries (or an empty one). They are")
        print("      assumed visible for every country. Confirm that is the intent:")
        for lbl in unrestricted:
            print(f"      - {lbl}")

    rows_for_csv = []
    targets = [c for c in countries
               if not args.country or str(c["code"]).upper() == args.country.upper()]
    if args.country and not targets:
        die(f"country {args.country} is not in filters.countries")

    for c in targets:
        rows = visible_for(sections, c["code"])
        n_groups = sum(1 for r in rows if r["type"] == "list")
        n_headers = sum(1 for r in rows if r["type"] == "header")
        print()
        print("=" * 78)
        print(f"COUNTRY {c['code']}  ({c['title']})   chip position: "
              f"{c['pos']} (0-based) / {c['pos'] + 1} (1-based)")
        print(f"expected on screen: {n_headers} header(s), {n_groups} group(s)")
        print("-" * 78)
        print(f"{'cfg#':>4}  {'type':<7} {'hdr_pos':>7} {'grp_pos':>7}  label")
        print("-" * 78)
        for r in rows:
            hp = (f"{r['header_position_0']}/{r['header_position_1']}"
                  if r["type"] == "header" else "")
            gp = (f"{r['group_position_0']}/{r['group_position_1']}"
                  if r["type"] == "list" else "")
            star = "*" if r["unrestricted"] else " "
            print(f"{r['config_index']:>4}{star} {r['type']:<7} {hp:>7} {gp:>7}  {r['label']}")
            rows_for_csv.append({
                "country_code": c["code"],
                "country_title": c["title"],
                "chip_position_0": c["pos"],
                "chip_position_1": c["pos"] + 1,
                **r,
            })

    print()
    print("positions are printed as 0-based/1-based; confirm against new_events in")
    print("analysts_library.xlsx. '*' marks a section with no country restriction.")

    if args.csv and rows_for_csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows_for_csv[0]))
            w.writeheader()
            w.writerows(rows_for_csv)
        print(f"\nCSV written: {args.csv}")


if __name__ == "__main__":
    main()
