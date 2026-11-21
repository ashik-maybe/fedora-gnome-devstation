#!/usr/bin/env bash
# Tests for steps/40-repos.sh. Everything runs against a temp ROOT, a temp
# ASSETS_DIR and a stubbed `rpm` / `install`, so the real rpmdb is never touched.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
step_file="$here/../steps/40-repos.sh"

fail() {
	printf 'test-repos: FAIL: %s\n' "$*" >&2
	exit 1
}

ok() {
	printf 'ok: %s\n' "$*"
}

# --- sourcing must not change the caller's shell options -------------------
opts_before="$(set +o)"
# shellcheck disable=SC1090
source "$step_file"
opts_after="$(set +o)"
[ "$opts_before" = "$opts_after" ] ||
	fail "sourcing 40-repos.sh changed the caller's shell options"
ok "sourcing 40-repos.sh leaves shell options unchanged"

# --- stubs -----------------------------------------------------------------
# `rpm -q <pkg>` consults a per-workspace "installed" file; -Uvh adds to it.
rpm() {
	local log="$STATE_DIR/rpm-calls.log" installed="$STATE_DIR/rpm-installed"
	local pkg f
	printf '%s\n' "$*" >>"$log"
	case "${1:-}" in
	-q)
		pkg="${2:-}"
		[ -n "$pkg" ] || return 1
		if [ -f "$installed" ] && grep -qxF "$pkg" "$installed"; then
			return 0
		fi
		return 1
		;;
	-Uvh)
		for f in "$@"; do
			case "$f" in
			*rpmfusion-free-release.noarch.rpm)
				printf '%s\n' rpmfusion-free-release >>"$installed"
				;;
			*rpmfusion-nonfree-release.noarch.rpm)
				printf '%s\n' rpmfusion-nonfree-release >>"$installed"
				;;
			esac
		done
		return 0
		;;
	*)
		return 0
		;;
	esac
}

install() {
	printf '%s\n' "$*" >>"$STATE_DIR/install.log"
	command install "$@"
}

state_log() {
	printf '%s\n' "$*" >>"$STATE_DIR/state.log"
}

# --- fixture ---------------------------------------------------------------
work="$(mktemp -d)"
cleanup() {
	trap - EXIT
	rm -rf "$work"
}
trap cleanup EXIT

setup_workspace() {
	local base="$1" a
	STATE_DIR="$base/state"
	FAKE_ROOT="$base/root"
	ROOT="/"
	REPOS_TARGET="$FAKE_ROOT/etc/yum.repos.d"
	ASSETS_DIR="$base/assets"
	REPO_DIR="$base/repo"
	DRY_RUN=0
	FORCE=0
	mkdir -p "$STATE_DIR" "$REPOS_TARGET" "$ASSETS_DIR" "$REPO_DIR/repos"
	: >"$STATE_DIR/rpm-installed"
	: >"$STATE_DIR/rpm-calls.log"
	: >"$STATE_DIR/install.log"
	: >"$STATE_DIR/state.log"
	for a in rpmfusion-free-release.noarch.rpm \
		rpmfusion-nonfree-release.noarch.rpm \
		google-chrome.asc helium-copr.asc; do
		printf 'stub %s\n' "$a" >"$ASSETS_DIR/$a"
	done
	printf '[google-chrome]\nenabled=1\n' >"$REPO_DIR/repos/google-chrome.repo"
	printf '[copr:helium]\nenabled=1\n' >"$REPO_DIR/repos/helium-copr.repo"
	export STATE_DIR ROOT FAKE_ROOT REPOS_TARGET ASSETS_DIR REPO_DIR DRY_RUN FORCE
}

# --- first run does the work ------------------------------------------------
setup_workspace "$work/first"
step_run || fail "first step_run returned nonzero"

rpm_log="$STATE_DIR/rpm-calls.log"
grep -q -- "-Uvh --nosignature $ASSETS_DIR/rpmfusion-free-release.noarch.rpm" "$rpm_log" ||
	fail "first run did not install the free release RPM"
grep -q -- "-Uvh --nosignature $ASSETS_DIR/rpmfusion-nonfree-release.noarch.rpm" "$rpm_log" ||
	fail "first run did not install the nonfree release RPM"
grep -q -- "--import $ASSETS_DIR/google-chrome.asc" "$rpm_log" ||
	fail "first run did not import the google-chrome key"
grep -q -- "--import $ASSETS_DIR/helium-copr.asc" "$rpm_log" ||
	fail "first run did not import the helium COPR key"
