# 20-rpms -- stage the kickstart's package closure as an offline local repo.
#
# Sourced by lib/runner.sh (see migrate/CONTRACT.md). This step is pure staging:
# it never touches $ROOT, so it is safe to run with ROOT != /.
#
# step_run() does, at run time (the kickstart stays the single source of truth):
#   1. generate add/remove/drop-groups lists with migrate/manifest.py into
#      $MANIFEST_DIR (default $STATE_DIR/manifest);
#   2. call rpms_stage "$MANIFEST_DIR/add.txt" to download and index every RPM
#      into $RPMS_DIR (default $STATE_DIR/rpms);
#   3. verify the result is a usable repo: repodata/repomd.xml exists and the
#      tree holds more than 500 RPM files -- the same sanity bar as
#      scripts/resolve-packages.sh:74. Only then does it return 0, so the
#      runner writes the done marker only for a repo that can actually install.
#
# DRY_RUN=1 logs the work and writes nothing at all, including under STATE_DIR.
# All real writes stay under $STATE_DIR (RPMS_DIR/MANIFEST_DIR are test hooks
# that are expected to point inside it).
#
# This file is SOURCED: no file-scope shell options, no exit. step_run uses a
# subshell body so its `set +e` cannot leak into the runner, and reports
# failures by returning nonzero.

# Log through the runner's state_log when it provides one, else stdout.
_rpms_step_log() {
	if declare -F state_log >/dev/null 2>&1; then
		state_log "$@"
	else
		printf '%s\n' "$*"
	fi
}

# step_plan(): print what would happen; the runner shows this for --plan.
step_plan() {
	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	local repo_dir="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
	_rpms_step_log "20-rpms: plan: run python3 $repo_dir/migrate/manifest.py $repo_dir/kickstart/gnome-devstation.ks ${MANIFEST_DIR:-$state_dir/manifest}; stage ${MANIFEST_DIR:-$state_dir/manifest}/add.txt into ${RPMS_DIR:-$state_dir/rpms} with rpms_stage (dnf download + rpm -K + createrepo_c); require repodata/repomd.xml and more than 500 RPM files"
}

# step_run(): generate the manifest, stage and index the RPMs, verify. The
# subshell body keeps `set +e` and every local variable out of the runner.
step_run() (
	set +e

	local REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
	local STATE_DIR="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	local MANIFEST_DIR="${MANIFEST_DIR:-$STATE_DIR/manifest}"
	local RPMS_DIR="${RPMS_DIR:-$STATE_DIR/rpms}"
	local kickstart="$REPO_DIR/kickstart/gnome-devstation.ks"
	local manifest_py="$REPO_DIR/migrate/manifest.py"
	local add_list="$MANIFEST_DIR/add.txt"
	local repodata="$RPMS_DIR/repodata/repomd.xml"
	local rpm_count

	# rpms_stage comes from lib/rpms.sh. Load it once, sharing the guard with
	# any other step that uses the staged repo. Load it here rather than at
	# file scope so sourcing this step never depends on REPO_DIR being set.
	if [ "${_LIB_RPMS_LOADED:-0}" != 1 ] && [ -f "$REPO_DIR/migrate/lib/rpms.sh" ]; then
		# shellcheck disable=SC1091
		source "$REPO_DIR/migrate/lib/rpms.sh" || {
			_rpms_step_log "20-rpms: cannot source $REPO_DIR/migrate/lib/rpms.sh"
			return 1
		}
	fi
	if ! declare -F rpms_stage >/dev/null 2>&1; then
		_rpms_step_log "20-rpms: rpms_stage unavailable; migrate/lib/rpms.sh is missing"
		return 1
	fi

	# Both inputs come from the checkout; never copy the kickstart, read it.
	if [ ! -f "$kickstart" ]; then
		_rpms_step_log "20-rpms: missing kickstart: $kickstart"
		return 1
	fi
	if [ ! -f "$manifest_py" ]; then
		_rpms_step_log "20-rpms: missing manifest generator: $manifest_py"
		return 1
	fi

	if [ "${DRY_RUN:-0}" = "1" ]; then
		_rpms_step_log "20-rpms: DRY_RUN: would generate $add_list (and the remove/drop-groups lists) from $kickstart, then stage it into $RPMS_DIR and verify an indexed repo with more than 500 RPM files"
		return 0
	fi

	mkdir -p "$MANIFEST_DIR" || {
		_rpms_step_log "20-rpms: cannot create $MANIFEST_DIR"
		return 1
	}
	mkdir -p "$RPMS_DIR" || {
		_rpms_step_log "20-rpms: cannot create $RPMS_DIR"
		return 1
	}

	if ! python3 "$REPO_DIR/migrate/manifest.py" "$REPO_DIR/kickstart/gnome-devstation.ks" "$MANIFEST_DIR"; then
		_rpms_step_log "20-rpms: manifest generation failed"
		return 1
	fi
	if [ ! -f "$add_list" ]; then
		_rpms_step_log "20-rpms: manifest generator did not create $add_list"
		return 1
	fi
	_rpms_step_log "20-rpms: generated manifest in $MANIFEST_DIR"

	if ! rpms_stage "$add_list"; then
		_rpms_step_log "20-rpms: rpms_stage failed for $add_list"
		return 1
	fi

	# A half-built repo is worse than no repo: the later dnf steps would
	# silently fall back to the network. Verify before declaring success.
	if [ ! -s "$repodata" ]; then
		_rpms_step_log "20-rpms: staged repo has no $repodata"
		return 1
	fi
	rpm_count=$(find "$RPMS_DIR" -type f -name '*.rpm' | wc -l)
	if [ "$rpm_count" -le 500 ]; then
		_rpms_step_log "20-rpms: only $rpm_count RPM files in $RPMS_DIR; refusing to call that a usable repo"
		return 1
	fi

	_rpms_step_log "20-rpms: staged and indexed $rpm_count RPM files in $RPMS_DIR"
	return 0
)
