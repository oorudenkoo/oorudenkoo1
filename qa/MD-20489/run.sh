#!/usr/bin/env bash
# MD-20489 / PhotoLab 3.13.120-11222 - TikTok Trends tab test driver.
#
# Elements are located through `uiautomator dump` and tapped at the centre of
# their own bounds. No hardcoded coordinates anywhere.
#
#   ./run.sh bootstrap <apk>     install, launch, report the analytics tag, open the tab
#   ./run.sh f2 US KR BR ...     one chip after another, scroll to the end, log + shoot
#   ./run.sh f3 <country>        re-tap an already selected chip
#   ./run.sh f6 <country>        tab away and back; HOME and back
#   ./run.sh panels              S-3, S-4, S-7
#   ./run.sh offline <c1> <c2>   O-1..O-4 (network off, restored at the end)
#   ./run.sh coldstart           O-6 (cold start with no network)
#   ./run.sh fonts               A-1, A-2 (originals saved first, restored at the end)
#   ./run.sh checktab            is the TikTokTrends tab there at all (stops if not)
#   ./run.sh restore             put font_scale / density back, any time
#
# Everything lands in screens/<ID>.png and logs/<ID>.log next to this script.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCREENS="$ROOT/screens"; LOGS="$ROOT/logs"; TMP="$ROOT/.tmp"
STATE="$LOGS/_device_state.json"
PKG_FILE="$LOGS/_package.txt"
XML="$TMP/ui_dump.xml"
TAB_LABEL="${TAB_LABEL:-TikTokTrends}"

mkdir -p "$SCREENS" "$LOGS" "$TMP"

