#!/usr/bin/env bash
# run.sh — roda o proxmox-enable-sensors.sh num host Proxmox via SSH, da sua máquina.
#
#   ./run.sh <host> [--setup] [opções do proxmox-enable-sensors.sh]
#
#   ./run.sh 192.168.0.10 --setup      # instala lm-sensors/drivetemp e aplica
#   ./run.sh 192.168.0.10 --dry-run    # mostra o diff, não altera nada
#   ./run.sh 192.168.0.10              # aplica
#   ./run.sh 192.168.0.10 --status
#   ./run.sh 192.168.0.10 --revert [--purge]
#
#   <host> sem usuário vira root@<host>. Sem <host>, usa $PVE_HOST.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$DIR/proxmox-enable-sensors.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "erro: $*" >&2; exit 1; }

case "${1:-}" in -h|--help) usage ;; esac

HOST="${PVE_HOST:-}"
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then HOST="$1"; shift; fi
[ -n "$HOST" ] || usage 1
case "$HOST" in *@*) ;; *) HOST="root@$HOST" ;; esac
[ -f "$SCRIPT" ] || die "não achei $SCRIPT"

SETUP=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --setup)   SETUP=1 ;;
    -h|--help) usage ;;
    *)         ARGS+=("$a") ;;
  esac
done

if [ "$SETUP" -eq 1 ]; then
  echo "━━━ Pré-requisitos em $HOST ━━━"
  ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v sensors >/dev/null; then
  apt-get update -qq && apt-get install -y -qq lm-sensors
fi
sensors-detect --auto >/dev/null
modprobe drivetemp || echo "aviso: módulo drivetemp indisponível (sem temperatura de SATA)"
grep -qx drivetemp /etc/modules || echo drivetemp >> /etc/modules
sensors -j >/dev/null && echo "lm-sensors ok"
EOF
elif ! ssh -n "$HOST" 'command -v sensors >/dev/null'; then
  die "lm-sensors não está instalado em $HOST — rode de novo com --setup"
fi

# %q: cada argumento chega ao host remoto exatamente como foi digitado
REMOTE_ARGS=""
[ ${#ARGS[@]} -gt 0 ] && REMOTE_ARGS="$(printf ' %q' "${ARGS[@]}")"
ssh "$HOST" "bash -s --$REMOTE_ARGS" < "$SCRIPT"
