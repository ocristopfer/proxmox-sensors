# shellcheck shell=bash
# install.sh — everything that touches the system: backup, install/revert,
# service restart with health check, API validation and the final report.

# Never fails: it is also used by the rollback.
remove_collector() {
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$COLLECTOR" "$MOD_FILE" || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# From here on, any error triggers an automatic rollback.
backup_originals() {
  step "Backing up the originals"
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  cp -a "$PM_FILE" "$BACKUP_DIR/Nodes.pm"
  cp -a "$JS_FILE" "$BACKUP_DIR/pvemanagerlib.js"
  cat > "$BACKUP_DIR/RESTORE.sh" <<RESTOREEOF
#!/bin/sh
# Emergency manual restore. Run as root if everything else fails.
set -e
cp -a "$BACKUP_DIR/Nodes.pm"         "$PM_FILE"
cp -a "$BACKUP_DIR/pvemanagerlib.js" "$JS_FILE"
systemctl disable --now $UNIT_NAME 2>/dev/null || true
rm -f "$UNIT_FILE" "$COLLECTOR" "$MOD_FILE"
systemctl daemon-reload
systemctl restart pvedaemon pveproxy
echo "Proxmox restored."
RESTOREEOF
  chmod +x "$BACKUP_DIR/RESTORE.sh"
  ok "Backup: $BACKUP_DIR"
  ok "Emergency manual restore: $BACKUP_DIR/RESTORE.sh"
  ARMED=1
}

do_revert() {
  step "Removing the collector"
  remove_collector
  ok "Service and files removed"

  if [ "$PURGE" -eq 1 ]; then
    # guard: only delete if it really is our directory, with our RRD inside
    case "$DATA_DIR" in
      /var/lib/pve-sensors) [ -f "$DATA_DIR/sensors.rrd" ] && rm -rf "$DATA_DIR" && ok "History deleted" ;;
      *) warn "DATA_DIR='$DATA_DIR' is not the default — refusing to delete it for safety" ;;
    esac
  else
    log "History kept in $DATA_DIR (use --purge to delete it)"
  fi

  step "Reverting patches"
  perl "$PATCH_PM" "$PM_FILE" revert || die "failed to revert $PM_FILE"
  perl "$PATCH_JS" "$JS_FILE" revert || die "failed to revert $JS_FILE"
}

install_collector() {
  step "Installing the collector"
  mkdir -p "$DATA_DIR"
  install -m 0755 "$SRC_DIR/collector/pve-sensors-collect"    "$COLLECTOR"
  install -m 0644 "$SRC_DIR/perl/PVE/SensorsRRD.pm"           "$MOD_FILE"
  install -m 0644 "$SRC_DIR/collector/$UNIT_NAME"             "$UNIT_FILE"
  INSTALLED_COLLECTOR=1
  "$COLLECTOR" --once || die "the collector failed on its first run"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME"
  # restart, not --now: on a re-install the old collector would keep running
  systemctl restart "$UNIT_NAME"
  systemctl is-active --quiet "$UNIT_NAME" || die "the $UNIT_NAME service did not start"
  ok "pve-sensors-collect active — RRD at $DATA_DIR/sensors.rrd"
}

# Atomic: write a staging file next to the target and rename over it.
install_patched() {
  step "Installing the patched files (atomic)"
  local pair src dst
  for pair in "$TMP/Nodes.pm.new:$PM_FILE" "$TMP/pvemanagerlib.js.new:$JS_FILE"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    install -m "$(stat -c%a "$dst")" -o "$(stat -c%u "$dst")" -g "$(stat -c%g "$dst")" \
      "$src" "$dst.pve-sensors.staging"
    mv -f "$dst.pve-sensors.staging" "$dst"
  done
  ok "$PM_FILE and $JS_FILE updated"
}

