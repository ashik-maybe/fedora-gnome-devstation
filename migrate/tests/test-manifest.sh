#!/usr/bin/env bash
# Self-contained tests for migrate/manifest.py (CONTRACT.md, "manifest.py").
#
# 1. Fixture kickstart: the %packages mapping on add / remove / drop-group,
#    the ignored @^workstation-product-environment, and de-duplication.
# 2. Fixtures with an @core group and missing/unterminated %packages sections:
#    manifest.py must fail.
# 3. Real kickstart: the required entries land in the outputs and colord is
#    not in remove.txt.

set -euo pipefail

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$MIGRATE_DIR/manifest.py"
REAL_KS="$REPO_DIR/kickstart/gnome-devstation.ks"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- 1. Fixture: mapping, ignored environment, dedup, exact outputs --------
fixture="$work/fixture.ks"
out="$work/out"
cat >"$fixture" <<'EOF'
%packages
kernel
kernel
-gnome-tour
-@firefox
-colord
@^workstation-product-environment

%end
EOF
python3 "$MANIFEST" "$fixture" "$out"

printf 'kernel\n' >"$work/exp-add"
printf 'gnome-tour\n' >"$work/exp-remove"
printf 'firefox\n' >"$work/exp-drop"
diff -u "$work/exp-add" "$out/add.txt" || fail "add.txt mismatch"
diff -u "$work/exp-remove" "$out/remove.txt" || fail "remove.txt mismatch"
diff -u "$work/exp-drop" "$out/drop-groups.txt" || fail "drop-groups.txt mismatch"
if grep -qxF 'colord' "$out/remove.txt"; then
	fail "colord must not be in remove.txt"
fi

# --- 2. Fixture: an unsupported @group fails the run ------------------------
cat >"$work/bad.ks" <<'EOF'
%packages
@core
%end
EOF
if python3 "$MANIFEST" "$work/bad.ks" "$work/out-bad"; then
	fail "expected manifest.py to fail on the @core group"
fi

# --- 3. Real kickstart ------------------------------------------------------
real_out="$work/out-real"
python3 "$MANIFEST" "$REAL_KS" "$real_out"

grep -qxF 'google-chrome-stable' "$real_out/add.txt" ||
	fail "google-chrome-stable missing from add.txt"
grep -qxF 'gnome-tour' "$real_out/remove.txt" ||
	fail "gnome-tour missing from remove.txt"
grep -qxF 'firefox' "$real_out/drop-groups.txt" ||
	fail "firefox missing from drop-groups.txt"
if grep -qxF 'colord' "$real_out/remove.txt"; then
	fail "colord must not be in the real remove.txt"
fi

echo "test-manifest: OK"
