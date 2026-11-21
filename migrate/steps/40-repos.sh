#!/usr/bin/env bash
# Third-party repositories, RPM Fusion release RPMs and signing keys.
#
# Mirrors kickstart/gnome-devstation.ks %post sections 1-2:
#   1. install the staged RPM Fusion release RPMs with `rpm -Uvh --nosignature`;
#   2. ship the google-chrome / helium COPR repo files and import their keys.
#
# This file is SOURCED by migrate/lib/runner.sh. There is deliberately no
# file-scope `set` and no `exit`: step_run is a subshell, so every option it
# enables stays local to the step and a failure is reported with `return`.

# Staged RPM file : installed package name (the name `rpm -q` understands).
__repos_release_rpms=(
	"rpmfusion-free-release.noarch.rpm:rpmfusion-free-release"
	"rpmfusion-nonfree-release.noarch.rpm:rpmfusion-nonfree-release"
)

# Staged signing keys to feed to `rpm --import`.
__repos_keys=(
	"google-chrome.asc"
	"helium-copr.asc"
)

# Repo definitions copied from the checkout into the target root.
__repos_repo_files=(
	"google-chrome.repo"
	"helium-copr.repo"
)

step_plan() {
	local pair key repo
	printf '40-repos: third-party repos, RPM Fusion release RPMs and signing keys\n'
	printf '  root: %s\n' "${ROOT:-/}"
	printf '  assets: %s\n' "${ASSETS_DIR:-${STATE_DIR:-/var/lib/gnome-devstation-migrate}/assets}"
	for pair in "${__repos_release_rpms[@]}"; do
		printf '  install %s unless %s is already installed (rpm -Uvh --nosignature)\n' \
			"${pair%%:*}" "${pair#*:}"
	done
	for repo in "${__repos_repo_files[@]}"; do
		printf '  copy repos/%s -> %s/etc/yum.repos.d/%s (skip if identical)\n' \
			"$repo" "${ROOT:-/}" "$repo"
	done
	for key in "${__repos_keys[@]}"; do
		printf '  import %s (rpm --import), unless already imported\n' "$key"
	done
}

step_run() (
	# The state library gives us state_log and a persistent STATE_DIR. Load it
	# only once; in a minimal environment fall back to a plain printf logger.
	if [ "${_LIB_STATE_LOADED:-0}" != 1 ] &&
		[ -r "${REPO_DIR:-}/migrate/lib/state.sh" ]; then
		# shellcheck disable=SC1091
		source "$REPO_DIR/migrate/lib/state.sh" || return 1
	fi
	if ! declare -F state_log >/dev/null 2>&1; then
		state_log() { printf '40-repos: %s\n' "$*"; }
	fi

	local root="${ROOT:-/}"
	local assets_dir="${ASSETS_DIR:-${STATE_DIR:-/var/lib/gnome-devstation-migrate}/assets}"
	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	local dry_run="${DRY_RUN:-0}"
	local force="${FORCE:-0}"
	local key_dir="$state_dir/imported-keys"
	local repos_target="${REPOS_TARGET:-$root/etc/yum.repos.d}"

	local pair rpm_file rpm_pkg repo src dst key key_marker
	local failed=0

	# This step installs release RPMs and imports keys into the live rpmdb;
	# it is not a staging step and must refuse a non-root target.
	if [ "$root" != "/" ]; then
		state_log "refusing to run: ROOT='${root}' is not '/'"
		return 1
	fi

	# 1. Persist RPM Fusion for the installed system -------------------------
	for pair in "${__repos_release_rpms[@]}"; do
		rpm_file="${pair%%:*}"
		rpm_pkg="${pair#*:}"
		if rpm -q "$rpm_pkg" >/dev/null 2>&1; then
			state_log "$rpm_pkg already installed; skip $rpm_file"
			continue
		fi
		if [ ! -f "$assets_dir/$rpm_file" ]; then
			state_log "MISSING ASSET: $assets_dir/$rpm_file"
			failed=1
			continue
		fi
		if [ "$dry_run" = 1 ]; then
			state_log "DRY RUN: would rpm -Uvh --nosignature $assets_dir/$rpm_file"
			continue
		fi
		state_log "installing $rpm_file (rpm -Uvh --nosignature)"
		if ! rpm -Uvh --nosignature "$assets_dir/$rpm_file"; then
			state_log "FAILED to install $rpm_file"
			failed=1
		fi
	done

	# 2a. Repository definitions --------------------------------------------
	for repo in "${__repos_repo_files[@]}"; do
		src="${REPO_DIR:-}/repos/$repo"
		dst="$repos_target/$repo"
		if [ ! -f "$src" ]; then
			state_log "MISSING REPO FILE: $src"
			failed=1
			continue
		fi
		if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
			state_log "$dst already matches $src; skip"
			continue
		fi
		if [ "$dry_run" = 1 ]; then
			state_log "DRY RUN: would install $src -> $dst"
			continue
		fi
		state_log "copying $src -> $dst"
		if ! install -D -m 0644 "$src" "$dst"; then
			state_log "FAILED to copy $src -> $dst"
			failed=1
		fi
	done

	# 2b. Signing keys -------------------------------------------------------
	# A marker under STATE_DIR records a successful import. `rpm --import` is
	# itself idempotent, but the marker keeps re-runs quiet and testable
	# without having to parse gpg-pubkey package names from `rpm -qa`.
	for key in "${__repos_keys[@]}"; do
		key_marker="$key_dir/$key.imported"
		if [ "$force" != 1 ] && [ -f "$key_marker" ]; then
			state_log "$key already imported; skip"
			continue
		fi
		if [ ! -f "$assets_dir/$key" ]; then
			state_log "MISSING ASSET: $assets_dir/$key"
			failed=1
			continue
		fi
		if [ "$dry_run" = 1 ]; then
			state_log "DRY RUN: would rpm --import $assets_dir/$key"
			continue
		fi
		if [ "$force" = 1 ] && [ -f "$key_marker" ]; then
			state_log "FORCE=1: re-importing $key (rpm --import)"
		else
			state_log "importing $key (rpm --import)"
		fi
		if ! rpm --import "$assets_dir/$key"; then
			state_log "FAILED to import $key"
			failed=1
			continue
		fi
		if ! mkdir -p "$key_dir" || ! : >"$key_marker"; then
			state_log "FAILED to record import of $key in $key_marker"
			failed=1
		fi
	done

	# Verify our own work before the runner writes the done marker ----------
	if [ "$dry_run" != 1 ]; then
		for pair in "${__repos_release_rpms[@]}"; do
			rpm_pkg="${pair#*:}"
			if ! rpm -q "$rpm_pkg" >/dev/null 2>&1; then
				state_log "VERIFY: $rpm_pkg is still not installed"
				failed=1
			fi
		done
		for repo in "${__repos_repo_files[@]}"; do
			dst="$repos_target/$repo"
			if [ ! -f "$dst" ]; then
				state_log "VERIFY: missing $dst"
				failed=1
			fi
		done
		for key in "${__repos_keys[@]}"; do
			if [ ! -f "$key_dir/$key.imported" ]; then
				state_log "VERIFY: no import marker for $key"
				failed=1
			fi
		done
	fi

	if [ "$failed" -ne 0 ]; then
		return 1
	fi
	state_log "third-party repos, release RPMs and signing keys are in place"
	return 0
)
