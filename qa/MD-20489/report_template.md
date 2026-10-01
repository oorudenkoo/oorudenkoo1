# MD-20489 — TikTok Trends tab, test report

Build: 3.13.120-11222 · Config: ilya_rudenko1_v11_fixed.json · Device: <model, Android N>
Analytics tag: <from ./run.sh bootstrap>

## Results

| ID | Статус | Что увидел | Файлы |
|---|---|---|---|
| F-2 US | | | screens/F-2_US_top.png, logs/F-2_US.log |
| F-2 KR | | | |
| F-2 … | | | |
| F-3 | | | screens/F-3_before.png, screens/F-3_after.png, logs/F-3.log |
| F-6 | | | screens/F-6_1..5, logs/F-6.log |
| S-3 | | | screens/S-3_*, logs/S-3.log |
| S-4 | | | screens/S-4_*, logs/S-4.log |
| S-7 | | | screens/S-7_*, logs/S-7.log |
| O-1 | | | screens/O-1_*, logs/O-1.log |
| O-2 | | | |
| O-3 | | | screens/O-3_1_after_card_tap.png, logs/O-3.log |
| O-4 | | | |
| O-6 | | | screens/O-6_1_cold_start.png, logs/O-6.log |
| A-1 | | | screens/A-1_*, logs/A-1.log |
| A-2 | | | screens/A-2_*, logs/A-2.log |
| AN-* | | | events.json, logs/*.events.log |

Статус: Pass / Fail / Blocked (+ причина).

## Analytics vs new_events (rows 2–9)

| Event | Spec | Actual | Verdict |
|---|---|---|---|
| home_page_filter_shown | | | |
| home_page_filter_select | value = chip position L→R, filter_value = new value | | |
| home_page_header_shown | value1 = header_position | | |
| home_page_group_shown | value1 = group_position (groups only, no gaps), group_type = hashtag | | |
| home_page_composition_select | click_type = preview | | |

- `header_name` or `header_type`: <which one the build sends, and which one the spec asks for>
- Duplicate shown-events without a visible change: <from check_events.py>

## Расхождения (для баг-репортов)

### 1. <short title>
- **Case / ID:** 
- **Steps:** 
- **Expected:** (spec or config reference)
- **Actual:** 
- **Evidence:** screens/…, logs/…
- **Severity:** 
