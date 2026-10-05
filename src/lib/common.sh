# shellcheck shell=bash
# common.sh — logging helpers, temp dir, automatic rollback and traps.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

node_name() { hostname | cut -d. -f1; }

TMP="$(mktemp -d)"
BACKUP_DIR=""
ARMED=0              # 1 = we already touched /usr; an error from here on = rollback
INSTALLED_COLLECTOR=0

rollback() {
  echo ""
  echo -e "${RED}━━━ AUTOMATIC ROLLBACK ━━━${NC}" >&2
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    [ -f "$BACKUP_DIR/Nodes.pm" ]         && cp -a "$BACKUP_DIR/Nodes.pm"         "$PM_FILE" && echo "  restored: $PM_FILE" >&2
    [ -f "$BACKUP_DIR/pvemanagerlib.js" ] && cp -a "$BACKUP_DIR/pvemanagerlib.js" "$JS_FILE" && echo "  restored: $JS_FILE" >&2
  fi
  rm -f "$PM_FILE.pve-sensors.staging" "$JS_FILE.pve-sensors.staging" 2>/dev/null || true
  if [ "$INSTALLED_COLLECTOR" -eq 1 ]; then
    remove_collector
    echo "  removed: collector" >&2
  fi
  systemctl restart pvedaemon pveproxy >/dev/null 2>&1 || true
  echo -e "${YELLOW}  Proxmox was returned to its previous state.${NC}" >&2
  [ -n "$BACKUP_DIR" ] && echo "  Backup kept at: $BACKUP_DIR" >&2
  echo "" >&2
}

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ARMED" -eq 1 ]; then rollback; fi
  rm -rf "$TMP"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