for repo in google-chrome.repo helium-copr.repo; do
	cmp -s "$REPO_DIR/repos/$repo" "$REPOS_TARGET/$repo" ||
		fail "first run did not copy $repo into REPOS_TARGET"
done
for key in google-chrome.asc helium-copr.asc; do
	[ -f "$STATE_DIR/imported-keys/$key.imported" ] ||
		fail "first run did not record the import of $key"
done
[ "$(wc -l <"$STATE_DIR/install.log")" -eq 2 ] ||
	fail "first run did not install exactly two repo files"
ok "first run installs both release RPMs, copies both repos and imports both keys"

# --- second run is idempotent ----------------------------------------------
uvh_before="$(grep -c -- '-Uvh' "$rpm_log" || true)"
imp_before="$(grep -c -- '--import' "$rpm_log" || true)"
install_before="$(wc -l <"$STATE_DIR/install.log")"

step_run || fail "second step_run returned nonzero"

[ "$(grep -c -- '-Uvh' "$rpm_log" || true)" = "$uvh_before" ] ||
	fail "second run re-installed an already installed release RPM"
[ "$(grep -c -- '--import' "$rpm_log" || true)" = "$imp_before" ] ||
	fail "second run re-imported an already imported key"
[ "$(wc -l <"$STATE_DIR/install.log")" = "$install_before" ] ||
	fail "second run rewrote an identical repo file"
ok "second run performs no Uvh, no import and no repo-file rewrite"

# --- FORCE=1 re-imports keys despite markers --------------------------------
imp_before_force="$(grep -c -- '--import' "$rpm_log" || true)"
FORCE=1
step_run || fail "FORCE step_run returned nonzero"
[ "$(grep -c -- '--import' "$rpm_log" || true)" -gt "$imp_before_force" ] ||
	fail "FORCE=1 did not re-import keys when markers were present"
for key in google-chrome.asc helium-copr.asc; do
	[ -f "$STATE_DIR/imported-keys/$key.imported" ] ||
		fail "FORCE=1 did not refresh the import marker for $key"
done
ok "FORCE=1 re-imports keys and refreshes markers"

# --- ROOT != / is refused ---------------------------------------------------
setup_workspace "$work/root-guard"
ROOT="$FAKE_ROOT"
: >"$STATE_DIR/rpm-calls.log"
: >"$STATE_DIR/install.log"
if step_run; then
	fail "step_run returned 0 when ROOT != /"
fi
[ "$(wc -l <"$STATE_DIR/rpm-calls.log")" -eq 0 ] ||
	fail "ROOT != / guard must not call rpm"
[ -z "$(find "$REPOS_TARGET" -type f -print -quit)" ] ||
	fail "ROOT != / guard must not write repo files"
[ ! -e "$STATE_DIR/imported-keys" ] ||
	fail "ROOT != / guard must not create key import markers"
ok "ROOT != / is refused with no rpm calls and no repo files written"

# --- DRY_RUN writes nothing -------------------------------------------------
setup_workspace "$work/dry"
DRY_RUN=1
step_run || fail "DRY_RUN step_run returned nonzero"
[ "$(grep -c -- '-Uvh' "$STATE_DIR/rpm-calls.log" || true)" -eq 0 ] ||
	fail "DRY_RUN called rpm -Uvh"
[ "$(grep -c -- '--import' "$STATE_DIR/rpm-calls.log" || true)" -eq 0 ] ||
	fail "DRY_RUN called rpm --import"
[ -z "$(find "$REPOS_TARGET" -type f -print -quit)" ] ||
	fail "DRY_RUN created files under REPOS_TARGET"
[ ! -e "$STATE_DIR/imported-keys" ] || fail "DRY_RUN created key import markers"
[ ! -s "$STATE_DIR/install.log" ] || fail "DRY_RUN copied a repo file"
ok "DRY_RUN only prints: no rpm writes, no ROOT files and no markers"

# --- state_log fallback still works ----------------------------------------
setup_workspace "$work/fallback"
(
	unset -f state_log
	step_run
) || fail "step_run failed when state_log is absent (fallback path)"
grep -q -- '-Uvh' "$STATE_DIR/rpm-calls.log" ||
	fail "fallback path did not install the release RPMs"
[ -f "$REPOS_TARGET/google-chrome.repo" ] ||
	fail "fallback path did not copy the repo files"
ok "step_run works with the declare -F state_log fallback"

# --- failures are reported to the runner -----------------------------------
setup_workspace "$work/fail"
rm -f "$ASSETS_DIR/helium-copr.asc"
if step_run; then
	fail "step_run returned 0 with a missing staged key"
fi
ok "step_run returns nonzero when a staged asset is missing"

echo "all 40-repos.sh tests passed"
