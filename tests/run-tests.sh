#!/usr/bin/env bash
# run-tests.sh — offline tests: no Proxmox needed.
#
#   tests/run-tests.sh
#
# Runs the patchers against minimal stand-ins of the PVE files
# (tests/fixtures) and checks that patch + revert is byte-for-byte reversible,
# that re-applying is idempotent and that the collector classifies the sensors
# correctly. The end-to-end --dry-run test needs root (the script refuses to
# run otherwise) and is skipped without it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
FIX="$ROOT/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { echo "  ok    $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

export PERL5LIB="$ROOT/tests/stubs${PERL5LIB:+:$PERL5LIB}"
export SENSORS_BIN="$ROOT/tests/bin/sensors"
export NVIDIA_SMI=/nonexistent

PM="$SRC/patchers/patch-nodes-pm.pl"
JS="$SRC/patchers/patch-pvemanagerlib.pl"
SNIPPET="$SRC/web/sensors-item.js"
FIELDS="'t_cpu', 't_nvme0'"
TITLES="'CPU', 'NVMe 0'"

echo "syntax"
for f in "$SRC/collector/pve-sensors-collect" "$SRC/perl/PVE/SensorsRRD.pm" "$PM" "$JS" "$FIX/Nodes.pm"; do
  check "perl -c ${f#"$ROOT"/}" perl -c "$f"
done

echo "collector"
LIST="$(perl "$SRC/collector/pve-sensors-collect" --list)"
expect_series() { printf '%s\n' "$LIST" | grep -qx "$1"; }
check "cpu = Package id 0"            expect_series $'cpu\tCPU'
check "cpu_max present"               expect_series $'cpu_max\tCPU max'
check "board = SYSTIN (garbage drop)" expect_series $'board\tBoard'
check "nvme0 from Composite"          expect_series $'nvme0\tNVMe 0'
check "disk0 short label"             expect_series $'disk0\tscsi-0-0'
check "disk1 (trailing comma JSON)"   expect_series $'disk1\tscsi-1-0'
check "exactly 6 series"              test "$(printf '%s\n' "$LIST" | wc -l)" -eq 6

echo "Nodes.pm"
cp "$FIX/Nodes.pm" "$WORK/Nodes.pm"
check "patch with graph"        perl "$PM" "$WORK/Nodes.pm" patch 1
check "thermalstate inserted"   grep -q 'thermalstate' "$WORK/Nodes.pm"
check "rrddata merge inserted"  grep -q 'PVE::SensorsRRD::merge' "$WORK/Nodes.pm"
check "RRD name reused"         grep -q '"pve2-node/$param->{node}", $param->{timeframe}' "$WORK/Nodes.pm"
check "patched file compiles"   perl -c "$WORK/Nodes.pm"
cp "$WORK/Nodes.pm" "$WORK/Nodes.pm.once"
check "re-patch"                perl "$PM" "$WORK/Nodes.pm" patch 1
check "re-patch is idempotent"  cmp -s "$WORK/Nodes.pm" "$WORK/Nodes.pm.once"
check "revert"                  perl "$PM" "$WORK/Nodes.pm" revert
check "revert == original"      cmp -s "$WORK/Nodes.pm" "$FIX/Nodes.pm"
check "patch without graph"     perl "$PM" "$WORK/Nodes.pm" patch 0
check "  no rrddata block"      sh -c "! grep -q PVE-SENSORS-RRD '$WORK/Nodes.pm'"
check "  revert == original"    sh -c "perl '$PM' '$WORK/Nodes.pm' revert && cmp -s '$WORK/Nodes.pm' '$FIX/Nodes.pm'"

echo "pvemanagerlib.js"
cp "$FIX/pvemanagerlib.js" "$WORK/lib.js"
check "patch with chart"        perl "$JS" "$WORK/lib.js" patch "$SNIPPET" "$FIELDS" "$TITLES" 90 0
check "Temperatures line"       grep -q "itemId: 'thermal'" "$WORK/lib.js"
check "model fields"            grep -q "PVE-SENSORS-FIELDS-BEGIN" "$WORK/lib.js"
check "chart panel"             grep -q "PVE-SENSORS-CHART-BEGIN" "$WORK/lib.js"
check "height bumped 350->440"  grep -q "height: 440, // PVE-SENSORS-MOD height was 350" "$WORK/lib.js"
check "minHeight 360->440"      grep -q "minHeight: 440, // PVE-SENSORS-MOD minHeight was 360" "$WORK/lib.js"
check "line goes after CPU(s)"  sh -c "awk '/itemId: .cpus./{c=NR} /itemId: .thermal./{t=NR} END{exit !(c && t > c)}' '$WORK/lib.js'"
if command -v node >/dev/null; then
  check "patched JS parses"     node --check "$WORK/lib.js"
fi
cp "$WORK/lib.js" "$WORK/lib.js.once"
check "re-patch"                perl "$JS" "$WORK/lib.js" patch "$SNIPPET" "$FIELDS" "$TITLES" 90 0
check "re-patch is idempotent"  cmp -s "$WORK/lib.js" "$WORK/lib.js.once"
check "revert"                  perl "$JS" "$WORK/lib.js" revert
check "revert == original"      cmp -s "$WORK/lib.js" "$FIX/pvemanagerlib.js"
check "--panel-height=500"      sh -c "perl '$JS' '$WORK/lib.js' patch '$SNIPPET' '' '' 90 500 && grep -q 'height: 500,' '$WORK/lib.js'"
check "  revert == original"    sh -c "perl '$JS' '$WORK/lib.js' revert && cmp -s '$WORK/lib.js' '$FIX/pvemanagerlib.js'"

echo "entrypoint"
check "--help"                    bash "$SRC/proxmox-enable-sensors.sh" --help
check "unknown arg is rejected"   sh -c "! bash '$SRC/proxmox-enable-sensors.sh' --bogus"
check "--purge needs --revert"    sh -c "! bash '$SRC/proxmox-enable-sensors.sh' --purge"
if [ "$(id -u)" -eq 0 ]; then
  cp "$FIX/Nodes.pm" "$WORK/e2e-Nodes.pm"
  cp "$FIX/pvemanagerlib.js" "$WORK/e2e-lib.js"
  OUT="$WORK/dry-run.log"
  if PATH="$ROOT/tests/bin:$PATH" PM_FILE="$WORK/e2e-Nodes.pm" JS_FILE="$WORK/e2e-lib.js" \
       bash "$SRC/proxmox-enable-sensors.sh" --dry-run >"$OUT" 2>&1; then
    pass "--dry-run end to end"
  else
    fail "--dry-run end to end"; sed 's/^/        /' "$OUT"
  fi
  check "  reversibility proven"  grep -q "reversibility proven" "$OUT"
  check "  6 series detected"     grep -q "6 series will be plotted" "$OUT"
  check "  files left untouched"  sh -c "cmp -s '$FIX/Nodes.pm' '$WORK/e2e-Nodes.pm' && cmp -s '$FIX/pvemanagerlib.js' '$WORK/e2e-lib.js'"
else
  echo "  skip  --dry-run end to end (needs root)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
