# migrate/steps/30-upgrade.sh
#
# Segment 30: full system upgrade checkpoint.
#
# This file is SOURCED by migrate/lib/runner.sh.  It only defines step_run()
# and step_plan(): no file-scope `set`, no `exit`.  step_run() uses a subshell
# body so any local state stays inside the step and can never leak into the
# runner.  All writes are confined to $STATE_DIR; the runner owns the markers.

step_run() (
	# Prefer the runner's timestamped logger when present; fall back to plain
	# stdout so the step can also be sourced and tested standalone.
	_upgrade_log() {
		if declare -F state_log >/dev/null 2>&1; then
			state_log "$@"
		else
			printf '%s\n' "$*"
		fi
	}

	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	local -a dnf_opts=(
		"--setopt=cachedir=${state_dir}/dnf-cache"
		"--setopt=keepcache=1"
	)

	# ---- Plan / dry run: resolve the transaction, never apply, never write. ----
	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '%s\n' "DRY_RUN: dnf ${dnf_opts[*]} --assumeno upgrade (a real run uses -y)"
		# --assumeno is dnf's "do not apply" flag: no -y, no package changes.
		if dnf "${dnf_opts[@]}" --assumeno upgrade; then
			return 0
		fi
		return 1
	fi

	# This step mutates the live system; it is not a staging step (00/10/20).
	if [ -n "${ROOT:-}" ] && [ "${ROOT}" != "/" ]; then
		_upgrade_log "refusing to upgrade: ROOT='${ROOT}' is not '/'"
		return 1
	fi

	mkdir -p "${state_dir}/dnf-cache" || return 1

	# Upgrade *every* installed package before any add/remove step, so the
	# package set we compute later is based on an up-to-date system.
	_upgrade_log "30-upgrade: upgrading all installed packages before any package-set changes"
	if ! dnf "${dnf_opts[@]}" -y upgrade; then
		_upgrade_log "30-upgrade: dnf upgrade failed"
		return 1
	fi

	# Own verification: the package database must still be consistent.  The
	# runner writes the done marker only after we return 0.
	_upgrade_log "30-upgrade: verifying the package database with dnf check"
	if ! dnf "${dnf_opts[@]}" check; then
		_upgrade_log "30-upgrade: dnf check failed after upgrade"
		return 1
	fi

	_upgrade_log "30-upgrade: system upgrade complete and verified"
	return 0
)

step_plan() {
	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	printf '%s\n' \
		"30-upgrade: dnf --setopt=cachedir=${state_dir}/dnf-cache --setopt=keepcache=1 -y upgrade, then dnf check (before any add/remove step)"
}
