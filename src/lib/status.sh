# shellcheck shell=bash
# status.sh — --status: read only, changes nothing.

show_status() {
  echo ""
  echo "━━━ Temperature mod status ━━━"
  echo ""
  local f
  for f in "$PM_FILE" "$JS_FILE"; do
    if [ ! -f "$f" ]; then echo "  [missing]   $f"
    elif grep -q "PVE-SENSORS" "$f" 2>/dev/null; then
      echo "  [PATCHED]   $f"
      grep -o "PVE-SENSORS-[A-Z]*-BEGIN" "$f" | sed 's/^/                └ /'
    else echo "  [original]  $f"; fi
  done
  for f in "$MOD_FILE" "$COLLECTOR" "$UNIT_FILE"; do
    [ -f "$f" ] && echo "  [installed] $f" || echo "  [missing]   $f"
  done
  echo ""
  if systemctl list-unit-files "$UNIT_NAME" >/dev/null 2>&1; then
    echo "  Collector: $(systemctl is-active "$UNIT_NAME" 2>/dev/null) / $(systemctl is-enabled "$UNIT_NAME" 2>/dev/null)"
  else
    echo "  Collector: not installed"
  fi
  if [ -f "$DATA_DIR/sensors.rrd" ]; then
    echo "  RRD:       $DATA_DIR/sensors.rrd ($(du -h "$DATA_DIR/sensors.rrd" | cut -f1))"
  fi
  [ -x "$COLLECTOR" ] && { echo "  Series:"; "$COLLECTOR" --list 2>/dev/null | sed 's/^/            /'; }
  echo ""
  if [ -f "$STATE_FILE" ]; then
    echo "  Re-apply after upgrade: yes (options: $(tr '\n' ' ' < "$STATE_FILE"))"
  else
    echo "  Re-apply after upgrade: no"
  fi
  echo ""
  echo "  Backups: $BACKUP_ROOT"
  ls -1 "$BACKUP_ROOT" 2>/dev/null | sed 's/^/            /' || echo "            (none)"
  echo ""
}
