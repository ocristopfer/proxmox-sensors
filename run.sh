#!/usr/bin/env bash
# run.sh — runs src/proxmox-enable-sensors.sh on a Proxmox host over SSH, from your machine.
#   The src/ folder is streamed as a tar into a temporary directory on the host,
#   run from there and removed at the end. Nothing is left behind.
#
#   ./run.sh <host> [--setup] [proxmox-enable-sensors.sh options]
#
#   ./run.sh 192.168.0.10 --setup      # installs lm-sensors/drivetemp and applies
#   ./run.sh 192.168.0.10 --dry-run    # shows the diff, changes nothing
#   ./run.sh 192.168.0.10              # applies
#   ./run.sh 192.168.0.10 --status
#   ./run.sh 192.168.0.10 --revert [--purge]
#
#   <host> without a user becomes root@<host>. Without <host>, uses $PVE_HOST.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/src"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "error: $*" >&2; exit 1; }

case "${1:-}" in -h|--help) usage ;; esac

HOST="${PVE_HOST:-}"
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then HOST="$1"; shift; fi
[ -n "$HOST" ] || usage 1
case "$HOST" in *@*) ;; *) HOST="root@$HOST" ;; esac
[ -f "$SRC/proxmox-enable-sensors.sh" ] || die "$SRC/proxmox-enable-sensors.sh not found"

SETUP=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --setup)   SETUP=1 ;;
    -h|--help) usage ;;
    *)         ARGS+=("$a") ;;
  esac
done

if [ "$SETUP" -eq 1 ]; then
  echo "━━━ Prerequisites on $HOST ━━━"
  ssh "$HOST" 'bash -s' <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v sensors >/dev/null; then
  apt-get update -qq && apt-get install -y -qq lm-sensors
fi
sensors-detect --auto >/dev/null
modprobe drivetemp || echo "warning: drivetemp module unavailable (no SATA temperatures)"
grep -qx drivetemp /etc/modules || echo drivetemp >> /etc/modules
sensors -j >/dev/null && echo "lm-sensors ok"
EOS
elif ! ssh -n "$HOST" 'command -v sensors >/dev/null'; then
  die "lm-sensors is not installed on $HOST — run again with --setup"
fi

# %q: each argument reaches the remote host exactly as typed
REMOTE_ARGS=""
[ ${#ARGS[@]} -gt 0 ] && REMOTE_ARGS="$(printf ' %q' "${ARGS[@]}")"
SELF_HINT="$(printf '%q' "./run.sh $HOST")"
# COPYFILE_DISABLE: keeps macOS tar from adding ._* metadata files
COPYFILE_DISABLE=1 tar -C "$SRC" -cf - . \
  | ssh "$HOST" "d=\$(mktemp -d) && trap 'rm -rf \$d' EXIT && tar -xf - -C \$d \
      && PVE_SENSORS_SELF=$SELF_HINT bash \$d/proxmox-enable-sensors.sh$REMOTE_ARGS"
