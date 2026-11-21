#!/usr/bin/env bash
# Step 80-flatpak: add the Flathub remote and install the three Flatpaks this
# image standardises on, mirroring section 6 of kickstart/gnome-devstation.ks
# (Flatseal, Extension Manager, Gear Lever).
#
# Warn-don't-fail, like the kickstart: a network failure or a missing app
# warns and the step still returns 0, because an unreachable Flathub must not
# sink an otherwise good install. A --root DIR (ROOT != /) warns and returns 0
# too: without the guard the step would call flatpak on the live host.

# lib/state.sh belongs to the state segment. When this segment's tree lacks it
# the step still runs and warnings fall back to stderr.
if [ -z "${_LIB_STATE_LOADED:-}" ]; then
	_LIB_STATE_LOADED=1
	if [ -f "${REPO_DIR:-}/migrate/lib/state.sh" ]; then
		# shellcheck disable=SC1091
		source "${REPO_DIR:-}/migrate/lib/state.sh"
	fi
fi

# The three Flatpaks the image standardises on.
FLATPAK_APPS=(
	com.github.tchx84.Flatseal
	com.mattjakeman.ExtensionManager
	it.mijorus.gearlever
)

# Progress log: state_log when a segment has installed it, stderr otherwise.
_flatpak_log() {
	if declare -F state_log >/dev/null 2>&1; then
		state_log "$*" || true
	else
		echo "$*"
	fi
	return 0
}

# Warning: state_log when available, stderr otherwise. Never fails the caller.
_flatpak_warn() {
	if declare -F state_log >/dev/null 2>&1; then
		state_log "WARNING: $*" || true
	else
		echo "WARNING: $*" >&2
	fi
	return 0
}

# Run one flatpak operation. In DRY_RUN print it and issue nothing; otherwise
# warn on failure instead of failing the step.
_flatpak_run() {
	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '%s %s\n' "$FLATPAK_BIN" "$*"
		return 0
	fi
	if ! "$FLATPAK_BIN" "$@"; then
		_flatpak_warn "flatpak $*"
	fi
	return 0
}

# Warn when an app is not actually installed after the installs. Warn-don't-fail.
_flatpak_verify() {
	local app
	if [ "${DRY_RUN:-0}" = "1" ]; then
		return 0
	fi
	for app in "${FLATPAK_APPS[@]}"; do
		if ! "$FLATPAK_BIN" info "$app" >/dev/null 2>&1; then
			_flatpak_warn "$app not installed; run 'flatpak install -y --system flathub $app' manually"
		fi
	done
}

step_run() {
	(
		set -euo pipefail

		# Root guard: flatpak installs onto the live host, so with ROOT != /
		# (a --root DIR fixture) the step must not run the real calls. Warn and
		# return 0, like the rest of the step.
		if [ "${ROOT:-/}" != "/" ]; then
			_flatpak_warn "skipping Flathub/Flatpaks: ROOT != / (live system)"
			exit 0
		fi

		# ${FLATPAK_BIN:-flatpak} so tests can stub the binary.
		FLATPAK_BIN="${FLATPAK_BIN:-flatpak}"

		_flatpak_log "adding the Flathub remote"
		_flatpak_run remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

		local app
		for app in "${FLATPAK_APPS[@]}"; do
			_flatpak_log "installing $app"
			_flatpak_run install -y --system flathub "$app"
		done

		_flatpak_verify
	)
}

step_plan() {
	echo "add the Flathub remote and install: ${FLATPAK_APPS[*]}"
}
