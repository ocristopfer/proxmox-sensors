# shellcheck shell=bash
# series.sh — detects the temperature series this hardware actually has.
#
# Sets: FIELDS_JS, TITLES_JS (chart fields/legend) and PANEL_BUMP (how many
# pixels the StatusView must grow). May turn WITH_GRAPH off.

FIELDS_JS=""
TITLES_JS=""
PANEL_BUMP=80

detect_series() {
  step "Detecting temperature series"
  local slots
  slots="$(SENSORS_BIN="$SENSORS_BIN" perl "$SRC_DIR/collector/pve-sensors-collect" --list 2>/dev/null || true)"
  if [ -z "$slots" ]; then
    warn "No series detected — the chart will be skipped (the text line stays)"
    WITH_GRAPH=0
    return 0
  fi
  echo "$slots" | while IFS=$'\t' read -r slot label; do echo "        $slot  →  $label"; done

  # Estimate of how many LINES the 'Temperatures' block will take in the
  # panel. The StatusView has a fixed height: if it doesn't grow enough, it
  # cuts the bottom lines (Kernel Version, Repository Status...). Each text
  # group takes 1 line; with the short labels ~6 disks/NVMe fit per line.
  # The 24px base is slack for when the window is narrower and one of the
  # lists wraps into two lines.
  local lines=0 nv dk
  echo "$slots" | grep -q '^cpu'   && lines=$((lines+1)) || true
  echo "$slots" | grep -q '^gpu'   && lines=$((lines+1)) || true
  echo "$slots" | grep -q '^board' && lines=$((lines+1)) || true
  nv="$(echo "$slots" | grep -c '^nvme' || true)"
  dk="$(echo "$slots" | grep -c '^disk' || true)"
  [ "$nv" -gt 0 ] && lines=$((lines + (nv + 5) / 6)) || true
  [ "$dk" -gt 0 ] && lines=$((lines + (dk + 5) / 6)) || true
  PANEL_BUMP=$((24 + 22 * lines))
  log "temperature block: ~$lines line(s) → panel +${PANEL_BUMP}px"

  if [ "$WITH_GRAPH" -eq 1 ]; then
    FIELDS_JS="$(echo "$slots" | awk -F'\t' '{printf "%s'\''t_%s'\''", (NR>1 ? ", " : ""), $1}')"
    TITLES_JS="$(echo "$slots" | awk -F'\t' '{gsub(/'\''/,"",$2); printf "%s'\''%s'\''", (NR>1 ? ", " : ""), $2}')"
    ok "$(echo "$slots" | wc -l) series will be plotted"
  fi
}
