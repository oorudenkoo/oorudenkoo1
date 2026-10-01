# MD-20489 — TikTok Trends tab, test kit

Built in a cloud session that had **no adb and no device**, so nothing here was run
against the real build. It is tooling for the local run, not results.

| File | Tested? | What it is |
|---|---|---|
| `run.sh` | yes, against a mock `adb` | bash driver for every case; elements found by text via `uiautomator dump` |
| `lib.ps1` | **no — never executed** | same primitives in PowerShell, if you prefer it over Git Bash |
| `analyze_config.py` | yes, on a synthetic config | the F-2 oracle: expected sections + positions per country |
| `check_events.py` | yes, on synthetic logcat | the AN-* helper: event params, `header_name` vs `header_type`, duplicate shown-events |
| `report_template.md` | — | skeleton for the final `report.md` |

`run.sh` needs bash (Git Bash on Windows) and `adb` on PATH. The Python tools need
python3 only — no third-party packages.

## Order of work

```bash
cd /c/Users/ASUS/Desktop/qaMD-20489        # Git Bash path form

# 0. expected values, before touching the device
python analyze_config.py ilya_rudenko1_v11_fixed.json --csv expected.csv

# 1. install, launch, open the tab, report the analytics tag
./run.sh bootstrap PhotoLab-3.13.120-11222.apk

# 2. if you only want to know whether the tab exists at all
./run.sh checktab                 # exit 1 and saves logs/_no_tab_dump.xml when absent

# 3. cases
./run.sh f2 US KR BR DE JP        # the codes from filters.countries
./run.sh f3 US
./run.sh f6 KR
./run.sh panels                   # S-3, S-4, S-7
./run.sh offline US KR            # O-1..O-4, network restored at the end
./run.sh coldstart                # O-6
./run.sh fonts                    # A-1, A-2, originals restored at the end

# 4. analytics against the spec
python check_events.py logs/ --json events.json
```

If anything dies mid-run with the display still altered:

```bash
./run.sh restore                  # reads logs/_device_state.json
```

## Things that are deliberately not automated

- **Toast presence (O-2, O-3).** Toasts are often missing from the uiautomator
  hierarchy, so `run.sh` captures a screenshot right after the tap and leaves the
  verdict to the screenshot. Don't let the script's silence read as "no toast".
- **Comparing visible sections with the config (F-2).** The driver writes what it
  saw to `logs/F-2_<country>.visible.txt`; `analyze_config.py` prints what should
  be there. The comparison is a judgement call — section titles on screen need not
  match the config's keys verbatim.
- **Top bar + bottom bar together (S-*).** Screenshots only. A node existing in the
  hierarchy is not proof it is on screen.
- **Chip positions.** `analyze_config.py` prints both 0-based and 1-based, because
  which one `value` uses is defined by `new_events`, not by the config.

## Known shaky spots

- Package name is resolved by diffing `pm list packages -3` around the install. On a
  reinstall over the same build nothing new appears, so it falls back to a name match
  and otherwise stops and asks. You can also just write the name into
  `logs/_package.txt`.
- `check_events.py` guesses the log format with a loose `key=value` / `"key":"value"`
  regex. Once the first real event line is in hand, check the parsed output against it;
  if the build uses a bundle dump format, adjust `PARAM_RE` — one place, one line.
- `./run.sh f2` returns to the top of the list with two fixed upward swipes. If the
  list is very long, scroll back up by hand between countries.
- `svc wifi/data` is silently ignored on some vendor ROMs. `run.sh` warns but keeps
  going — confirm the device really is offline before trusting O-*.
