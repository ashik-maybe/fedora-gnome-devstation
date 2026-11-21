#!/usr/bin/env bash
# Persistent state for the migration runner: step markers, the interrupt flag
# and the run log. Everything lives under $STATE_DIR.
#
#   $STATE_DIR/steps/<id>.done   marker: sha256(step file) / UTC time / id
#   $STATE_DIR/interrupted       written by state_mark_interrupted, names the step
#   $STATE_DIR/migrate.log       tee'd by migrate.sh; state_log writes stdout only
#
# Marker writes are atomic (mktemp + mv in the same directory): the marker is
# the only record that a step finished, so a crash mid-write must not leave a
# half-written marker behind.
#
# The lock is flock(1) on fd 9 of /run/gnome-devstation-migrate.lock, a
# root-owned tmpfs, so unprivileged runs fall back to the $STATE_DIR copy when
# /run is not writable.

if [ "${_LIB_STATE_LOADED:-0}" = 1 ]; then
	return 0
fi
_LIB_STATE_LOADED=1

STATE_DIR="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"

state_init() {
	mkdir -p "$STATE_DIR/steps" || return 1
}

state_log() {
	local line
	line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') state: $*"
	# migrate.sh tees every line to migrate.log. Appending here as well would
	# double-log, so write to stdout only.
	printf '%s\n' "$line"
}

state_is_done() {
	local id="$1" step_file="$2" marker stored current
	# The id becomes a path component; reject anything that could escape steps/.
	[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	marker="$STATE_DIR/steps/${id}.done"
	[ -f "$marker" ] || return 1
	stored="$(sed -n '1p' "$marker" 2>/dev/null)"
	current="$(sha256sum "$step_file" 2>/dev/null | cut -d' ' -f1)"
	[ -n "$stored" ] && [ "$stored" = "$current" ]
}

state_mark_done() {
	local id="$1" step_file="$2" marker hash stamp tmp
	# The id becomes a path component; reject anything that could escape steps/.
	[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	marker="$STATE_DIR/steps/${id}.done"
	mkdir -p "$(dirname "$marker")" || return 1
	hash="$(sha256sum "$step_file" 2>/dev/null | cut -d' ' -f1)" || return 1
	stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	tmp="$(mktemp "${marker}.XXXXXX")" || return 1
	if ! printf '%s\n%s\n%s\n' "$hash" "$stamp" "$id" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$marker" || return 1
}

state_mark_interrupted() {
	local id="$1"
	mkdir -p "$STATE_DIR" || return 1
	printf '%s\n' "$id" >"$STATE_DIR/interrupted"
}

state_clear_interrupted() {
	rm -f "$STATE_DIR/interrupted"
}

state_lock_acquire() {
	local lock=/run/gnome-devstation-migrate.lock
	local opened_fd=0
	# /run is a root-owned tmpfs; without write access, use the copy under
	# $STATE_DIR so unprivileged runs and tests still get a lock.
	[ -w /run ] || lock="$STATE_DIR/lock"
	mkdir -p "$(dirname "$lock")" 2>/dev/null
	# Skip reopening fd 9 while it already holds the lock: bash closes the old
	# descriptor on `exec 9>>` and would release the lock mid-acquire.
	if [ ! -e "/proc/self/fd/9" ]; then
		exec 9>>"$lock" || return 1
		opened_fd=1
	fi
	if ! flock -n 9; then
		# If this call opened fd 9, do not leave it behind on failure. If the
		# caller already held fd 9, leave it alone (reentrancy).
		if [ "$opened_fd" = 1 ]; then
			exec 9>&-
		fi
		return 1
	fi
	return 0
}

state_lock_release() {
	flock -u 9 2>/dev/null || true
	exec 9>&- || true
	return 0
}
