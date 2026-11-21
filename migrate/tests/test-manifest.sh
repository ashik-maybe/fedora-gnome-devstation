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

# --- 2b. Malformed empty names fail loudly ---------------------------------
cat >"$work/empty-neg.ks" <<'EOF'
%packages
-
%end
EOF
if python3 "$MANIFEST" "$work/empty-neg.ks" "$work/out-empty-neg"; then
	fail "expected manifest.py to fail on empty negation '-'"
fi

cat >"$work/empty-drop.ks" <<'EOF'
%packages
-@
%end
EOF
if python3 "$MANIFEST" "$work/empty-drop.ks" "$work/out-empty-drop"; then
	fail "expected manifest.py to fail on empty drop-group '-@'"
fi

# --- 2c. Edge cases: header options, KEEP, comments, CRLF, dedup -----------
cat >"$work/edge.ks" <<'EOF'
%packages --nocore --excludeWeakdeps
# comment should be ignored
kernel
kernel
-gnome-tour
-gnome-tour
-colord
-cups-pk-helper
-libglvnd-gles
-@firefox
-@firefox
@^workstation-product-environment
%end
EOF
python3 "$MANIFEST" "$work/edge.ks" "$work/out-edge"
printf 'kernel\n' >"$work/exp-edge-add"
printf 'gnome-tour\n' >"$work/exp-edge-remove"
printf 'firefox\n' >"$work/exp-edge-drop"
diff -u "$work/exp-edge-add" "$work/out-edge/add.txt" || fail "edge add.txt mismatch"
diff -u "$work/exp-edge-remove" "$work/out-edge/remove.txt" || fail "edge remove.txt mismatch"
diff -u "$work/exp-edge-drop" "$work/out-edge/drop-groups.txt" || fail "edge drop-groups.txt mismatch"
for kept in colord cups-pk-helper libglvnd-gles; do
	if grep -qxF "$kept" "$work/out-edge/remove.txt"; then
		fail "$kept must not be in remove.txt"
	fi
done

# CRLF line endings must be accepted.
python3 - "$work/crlf.ks" <<'PY'
import sys
path = sys.argv[1]
text = '%packages\r\nkernel\r\n-gnome-tour\r\n-@firefox\r\n%end\r\n'
open(path, 'w', newline='').write(text)
PY
python3 "$MANIFEST" "$work/crlf.ks" "$work/out-crlf"
diff -u "$work/exp-edge-add" "$work/out-crlf/add.txt" || fail "CRLF add.txt mismatch"
diff -u "$work/exp-edge-remove" "$work/out-crlf/remove.txt" || fail "CRLF remove.txt mismatch"
diff -u "$work/exp-edge-drop" "$work/out-crlf/drop-groups.txt" || fail "CRLF drop-groups.txt mismatch"

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
