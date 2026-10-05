# shellcheck shell=bash
# checks.sh — pre-checks and dependency validation.

preflight() {
  [ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox host"
  command -v pveversion &>/dev/null || die "'pveversion' not found — run this on the Proxmox host"
  command -v systemctl  &>/dev/null || die "'systemctl' not found"
  [ -f "$PM_FILE" ] || die "$PM_FILE not found"
  [ -f "$JS_FILE" ] || die "$JS_FILE not found"
  [ -w "$PM_FILE" ] || die "No write permission on $PM_FILE"
  [ -w "$JS_FILE" ] || die "No write permission on $JS_FILE"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Proxmox — Temperatures in the node Summary"
  echo "  Mode:     $MODE$([ "$WITH_GRAPH" -eq 0 ] && echo ' (no chart)')"
  echo "  Node:     $(node_name)"
  echo "  Version:  $(pveversion | head -1)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

check_dependencies() {
  step "Checking dependencies"

  [ -x "$SENSORS_BIN" ] || die "'$SENSORS_BIN' does not exist. First run: apt install -y lm-sensors && sensors-detect --auto"

  # same tolerance as the collector: some lm-sensors versions emit a trailing comma
  local json chips
  json="$(timeout 10 "$SENSORS_BIN" -j 2>/dev/null | sed -E ':a;N;$!ba;s/,[[:space:]]*([]}])/\1/g' || true)"
  if ! printf '%s' "$json" | perl -MJSON::PP -e 'local $/; decode_json(<STDIN>);' 2>/dev/null; then
    die "'sensors -j' did not return valid JSON. Check the output of: sensors -j"
  fi

  chips="$(printf '%s' "$json" | perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); print join(", ", sort keys %$d);')"
  ok "Chips detected: ${chips:-none}"
  [ -n "$chips" ] || warn "No chips — the line will show N/A until sensors-detect finds something"

  if [ "$WITH_GRAPH" -eq 1 ] && ! perl -MRRDs -e1 2>/dev/null; then
    if [ "$MODE" = "dry-run" ]; then
      warn "perl module RRDs missing — the script would install the 'librrds-perl' package"
    else
      log "Installing librrds-perl (needed for the chart)..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y librrds-perl >/dev/null 2>&1 \
        || die "failed to install librrds-perl (repository unavailable?).
        Nothing was changed. Run with --no-graph to install only the text line."
      ok "librrds-perl installed"
    fi
  fi
}
