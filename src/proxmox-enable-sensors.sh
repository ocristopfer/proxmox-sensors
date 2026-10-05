#!/usr/bin/env bash
# proxmox-enable-sensors.sh — Temperatures (CPU / GPU / NVMe / HDD) in Proxmox VE:
#                             a line in the node Summary + a history chart
#
# USAGE (on the Proxmox host, as root):
#   proxmox-enable-sensors.sh                    apply (idempotent)
#   proxmox-enable-sensors.sh --dry-run          show the diff, change nothing
#   proxmox-enable-sensors.sh --status           show the current state
#   proxmox-enable-sensors.sh --no-graph         text line only, no chart
#   proxmox-enable-sensors.sh --panel-height=N   force the Summary panel height
#   proxmox-enable-sensors.sh --revert           undo everything (keeps history)
#   proxmox-enable-sensors.sh --revert --purge   undo and delete the history
#
# PREREQUISITES:
#   apt install -y lm-sensors && sensors-detect --auto
#   modprobe drivetemp && echo drivetemp >> /etc/modules   # SATA temps
#
# WHAT IT CHANGES:
#   Nodes.pm          'thermalstate' in GET /nodes/{node}/status and the
#                     temperature series merged into GET /nodes/{node}/rrddata
#   pvemanagerlib.js  "Temperatures" line + chart panel in the node Summary
#   + pve-sensors-collect (systemd service) writing /var/lib/pve-sensors/sensors.rrd
#
# SAFETY: backup first, everything is patched on copies, 'perl -c' and a
# byte-by-byte proof of reversibility before touching /usr, atomic install,
# health check after the restart and automatic rollback on any error.
# Details in the README.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SRC_DIR/lib/common.sh" ] \
  || { echo "error: $SRC_DIR/lib not found — run it from the project's src/ (or use run.sh)" >&2; exit 1; }

# =============================================================================
# Configuration (overridable through the environment, mainly for tests)
# =============================================================================
PM_FILE="${PM_FILE:-/usr/share/perl5/PVE/API2/Nodes.pm}"
JS_FILE="${JS_FILE:-/usr/share/pve-manager/js/pvemanagerlib.js}"
MOD_FILE="${MOD_FILE:-/usr/share/perl5/PVE/SensorsRRD.pm}"
COLLECTOR="${COLLECTOR:-/usr/local/bin/pve-sensors-collect}"
UNIT_NAME="pve-sensors-collect.service"
UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/$UNIT_NAME}"
DATA_DIR="${DATA_DIR:-/var/lib/pve-sensors}"
SENSORS_BIN="${SENSORS_BIN:-/usr/bin/sensors}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/pve-sensors-mod}"
# Options of the last install. The .deb package uses this file to re-apply
# the patches on its own when a pve-manager upgrade removes them.
STATE_FILE="${STATE_FILE:-$DATA_DIR/applied-args}"
# How the report tells the user to call us again (the .deb sets "pve-sensors").
SELF="${PVE_SENSORS_SELF:-bash $0}"

# =============================================================================
# Arguments
# =============================================================================
MODE="patch"
WITH_GRAPH=1
PURGE=0
PANEL_HEIGHT=""
for arg in "$@"; do
  case "$arg" in
    --revert)   MODE="revert" ;;
    --dry-run)  MODE="dry-run" ;;
    --status)   MODE="status" ;;
    --no-graph) WITH_GRAPH=0 ;;
    --purge)    PURGE=1 ;;
    --panel-height=*) PANEL_HEIGHT="${arg#*=}" ;;
    -h|--help)  awk 'NR==1{next} /^set -euo pipefail$/{exit} {print}' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

if [ "$PURGE" -eq 1 ] && [ "$MODE" != "revert" ]; then
  echo "--purge only makes sense together with --revert" >&2; exit 1
fi

# shellcheck source=lib/common.sh
. "$SRC_DIR/lib/common.sh"
# shellcheck source=lib/status.sh
. "$SRC_DIR/lib/status.sh"
# shellcheck source=lib/checks.sh
. "$SRC_DIR/lib/checks.sh"
# shellcheck source=lib/series.sh
. "$SRC_DIR/lib/series.sh"
# shellcheck source=lib/patch.sh
. "$SRC_DIR/lib/patch.sh"
# shellcheck source=lib/install.sh
. "$SRC_DIR/lib/install.sh"

# =============================================================================
# Main
# =============================================================================
if [ "$MODE" = "status" ]; then
  show_status
  exit 0
fi

preflight

if [ "$MODE" != "revert" ]; then
  check_dependencies
  detect_series
  if [ -n "$PANEL_HEIGHT" ]; then log "panel height forced to ${PANEL_HEIGHT}px (--panel-height)"; fi
fi

if [ "$MODE" = "dry-run" ]; then
  show_dry_run
  exit 0
fi

backup_originals          # arms the automatic rollback

if [ "$MODE" = "revert" ]; then
  do_revert
else
  do_install
fi

restart_services
if [ "$MODE" = "patch" ]; then validate_api; fi

ARMED=0                   # all good; disarm the automatic rollback

save_state "$@"
report