do_install() {
  apply_to_copies patch
  verify_copies

  if [ "$WITH_GRAPH" -eq 1 ]; then
    install_collector
  elif [ -f "$UNIT_FILE" ]; then
    # --no-graph on an install that already had the chart: remove the collector too
    remove_collector
    log "Collector removed (--no-graph). History kept in $DATA_DIR"
  fi

  install_patched
}

restart_services() {
  step "Restarting pvedaemon and pveproxy"
  systemctl restart pvedaemon pveproxy || die "the restart failed"
  sleep 3
  local svc
  for svc in pvedaemon pveproxy; do
    systemctl is-active --quiet "$svc" \
      || die "$svc did NOT come up after the patch.
        Last log lines:
$(journalctl -u "$svc" -n 15 --no-pager 2>/dev/null | sed 's/^/        /')"
  done
  ok "pvedaemon and pveproxy active"
}

validate_api() {
  step "Validating the API"
  local node
  node="$(node_name)"

  pvesh get "/nodes/$node/status" --output-format json >/dev/null 2>&1 \
    || die "GET /nodes/$node/status broke after the patch"
  if pvesh get "/nodes/$node/status" --output-format json 2>/dev/null | grep -q '"thermalstate"'; then
    ok "/status returns 'thermalstate'"
  else
    warn "/status did not return 'thermalstate' (the API responds, but the field is missing)"
  fi

  pvesh get "/nodes/$node/rrddata" --timeframe hour --output-format json >/dev/null 2>&1 \
    || die "GET /nodes/$node/rrddata broke after the patch"
  ok "/rrddata responds normally"

  if [ "$WITH_GRAPH" -eq 1 ]; then
    if pvesh get "/nodes/$node/rrddata" --timeframe hour --output-format json 2>/dev/null | grep -q '"t_'; then
      ok "/rrddata already returns temperature series"
    else
      log "/rrddata has no t_* series yet — expected in the 1st minute (the RRD needs samples)"
    fi
  fi
}

# Remembers the options used, so the .deb can re-apply after a pve-manager
# upgrade. A revert forgets them, and upgrades stop re-applying.
save_state() {
  if [ "$MODE" = "patch" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    # only --no-graph / --panel-height get here; everything else exited earlier
    : > "$STATE_FILE"
    local arg
    for arg in "$@"; do printf '%s\n' "$arg" >> "$STATE_FILE"; done
  else
    rm -f "$STATE_FILE"
  fi
}

report() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [ "$MODE" = "revert" ] && echo "  Patches removed" || echo "  Temperatures enabled"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  if [ "$MODE" = "patch" ]; then
    echo "  IMPORTANT: do a HARD refresh in the browser (Ctrl+Shift+R),"
    echo "  otherwise it keeps serving pvemanagerlib.js from cache."
    echo ""
    echo "  Datacenter > $(node_name) > Summary"
    echo "    - 'Temperatures' line right below 'CPU(s)'  (current value)"
    if [ "$WITH_GRAPH" -eq 1 ]; then
      echo "    - 'Temperatures (°C)' panel next to the CPU/Network charts"
      echo ""
      echo "  The chart starts empty and fills at 1 sample/minute — give it ~5 min."
      echo "  History: 25h at 1min, 31d at 30min, 6 months at 3h, 2 years at 12h."
      echo ""
      echo "  Collector: systemctl status $UNIT_NAME"
      echo "  Series:    $COLLECTOR --list"
    fi
    echo ""
    echo "  Status:    $SELF --status"
    echo "  Backup:    $BACKUP_DIR"
    echo ""
    echo "  UNDO:"
    echo "    $SELF --revert            # keeps the history"
    echo "    $SELF --revert --purge    # deletes the history too"
    echo "    $BACKUP_DIR/RESTORE.sh    # emergency, without depending on this script"
    echo ""
    echo "  Changed hardware (new NVMe/GPU)? Run it again — the blocks are"
    echo "  regenerated and the chart starts plotting the new series."
    echo ""
    echo "  Every pve-manager upgrade removes the patches from the 2 files."
    echo "  Run it again (the .deb package does it for you) — the RRD history is NOT lost."
  fi
  echo ""
}