say()  { printf '%s\n' "$*"; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ adb basics

ADB=${ADB:-adb}

assert_device() {
  local ready
  ready=$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
  [ -n "$ready" ] || { "$ADB" devices; die 'no device in state "device" - check USB and the RSA prompt'; }
  [ "$(printf '%s\n' "$ready" | wc -l)" -eq 1 ] || die 'more than one device - set ANDROID_SERIAL'
  ok "device OK: $ready"
}

pkg() {
  [ -s "$PKG_FILE" ] || die "package unknown - run './run.sh bootstrap <apk>' first"
  tr -d '\r\n' < "$PKG_FILE"
}

# ------------------------------------------------------------------- ui dump

ui_dump() {
  local i
  for i in 1 2 3 4; do
    if "$ADB" shell uiautomator dump /sdcard/ui_dump.xml 2>&1 | grep -qi 'error\|could not'; then
      sleep 1; continue
    fi
    if "$ADB" pull /sdcard/ui_dump.xml "$XML" >/dev/null 2>&1 && [ -s "$XML" ]; then
      return 0
    fi
    sleep 1
  done
  die "uiautomator dump failed after 4 attempts"
}

# All <node .../> elements, one per line - the basis for every lookup below.
ui_nodes() { grep -o '<node[^>]*>' "$XML"; }

# Visible texts, in hierarchy order.
ui_texts() {
  ui_nodes | grep -o 'text="[^"]*"' | sed 's/^text="//; s/"$//' | grep -v '^$'
}

# bounds of the first node whose text (or content-desc) matches.
# $2 = "exact" for equality, anything else for substring.
ui_bounds() {
  local needle="$1" mode="${2:-loose}" line
  if [ "$mode" = exact ]; then
    line=$(ui_nodes | grep -F "text=\"$needle\"" | head -1)
    [ -n "$line" ] || line=$(ui_nodes | grep -F "content-desc=\"$needle\"" | head -1)
  else
    line=$(ui_nodes | grep -F "$needle" | head -1)
  fi
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | grep -o 'bounds="[^"]*"' | head -1 | sed 's/bounds="//; s/"$//'
}

has_text() { ui_dump; ui_bounds "$1" "${2:-loose}" >/dev/null 2>&1; }

tap_text() {
  local needle="$1" mode="${2:-loose}" b x1 y1 x2 y2 cx cy
  ui_dump
  b=$(ui_bounds "$needle" "$mode") || { warn "no node matching '$needle'"; return 1; }
  read -r x1 y1 x2 y2 < <(printf '%s\n' "$b" \
    | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\1 \2 \3 \4/')
  cx=$(( (x1 + x2) / 2 )); cy=$(( (y1 + y2) / 2 ))
  say "  tap '$needle' -> ($cx,$cy)  bounds=$b"
  "$ADB" shell input tap "$cx" "$cy" >/dev/null
  sleep 1.2
}

# ------------------------------------------------------------------- scrolling

screen_size() {
  "$ADB" shell wm size | sed -n 's/.*size: *\([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1
}

scroll_down() {
  local w h x y1 y2
  read -r w h < <(screen_size)
  [ -n "${h:-}" ] || die "cannot read screen size"
  x=$(( w / 2 )); y1=$(( h * 75 / 100 )); y2=$(( h * 30 / 100 ))
  "$ADB" shell input swipe "$x" "$y1" "$x" "$y2" 400 >/dev/null
  sleep 0.9
}

# Scrolls until the hierarchy stops changing. Prints every text seen on the way,
# de-duplicated, order preserved - that is the list to compare with the config.
scroll_to_bottom() {
  local shot_prefix="${1:-}" max="${2:-25}" i prev='' sig
  local seen="$TMP/seen.txt"; : > "$seen"
  for (( i=0; i<=max; i++ )); do
    ui_dump
    ui_texts >> "$seen"
    [ -n "$shot_prefix" ] && shot "$(printf '%s_scroll%02d' "$shot_prefix" "$i")" >/dev/null
    sig=$(cksum < "$XML" | awk '{print $1}')
    if [ "$sig" = "$prev" ]; then say "  bottom reached after $i swipe(s)"; break; fi
    prev="$sig"
    (( i < max )) && scroll_down
  done
  awk '!seen[$0]++' "$seen"
}

# ----------------------------------------------------------------- screenshots

shot() {
  local name="$1"
  "$ADB" shell screencap -p /sdcard/_qa_shot.png >/dev/null
  "$ADB" pull /sdcard/_qa_shot.png "$SCREENS/$name.png" >/dev/null 2>&1 \
    || { warn "screenshot pull failed for $name"; return 1; }
  "$ADB" shell rm -f /sdcard/_qa_shot.png >/dev/null 2>&1
  say "  screenshot -> screens/$name.png"
}

# -------------------------------------------------------------------- logcat

log_start() { "$ADB" logcat -c >/dev/null 2>&1; say "[$1] logcat cleared"; }

log_stop() {
  local id="$1" n
  "$ADB" logcat -d -v threadtime > "$LOGS/$id.log" 2>&1
  grep -a 'home_page_' "$LOGS/$id.log" > "$LOGS/$id.events.log" 2>/dev/null || true
  n=$(wc -l < "$LOGS/$id.events.log" | tr -d ' ')
  say "[$id] logs/$id.log ; $n home_page_* line(s) -> logs/$id.events.log"
}

# Step 1 of the task: which tag carries home_page_*.
find_tag() {
  local buf="$TMP/tagscan.log"
  "$ADB" logcat -d -v threadtime > "$buf" 2>&1
  if ! grep -aq 'home_page_' "$buf"; then
    warn "no home_page_* in the current buffer - interact with the app and re-run"
    return 1
  fi
  info "tags carrying home_page_*:"
  grep -a 'home_page_' "$buf" \
    | sed -n 's/^[^ ]* *[^ ]* *[0-9]* *[0-9]* *\([A-Z]\) *\([^:]*\):.*/\1\/\2/p' \
    | sort | uniq -c | sort -rn | sed 's/^/  /'
  info "first matching line verbatim:"
  grep -a -m1 'home_page_' "$buf" | sed 's/^/  /'
}

check_fatal() {
  local id="$1"
  if grep -aq 'FATAL EXCEPTION\|Process crashed\|ANR in' "$LOGS/$id.log"; then
    printf '\033[31m  FATAL found in %s:\033[0m\n' "$id"
    grep -a -m5 'FATAL EXCEPTION\|Process crashed\|ANR in' "$LOGS/$id.log" | sed 's/^/    /'
    return 1
  fi
  ok "  no FATAL EXCEPTION in $id"
}

# ------------------------------------------------------------------ navigation

press_home() { "$ADB" shell input keyevent KEYCODE_HOME >/dev/null; sleep 1; }
press_back() { "$ADB" shell input keyevent KEYCODE_BACK >/dev/null; sleep 1; }
resume_app() { "$ADB" shell monkey -p "$(pkg)" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 2; }

open_tab() {
  ui_dump
  if ! ui_bounds "$TAB_LABEL" >/dev/null 2>&1; then
    say ''
    warn "tab '$TAB_LABEL' is NOT in the hierarchy."
    say  'Visible texts right now:'
    ui_texts | sed 's/^/    /' | head -40
    cp "$XML" "$LOGS/_no_tab_dump.xml"
    die "STOP: the tab is missing. Hierarchy saved to logs/_no_tab_dump.xml - report this and go no further."
  fi
  tap_text "$TAB_LABEL"
  ok "tab '$TAB_LABEL' opened"
}

# ---------------------------------------------------------------- network

net() {
  local verb; [ "$1" = on ] && verb=enable || verb=disable
  "$ADB" shell svc wifi "$verb" >/dev/null 2>&1 || warn "svc wifi $verb failed"
  "$ADB" shell svc data "$verb" >/dev/null 2>&1 || warn "svc data $verb failed"
  sleep 3
  printf '\033[33mnetwork: %s\033[0m\n' "$1"
}

# --------------------------------------------- display state: save and restore

save_state() {
  local fs wm phys ovr
  fs=$("$ADB" shell settings get system font_scale | tr -d '\r\n')
  wm=$("$ADB" shell wm density)
  phys=$(printf '%s\n' "$wm" | sed -n 's/.*Physical density: *\([0-9]*\).*/\1/p' | head -1)
  ovr=$(printf '%s\n'  "$wm" | sed -n 's/.*Override density: *\([0-9]*\).*/\1/p' | head -1)
  cat > "$STATE" <<EOF
{"font_scale":"${fs}","physical_density":"${phys}","override_density":"${ovr}","captured_at":"$(date -Iseconds)"}
EOF
  ok "saved: font_scale=${fs:-<empty>} physical=${phys:-?} override=${ovr:-<none>} -> logs/_device_state.json"
}

restore_state() {
  if [ ! -s "$STATE" ]; then
    warn 'no _device_state.json; falling back to delete font_scale + density reset'
    "$ADB" shell settings delete system font_scale >/dev/null 2>&1
    "$ADB" shell wm density reset >/dev/null 2>&1
    return
  fi
  local fs ovr
  fs=$(sed -n 's/.*"font_scale":"\([^"]*\)".*/\1/p' "$STATE")
  ovr=$(sed -n 's/.*"override_density":"\([^"]*\)".*/\1/p' "$STATE")
  if [ -z "$fs" ] || [ "$fs" = null ]; then
    # Never set: writing 1.0 is not the same as unset.
    "$ADB" shell settings delete system font_scale >/dev/null 2>&1
    say '  font_scale: deleted (was unset)'
  else
    "$ADB" shell settings put system font_scale "$fs" >/dev/null 2>&1
    say "  font_scale: restored to $fs"
  fi
  if [ -n "$ovr" ]; then
    "$ADB" shell wm density "$ovr" >/dev/null 2>&1
    say "  density: override restored to $ovr"
  else
    "$ADB" shell wm density reset >/dev/null 2>&1
    say '  density: reset to physical'
  fi
  ok 'display state restored'
}

# ===================================================================== cases

cmd_bootstrap() {
  local apk="${1:-}"
  [ -n "$apk" ] || die "usage: ./run.sh bootstrap <apk>"
  [ -f "$apk" ] || die "APK not found: $apk"
  assert_device

  "$ADB" shell pm list packages -3 | tr -d '\r' | sort > "$TMP/pkg_before.txt"
  info "installing $apk"
  "$ADB" install -r "$apk" | tee "$LOGS/_install.log" | tail -3
  grep -q 'Success' "$LOGS/_install.log" || die 'install -r did not report Success'
  "$ADB" shell pm list packages -3 | tr -d '\r' | sort > "$TMP/pkg_after.txt"

  local new
  new=$(comm -13 "$TMP/pkg_before.txt" "$TMP/pkg_after.txt" | sed 's/^package://')
  if [ "$(printf '%s' "$new" | grep -c .)" -ne 1 ]; then
    new=$(grep -iE 'photolab|photo_lab|funny_photo|linerock' "$TMP/pkg_after.txt" | sed 's/^package://')
  fi
  [ "$(printf '%s' "$new" | grep -c .)" -eq 1 ] || {
    warn 'cannot resolve the package automatically'
    warn 'launch the app by hand, then: adb shell dumpsys window | grep mCurrentFocus'
    warn 'write the name into logs/_package.txt and re-run'
    die 'package unresolved'
  }
  printf '%s' "$new" > "$PKG_FILE"
  ok "package: $new"

  log_start BOOTSTRAP
  "$ADB" shell monkey -p "$new" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 5
  shot BOOTSTRAP_launch
  open_tab                       # stops here if the tab is absent
  shot BOOTSTRAP_tab
  # A couple of interactions so the buffer has events to identify the tag with.
  scroll_down; scroll_down
  log_stop BOOTSTRAP
  say ''
  find_tag || true
  say ''
  info 'now run the cases, e.g.: ./run.sh f2 US KR BR'
}

cmd_f2() {
  [ $# -ge 1 ] || die 'usage: ./run.sh f2 <country> [country...]'
  assert_device
  local c id
  for c in "$@"; do
    id="F-2_$c"
    info "=== $id"
    log_start "$id"
    tap_text "$c" || { warn "chip '$c' not found - skipping"; log_stop "$id"; continue; }
    shot "${id}_top"
    say "  visible sections after filtering (scrolling to the end):"
    scroll_to_bottom "$id" | sed 's/^/    /' | tee "$LOGS/${id}.visible.txt" >/dev/null
    sed 's/^/    /' "$LOGS/${id}.visible.txt"
    log_stop "$id"
    # back to the top for the next country
    "$ADB" shell input swipe 540 600 540 1800 300 >/dev/null; sleep 1
    "$ADB" shell input swipe 540 600 540 1800 300 >/dev/null; sleep 1
    say ''
  done
  info "compare each ${LOGS##*/}/F-2_*.visible.txt with: python analyze_config.py <config.json>"
}

cmd_f3() {
  local c="${1:?usage: ./run.sh f3 <country>}"
  assert_device
  info "=== F-3 (re-tap the already selected chip '$c')"
  tap_text "$c" || die "chip '$c' not found"
  sleep 1
  ui_dump; cp "$XML" "$TMP/f3_before.xml"
  ui_texts > "$LOGS/F-3.before.txt"
  shot F-3_before
  log_start F-3                   # cleared AFTER the first selection on purpose:
                                  # only the second tap may appear in this log
  tap_text "$c" || die "chip '$c' vanished"
  sleep 1
  ui_dump; ui_texts > "$LOGS/F-3.after.txt"
  shot F-3_after
  log_stop F-3
  if diff -q "$LOGS/F-3.before.txt" "$LOGS/F-3.after.txt" >/dev/null; then
    ok '  list unchanged (texts identical)'
  else
    printf '\033[31m  list CHANGED after re-tapping the same chip:\033[0m\n'
    diff "$LOGS/F-3.before.txt" "$LOGS/F-3.after.txt" | head -20 | sed 's/^/    /'
  fi
  if grep -aq 'home_page_filter_select' "$LOGS/F-3.events.log" 2>/dev/null; then
    printf '\033[31m  home_page_filter_select WAS sent - expected: not sent\033[0m\n'
    grep -a 'home_page_filter_select' "$LOGS/F-3.events.log" | sed 's/^/    /'
  else
    ok '  home_page_filter_select not sent'
  fi
}

cmd_f6() {
  local c="${1:?usage: ./run.sh f6 <country>}"
  assert_device
  info "=== F-6 (selection survives tab switch / background)"
  log_start F-6
  tap_text "$c" || die "chip '$c' not found"
  shot F-6_1_selected
  ui_texts > "$LOGS/F-6.selected.txt"

  # another tab, then back
  local other
  other=$(ui_texts | grep -v "^$TAB_LABEL$" | head -1)
  say "  switching to another tab: '$other'"
  tap_text "$other" || warn 'could not switch tabs'
  shot F-6_2_other_tab
  open_tab
  shot F-6_3_back_from_tab
  ui_texts > "$LOGS/F-6.after_tab.txt"

  # HOME, then resume
  press_home; shot F-6_4_home
  resume_app; shot F-6_5_resumed
  ui_texts > "$LOGS/F-6.after_resume.txt"
  log_stop F-6

  local t r
  t=$(diff -q "$LOGS/F-6.selected.txt" "$LOGS/F-6.after_tab.txt"    >/dev/null && echo kept || echo LOST)
  r=$(diff -q "$LOGS/F-6.selected.txt" "$LOGS/F-6.after_resume.txt" >/dev/null && echo kept || echo LOST)
  say "  after tab switch : $t"
  say "  after background : $r"
  say "  (compare the screenshots too - the chip's selected state is the point)"
}

cmd_panels() {
  assert_device
  info '=== S-3 / S-4 / S-7 (top bar and bottom bar must be visible together)'
  # Hide the panels first.
  log_start S-3
  scroll_down; scroll_down; scroll_down
  shot S-3_0_panels_hidden
  press_home; sleep 1; resume_app
  shot S-3_1_after_background
  log_stop S-3

  log_start S-4
  scroll_down; scroll_down
  shot S-4_0_panels_hidden
  tap_text "$(ui_texts | grep -v "^$TAB_LABEL$" | head -1)" || warn 'no other screen to open'
  shot S-4_1_other_screen
  press_back
  shot S-4_2_after_back
  log_stop S-4

  log_start S-7
  scroll_down; scroll_down
  shot S-7_0_panels_hidden
  local other; other=$(ui_texts | grep -v "^$TAB_LABEL$" | head -1)
  tap_text "$other" || warn 'no other tab'
  shot S-7_1_other_tab
  open_tab
  shot S-7_2_back_on_tab
  log_stop S-7
  info 'check every S-* screenshot: top bar AND bottom bar present at once'
}

cmd_offline() {
  local c1="${1:?usage: ./run.sh offline <country-a> <country-b>}" c2="${2:?}"
  assert_device
  trap 'warn "interrupted - restoring network"; net on' INT TERM
  info '=== O-1..O-4 (no network)'
  net off
  log_start O-1
  shot O-1_0_before
  tap_text "$c1" || warn "chip '$c1' not found"
  shot O-1_1_chip_a
  tap_text "$c2" || warn "chip '$c2' not found"
  shot O-1_2_chip_b
  log_stop O-1
  say '  expected: filter switches, NO "no connection" toast (check the screenshots)'

  log_start O-3
  ui_texts > "$LOGS/O-3.before.txt"
  # First group item: the topmost hashtag-looking text.
  local card; card=$(ui_texts | grep -m1 '^#' || true)
  if [ -n "$card" ]; then
    tap_text "$card"
  else
    warn 'no #hashtag text found; tapping the centre of the first list row instead'
    local b x1 y1 x2 y2
    ui_dump
    b=$(ui_nodes | grep -F 'class="android.widget.ImageView"' | head -1 \
        | grep -o 'bounds="[^"]*"' | sed 's/bounds="//; s/"$//')
    if [ -n "$b" ]; then
      read -r x1 y1 x2 y2 < <(printf '%s\n' "$b" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\1 \2 \3 \4/')
      "$ADB" shell input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 )) >/dev/null; sleep 2
    fi
  fi
  shot O-3_1_after_card_tap
  ui_texts > "$LOGS/O-3.after.txt"
  log_stop O-3
  if diff -q "$LOGS/O-3.before.txt" "$LOGS/O-3.after.txt" >/dev/null; then
    ok '  screen unchanged - no navigation, as expected'
  else
    warn '  screen changed after the card tap - check whether a transition happened'
    diff "$LOGS/O-3.before.txt" "$LOGS/O-3.after.txt" | head -15 | sed 's/^/    /'
  fi
  say '  the toast itself has to be confirmed on screens/O-3_1_after_card_tap.png'
  say '  (toasts are often absent from the uiautomator hierarchy)'
  net on
  trap - INT TERM
  ok 'network restored'
}

cmd_coldstart() {
  assert_device
  trap 'warn "interrupted - restoring network"; net on' INT TERM
  info '=== O-6 (cold start, no network)'
  "$ADB" shell am force-stop "$(pkg)" >/dev/null; sleep 1
  net off
  log_start O-6
  "$ADB" shell monkey -p "$(pkg)" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 8
  shot O-6_1_cold_start
  ui_dump; ui_texts > "$LOGS/O-6.visible.txt"
  log_stop O-6
  check_fatal O-6 || true
  net on
  trap - INT TERM
}

cmd_fonts() {
  assert_device
  save_state                      # before touching anything
  trap 'warn "interrupted - restoring display state"; restore_state' INT TERM
  local phys
  phys=$(sed -n 's/.*"physical_density":"\([^"]*\)".*/\1/p' "$STATE")
  [ -n "$phys" ] || phys=420
  local bigger=$(( phys * 115 / 100 ))

  info "=== A-1 (font_scale 1.3, density $bigger)"
  log_start A-1
  "$ADB" shell settings put system font_scale 1.3 >/dev/null; sleep 2
  "$ADB" shell wm density "$bigger" >/dev/null; sleep 4
  resume_app
  shot A-1_1_filter_row
  tap_text 'South Korea' || tap_text 'Korea' || warn "'South Korea' chip not found - scroll the chip row by hand"
  shot A-1_2_south_korea
  ui_dump; ui_texts > "$LOGS/A-1.visible.txt"
  log_stop A-1

  info '=== A-2 (font_scale 0.85)'
  log_start A-2
  "$ADB" shell settings put system font_scale 0.85 >/dev/null; sleep 2
  resume_app
  shot A-2_1_filter_row
  tap_text 'South Korea' || tap_text 'Korea' || warn "'South Korea' chip not found"
  shot A-2_2_south_korea
  log_stop A-2

  restore_state
  trap - INT TERM
  info 'check A-* screenshots: long names must not be clipped or overlap'
}

# ========================================================================= main

case "${1:-}" in
  bootstrap) shift; cmd_bootstrap "$@" ;;
  f2)        shift; cmd_f2 "$@" ;;
  f3)        shift; cmd_f3 "$@" ;;
  f6)        shift; cmd_f6 "$@" ;;
  panels)    shift; cmd_panels ;;
  offline)   shift; cmd_offline "$@" ;;
  coldstart) shift; cmd_coldstart ;;
  fonts)     shift; cmd_fonts ;;
  restore)   shift; restore_state ;;
  checktab)  shift; assert_device; open_tab; shot CHECKTAB_tab ;;
  tag)       shift; find_tag ;;
  *) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
