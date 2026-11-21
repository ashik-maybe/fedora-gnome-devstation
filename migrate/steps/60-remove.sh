#!/usr/bin/env bash
# 60-remove — drop the groups and packages the kickstart excludes.
#
# Sourced by migrate/lib/runner.sh. Only functions are defined at file scope:
# no `set`, no `exit`, so sourcing cannot change the caller's shell options or
# kill the runner. Shell options live in step_run's subshell body only.
#
# Hard-dependency guard: dnf keeps its default dependency resolution (it will
# refuse to erase a package another kept package needs) unless ALLOW_ERASING=1
# is set explicitly. Every transaction is resolved with --assumeno first and
# applied only when that resolution is clean.

_remove_log() {
	if declare -F state_log >/dev/null 2>&1; then
		state_log "$@"
	else
		printf '[60-remove] %s\n' "$*"
	fi
}

step_plan() {
	cat <<'EOF'
60-remove: regenerate the manifest, then remove the excluded groups and packages.
  python3 migrate/manifest.py kickstart/gnome-devstation.ks $MANIFEST_DIR
  dnf --assumeno group remove @libreoffice @firefox @printing \
                                 @guest-desktop-agents @domain-client
  dnf -y       group remove <the same groups>               # only if clean
  dnf --assumeno remove <installed packages from remove.txt>
  dnf -y       remove <the same packages>                   # only if clean
  --allowerasing is used only when ALLOW_ERASING=1. DRY_RUN=1 stops after the
  --assumeno passes. Erased names and the dnf history id are recorded in
  $STATE_DIR for rollback.
EOF
}

step_run() (
	set -euo pipefail

	: "${REPO_DIR:?REPO_DIR must be set}"
	: "${STATE_DIR:?STATE_DIR must be set}"

	repo_dir="$REPO_DIR"
	state_dir="$STATE_DIR"
	manifest_dir="${MANIFEST_DIR:-$state_dir/manifest}"
	dry_run="${DRY_RUN:-0}"
	allow_erasing="${ALLOW_ERASING:-0}"
	root="${ROOT:-/}"

	if [ "$root" != "/" ]; then
		_remove_log "refusing to run with ROOT=$root: package removal targets the live system"
		return 1
	fi

	mkdir -p "$state_dir" "$manifest_dir"

	case "$allow_erasing" in
	1)
		erase_args=(--allowerasing)
		_remove_log "ALLOW_ERASING=1: --allowerasing is enabled; dnf may erase hard dependents"
		;;
	*)
		erase_args=()
		_remove_log "ALLOW_ERASING=0: hard-dependency guard active; dnf will not erase dependents"
		;;
	esac

	# manifest.py applies the KEEP filter (colord, cups-pk-helper and
	# libglvnd-gles never reach remove.txt); consume its output as-is.
	_remove_log "generating removal manifest from the kickstart"
	python3 "$repo_dir/migrate/manifest.py" \
		"$repo_dir/kickstart/gnome-devstation.ks" "$manifest_dir"

	groups_file="$manifest_dir/drop-groups.txt"
	packages_file="$manifest_dir/remove.txt"
	for f in "$groups_file" "$packages_file"; do
		if [ ! -r "$f" ]; then
			_remove_log "manifest did not produce $f"
			return 1
		fi
	done

	# Drop comments and blank lines from a manifest list.
	manifest_lines() { # <file>
		awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length) print }' "$1"
	}

	# Resolve with --assumeno, apply with -y only if the resolution was clean.
	dnf_pass() { # <label> <dnf arguments...>
		local label="$1"
		shift
		_remove_log "$label: resolving with --assumeno"
		if ! dnf --assumeno "${erase_args[@]}" "$@"; then
			_remove_log "$label: --assumeno reported an error; refusing to apply"
			return 1
		fi
		if [ "$dry_run" = 1 ]; then
			_remove_log "$label: DRY_RUN=1; no -y apply"
			return 0
		fi
		_remove_log "$label: --assumeno clean; applying with -y"
		if ! dnf -y "${erase_args[@]}" "$@"; then
			_remove_log "$label: apply failed"
			return 1
		fi
		return 0
	}

	# Snapshot installed names so the rollback list covers group members too.
	before_list="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u || true)"
	if [ -z "$before_list" ]; then
		_remove_log "WARNING: could not snapshot installed packages; rollback list may be incomplete"
	fi

	mapfile -t wanted_groups < <(manifest_lines "$groups_file")
	if [ "${#wanted_groups[@]}" -gt 0 ]; then
		dnf_pass "group remove" group remove "${wanted_groups[@]}" || return 1
	else
		_remove_log "no groups to remove (drop-groups.txt is empty)"
	fi

	# rpm -q makes explicit package removals idempotent across re-runs.
	present_pkgs=()
	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue
		if rpm -q "$pkg" >/dev/null 2>&1; then
			present_pkgs+=("$pkg")
		else
			_remove_log "skipping $pkg: already absent" >&2
		fi
	done < <(manifest_lines "$packages_file")

	if [ "${#present_pkgs[@]}" -gt 0 ]; then
		dnf_pass "package remove" remove "${present_pkgs[@]}" || return 1
	else
		_remove_log "no explicit packages to remove (all already absent)"
	fi

	if [ "$dry_run" = 1 ]; then
		_remove_log "DRY_RUN=1: --assumeno passes clean; no writes to the rollback records"
		return 0
	fi

	after_list="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u || true)"
	erased="$(comm -23 <(printf '%s\n' "$before_list") <(printf '%s\n' "$after_list") | sed '/^$/d')"
	if [ -n "$erased" ]; then
		{
			cat "$state_dir/removed-packages.txt" 2>/dev/null || true
			printf '%s\n' "$erased"
		} | sed '/^$/d' | sort -u >"$state_dir/.removed-packages.tmp"
		mv "$state_dir/.removed-packages.tmp" "$state_dir/removed-packages.txt"
		_remove_log "recorded erased package(s) in $state_dir/removed-packages.txt"
	else
		_remove_log "no packages were erased"
	fi

	# Best effort: the history id is a convenience for rollback, not a gate.
	hist="$(dnf history list 2>/dev/null |
		awk '$1 ~ /^[0-9]+$/ { if ($1 + 0 > m) m = $1 + 0 } END { if (m > 0) print m }' || true)"
	if [ -n "$hist" ]; then
		printf '%s\n' "$hist" >"$state_dir/dnf-history-after" || true
		_remove_log "dnf history id $hist recorded in $state_dir/dnf-history-after"
	else
		_remove_log "WARNING: could not read the dnf history id (non-fatal)"
	fi

	# Verify our own result before the runner writes the done marker.
	failed=0
	for pkg in "${present_pkgs[@]}"; do
		if rpm -q "$pkg" >/dev/null 2>&1; then
			_remove_log "VERIFY FAILED: $pkg is still installed"
			failed=1
		fi
	done
	if [ "$failed" -ne 0 ]; then
		return 1
	fi
	_remove_log "verified: all requested packages are gone"
	return 0
)
