# 50-add — install the packages the kickstart adds, from the staged local repo.
#
# This file is SOURCED by lib/runner.sh, so it only defines functions. It never
# calls `set` at file scope and never calls `exit`; step_run() is a subshell
# function and returns non-zero on failure.
#
# The work is done in two dnf passes over the *same* argument list:
#   1. a transaction test with --assumeno (no changes to the live system),
#   2. the real install with -y, only when the test passed.
# DRY_RUN stops after pass 1. All dnf cache writes go under STATE_DIR and the
# packages resolve only from the repo staged by 20-rpms (rpms_dnf_arg).

# Progress logging: use the runner's state_log when it is available, otherwise
# fall back to a timestamp-free prefix. declare -F keeps this safe when the
# step is sourced on its own (e.g. by the tests).
_step50_log() {
	if declare -F state_log >/dev/null 2>&1; then
		state_log "$@"
	else
		printf '[50-add] %s\n' "$*" >&2
	fi
}

# Print one package per line from a manifest list, dropping blank lines and
# comments and trimming surrounding whitespace.
_step50_clean_lines() {
	local line
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[ -n "$line" ] && printf '%s\n' "$line"
	done <"$1"
}

step_plan() {
	printf '%s\n' \
		"50-add: transaction-test (--assumeno) then install added packages from the local repo, excluding the kickstart removals; DRY_RUN tests only"
}

step_run() (
	local repo_dir="${REPO_DIR:-}"
	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	local manifest_dir="${MANIFEST_DIR:-$state_dir/manifest}"
	local dry_run="${DRY_RUN:-0}"

	# lib/rpms.sh provides rpms_dnf_arg (the --repofrompath=... of the staged
	# local repo). Guard against double sourcing like every other step.
	if [ -z "${_LIB_RPMS_LOADED:-}" ]; then
		[ -n "$repo_dir" ] || {
			_step50_log "REPO_DIR is not set; cannot load lib/rpms.sh"
			return 1
		}
		if ! source "$repo_dir/migrate/lib/rpms.sh"; then
			_step50_log "could not source $repo_dir/migrate/lib/rpms.sh"
			return 1
		fi
	fi
	if ! declare -F rpms_dnf_arg >/dev/null 2>&1; then
		_step50_log "rpms_dnf_arg is not defined; cannot use the local repo"
		return 1
	fi

	# Regenerate the add/remove lists from the kickstart (single source of
	# truth). MANIFEST_DIR is a caller override and defaults under STATE_DIR,
	# so this write is allowed even in DRY_RUN.
	[ -n "$repo_dir" ] || {
		_step50_log "REPO_DIR is not set; cannot locate manifest.py"
		return 1
	}
	mkdir -p "$manifest_dir" || {
		_step50_log "cannot create manifest directory: $manifest_dir"
		return 1
	}
	if ! python3 "$repo_dir/migrate/manifest.py" \
		"$repo_dir/kickstart/gnome-devstation.ks" "$manifest_dir"; then
		_step50_log "manifest generation failed"
		return 1
	fi

	[ -f "$manifest_dir/add.txt" ] || {
		_step50_log "missing $manifest_dir/add.txt"
		return 1
	}
	[ -f "$manifest_dir/remove.txt" ] || {
		_step50_log "missing $manifest_dir/remove.txt"
		return 1
	}

	local -a add_pkgs=()
	local -a remove_pkgs=()
	mapfile -t add_pkgs < <(_step50_clean_lines "$manifest_dir/add.txt")
	mapfile -t remove_pkgs < <(_step50_clean_lines "$manifest_dir/remove.txt")
	if [ "${#add_pkgs[@]}" -eq 0 ]; then
		_step50_log "add list is empty; nothing to do"
		return 0
	fi

	local exclude_arg=""
	if [ "${#remove_pkgs[@]}" -gt 0 ]; then
		exclude_arg="--exclude=$(
			IFS=,
			printf '%s' "${remove_pkgs[*]}"
		)"
	fi

	local repo_arg
	if ! repo_arg="$(rpms_dnf_arg)"; then
		_step50_log "rpms_dnf_arg failed"
		return 1
	fi
	local -a repo_args=()
	read -r -a repo_args <<<"$repo_arg"

	local cache_dir="$state_dir/dnf-cache"
	local -a dnf_args=(
		install
		"${repo_args[@]}"
		--disablerepo='*'
		"--setopt=cachedir=$cache_dir"
		"${add_pkgs[@]}"
	)
	[ -z "$exclude_arg" ] || dnf_args+=("$exclude_arg")

	_step50_log "testing additive transaction (--assumeno, ${#add_pkgs[@]} packages)"
	if ! dnf --assumeno "${dnf_args[@]}"; then
		_step50_log "transaction test failed; nothing was applied"
		return 1
	fi

	if [ "$dry_run" = 1 ]; then
		_step50_log "DRY_RUN: transaction test passed; skipping apply (-y)"
		return 0
	fi

	_step50_log "applying additive transaction (-y)"
	if ! dnf -y "${dnf_args[@]}"; then
		_step50_log "dnf install failed"
		return 1
	fi

	_step50_log "additive transaction complete"
	return 0
)
