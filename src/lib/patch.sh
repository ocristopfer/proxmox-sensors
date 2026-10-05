# shellcheck shell=bash
# patch.sh — patches temporary copies and proves they are safe and reversible.
# Nothing in /usr is touched here.

PATCH_PM="$SRC_DIR/patchers/patch-nodes-pm.pl"
PATCH_JS="$SRC_DIR/patchers/patch-pvemanagerlib.pl"
JS_SNIPPET="$SRC_DIR/web/sensors-item.js"

# $1 = patch | revert
apply_to_copies() {
  cp -a "$PM_FILE" "$TMP/Nodes.pm.new"
  cp -a "$JS_FILE" "$TMP/pvemanagerlib.js.new"
  perl "$PATCH_PM" "$TMP/Nodes.pm.new" "$1" "$WITH_GRAPH" \
    || die "patching $PM_FILE failed. NOTHING was changed."
  perl "$PATCH_JS" "$TMP/pvemanagerlib.js.new" "$1" "$JS_SNIPPET" "$FIELDS_JS" "$TITLES_JS" "$PANEL_BUMP" "$PANEL_HEIGHT" \
    || die "patching $JS_FILE failed. NOTHING was changed."
}

verify_copies() {
  step "Validating the result (nothing installed yet)"

  # 1 — perl -c: invalid perl here means a dead pvedaemon later. Blocking.
  if perl -c "$PM_FILE" >/dev/null 2>&1; then
    perl -c "$TMP/Nodes.pm.new" >/dev/null 2>&1 \
      || die "the patched Nodes.pm does NOT compile. NOTHING was changed.
        Run: perl -c $TMP/Nodes.pm.new  (to see the error)"
    ok "perl -c on the patched Nodes.pm: passed"
  else
    warn "the ORIGINAL Nodes.pm already doesn't compile in this environment — skipping perl -c"
  fi

  # 2 — end-to-end proof of reversibility.
  #
  # BASE = the original PVE file, i.e. what is installed in /usr with OUR
  # blocks removed. On a re-install the file in /usr is already patched from
  # the previous run; comparing against it directly would give a false
  # negative (and the size check would break if the labels got shorter).
  # The correct invariant is: revert(new) == revert(installed).
  cp -a "$PM_FILE" "$TMP/Nodes.pm.base"
  cp -a "$JS_FILE" "$TMP/pvemanagerlib.js.base"
  perl "$PATCH_PM" "$TMP/Nodes.pm.base"         revert >/dev/null \
    || die "could not rebuild the original of $PM_FILE. NOTHING was changed."
  perl "$PATCH_JS" "$TMP/pvemanagerlib.js.base" revert >/dev/null \
    || die "could not rebuild the original of $JS_FILE. NOTHING was changed."

  cp -a "$TMP/Nodes.pm.new"         "$TMP/Nodes.pm.rt"
  cp -a "$TMP/pvemanagerlib.js.new" "$TMP/pvemanagerlib.js.rt"
  perl "$PATCH_PM" "$TMP/Nodes.pm.rt"         revert >/dev/null || die "test revert failed"
  perl "$PATCH_JS" "$TMP/pvemanagerlib.js.rt" revert >/dev/null || die "test revert failed"

  cmp -s "$TMP/Nodes.pm.rt" "$TMP/Nodes.pm.base" \
    || die "PROOF OF REVERSIBILITY FAILED on $PM_FILE. NOTHING was changed."
  cmp -s "$TMP/pvemanagerlib.js.rt" "$TMP/pvemanagerlib.js.base" \
    || die "PROOF OF REVERSIBILITY FAILED on $JS_FILE. NOTHING was changed."
  ok "reversibility proven: --revert returns both files to the PVE original, byte by byte"

  # 3 — sanity: the patch can only have GROWN the original file
  local pair o n
  for pair in "$TMP/Nodes.pm.base:$TMP/Nodes.pm.new" "$TMP/pvemanagerlib.js.base:$TMP/pvemanagerlib.js.new"; do
    o="${pair%%:*}"; n="${pair##*:}"
    [ "$(stat -c%s "$n")" -ge "$(stat -c%s "$o")" ] \
      || die "the patched file got SMALLER than the PVE original. NOTHING was changed."
  done
  ok "no original content was removed"
}

show_dry_run() {
  step "Dry-run — nothing will be changed"
  apply_to_copies patch
  verify_copies
  echo ""
  echo "--- diff: $PM_FILE ---"; diff -u "$PM_FILE" "$TMP/Nodes.pm.new" || true
  echo ""
  echo "--- diff: $JS_FILE ---"; diff -u "$JS_FILE" "$TMP/pvemanagerlib.js.new" || true
  echo ""
  echo "--- files that would be created (none overwrites anything from PVE) ---"
  echo "  $COLLECTOR"
  echo "  $MOD_FILE"
  echo "  $UNIT_FILE"
  echo "  $DATA_DIR/sensors.rrd"
  echo ""
  ok "Dry-run done — run without --dry-run to apply"
}
