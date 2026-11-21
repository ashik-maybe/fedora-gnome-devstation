#!/usr/bin/env bash
# Test for migrate/steps/80-flatpak.sh: the step issues the Flathub remote-add
# and the three installs, warns instead of failing when flatpak fails, and
# issues nothing under DRY_RUN=1.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STEP="$REPO_DIR/migrate/steps/80-flatpak.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/bin/flatpak"
LOG="$TMP/flatpak.log"
WARN="$TMP/warnings.txt"
FAIL="$TMP/fail"

mkdir -p "$TMP/bin"

# Stub flatpak: logs its arguments; exits non-zero when the FAIL flag exists.
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FLATPAK_LOG"
if [ -f "$FLATPAK_FAIL" ]; then
	echo "stub: forced failure" >&2
	exit 1
fi
exit 0
EOF
chmod +x "$STUB"

export FLATPAK_BIN="$STUB"
export FLATPAK_LOG="$LOG"
export FLATPAK_FAIL="$FAIL"

# shellcheck disable=SC1091
source "$STEP"

# Scenario 1: a healthy run issues the remote-add and the three installs.
rm -f "$FAIL"
: >"$LOG"
step_run
grep -qxF 'remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' "$LOG"
grep -qxF 'install -y --system flathub com.github.tchx84.Flatseal' "$LOG"
grep -qxF 'install -y --system flathub com.mattjakeman.ExtensionManager' "$LOG"
grep -qxF 'install -y --system flathub it.mijorus.gearlever' "$LOG"
[ "$(grep -c '^install ' "$LOG")" -eq 3 ]

# Scenario 2: a failing flatpak still returns 0 and emits warnings.
: >"$LOG"
touch "$FAIL"
status=0
step_run 2>"$WARN" || status=$?
[ "$status" -eq 0 ]
grep -q 'WARNING' "$WARN"

# Scenario 3: DRY_RUN=1 issues no calls; it prints the commands instead.
rm -f "$FAIL"
: >"$LOG"
out="$(DRY_RUN=1 step_run)"
[ ! -s "$LOG" ]
printf '%s\n' "$out" | grep -qF 'remote-add --if-not-exists flathub'
printf '%s\n' "$out" | grep -qF 'install -y --system flathub com.github.tchx84.Flatseal'
printf '%s\n' "$out" | grep -qF 'install -y --system flathub com.mattjakeman.ExtensionManager'
printf '%s\n' "$out" | grep -qF 'install -y --system flathub it.mijorus.gearlever'

# Scenario 4: ROOT != / — the live host; the stub records zero calls and the
# step returns 0.
: >"$LOG"
# shellcheck disable=SC2034 # read by the sourced step under test
ROOT="$TMP/root"
status=0
step_run || status=$?
unset ROOT
[ "$status" -eq 0 ]
[ ! -s "$LOG" ]

# Scenario 5: sourcing leaves the caller's shell options unchanged — the
# strict mode now lives inside step_run instead of at file scope.
(
	set +e
	flags_before="$-"
	# shellcheck disable=SC1091
	source "$STEP"
	[ "$flags_before" = "$-" ]
)

echo "test-flatpak: OK"
