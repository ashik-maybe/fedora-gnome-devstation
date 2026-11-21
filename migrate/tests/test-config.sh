#!/usr/bin/env bash
# Test for migrate/steps/70-config.sh.
#
# Runs step_run against a temp ROOT and asserts:
#   - every expected file exists, is byte-identical to its source
#     (files/, repos/) and has mode 0644;
#   - `bash -n` passes on the installed profile;
#   - the dnf-automatic sed edits land in the pre-existing
#     $ROOT/etc/dnf/automatic.conf;
#   - dconf update is not run while ROOT != / (stub dconf; marker
#     absent);
#   - a same-content 0600 destination is corrected to 0644 by step_run;
#   - a second step_run leaves the content under $ROOT unchanged
#     (idempotency).
#
# Per CONTRACT.md, tests are self-contained with temp dirs / stubs and
# use the real repo files.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export REPO_DIR

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Keep the step's temp mimeapps file inside the test sandbox.
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
export STATE_DIR

ROOT="$WORK/root"
mkdir -p "$ROOT"
export ROOT

# Pre-existing dnf/automatic.conf with the kickstart's "bad" values, so
# the sed edits have something to change on the first run.
mkdir -p "$ROOT/etc/dnf"
cat >"$ROOT/etc/dnf/automatic.conf" <<'EOF'
apply_updates = no
upgrade_type = default
EOF

# Stub dconf: if the step ran it while ROOT != /, the marker would appear.
fakebin="$WORK/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/dconf" <<'EOF'
#!/bin/sh
touch "$FAKE_DCONF_MARKER"
EOF
chmod +x "$fakebin/dconf"
FAKE_DCONF_MARKER="$WORK/dconf-ran"
export FAKE_DCONF_MARKER
export PATH="$fakebin:$PATH"

source "$REPO_DIR/migrate/steps/70-config.sh"

# Pre-create one target with the right content but mode 0600: the step
# must correct the mode of a same-content destination.
install -Dm0600 "$REPO_DIR/files/90-devstation.sh" \
	"$ROOT/etc/profile.d/90-devstation.sh"

if ! step_run; then
	fail "step_run returned nonzero"
fi

expect() {
	local dest="$ROOT/$1" src="$2"
	[ -f "$dest" ] || fail "missing: $dest"
	cmp -s "$src" "$dest" || fail "differs from source: $dest"
	[ "$(stat -c %a "$dest")" = 644 ] ||
		fail "wrong mode on $dest: $(stat -c %a "$dest")"
}

expect "etc/profile.d/90-devstation.sh" "$REPO_DIR/files/90-devstation.sh"
expect "etc/dconf/profile/user" "$REPO_DIR/files/dconf-profile-user"
expect "etc/dconf/db/local.d/00-devstation" "$REPO_DIR/files/dconf-00-devstation"
expect "etc/yum.repos.d/google-chrome.repo" "$REPO_DIR/repos/google-chrome.repo"
expect "etc/yum.repos.d/helium-copr.repo" "$REPO_DIR/repos/helium-copr.repo"

# The installed profile must parse as valid bash.
bash -n "$ROOT/etc/profile.d/90-devstation.sh" ||
	fail "bash -n failed on installed profile"

# mimeapps.list matches the Chrome defaults the kickstart writes.
mime_expected="$WORK/expected-mimeapps.list"
cat >"$mime_expected" <<'EOF'
[Default Applications]
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
x-scheme-handler/about=google-chrome.desktop
text/html=google-chrome.desktop
application/xhtml+xml=google-chrome.desktop
EOF
cmp -s "$mime_expected" "$ROOT/etc/xdg/mimeapps.list" ||
	fail "mimeapps.list does not match the Chrome defaults"
[ "$(stat -c %a "$ROOT/etc/xdg/mimeapps.list")" = 644 ] ||
	fail "wrong mode on mimeapps.list"

# The dnf-automatic edits landed.
grep -q '^apply_updates = yes$' "$ROOT/etc/dnf/automatic.conf" ||
	fail "apply_updates not set to yes"
grep -q '^upgrade_type = security$' "$ROOT/etc/dnf/automatic.conf" ||
	fail "upgrade_type not set to security"

# dconf update must not run while ROOT != / (stub marker absent).
[ ! -e "$FAKE_DCONF_MARKER" ] ||
	fail "dconf update ran while ROOT != /"

# Second run: content under $ROOT must be unchanged.
snapshot() {
	(cd "$ROOT" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}
before=$(snapshot)
if ! step_run; then
	fail "second step_run returned nonzero"
fi
after=$(snapshot)
[ "$before" = "$after" ] || fail "second step_run changed content"

echo "PASS: test-config"
