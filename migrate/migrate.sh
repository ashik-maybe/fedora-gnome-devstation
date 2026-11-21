#!/usr/bin/env bash
# Converter entry point: root check, logging, lock, dispatch.
set -euo pipefail

_ORIG_ARGS=("$@")
_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_SELF_PATH="$_SELF_DIR/$(basename -- "${BASH_SOURCE[0]}")"
# Default to the checkout containing this file; tests may override REPO_DIR.
REPO_DIR="${REPO_DIR:-$(cd -- "$_SELF_DIR/.." && pwd -P)}"

usage() {
	cat <<'EOF'
Usage: migrate/migrate.sh [--plan] [--verify] [--step NN-name] [--force]
                          [--state-dir DIR] [--root DIR] [--os-release FILE]
                          [--help]

  --plan            print the planned work, change nothing (DRY_RUN=1)
  --verify          check every step marker, then run the shared gate
  --step ID         run only step ID (for example 40-repos)
  --force           re-run an already completed step
  --state-dir DIR   persistent state directory
  --root DIR        target root (only '/' is the live system)
  --os-release FILE os-release fixture used by preflight
  --help            show this help

Exit status: 0 success, 1 failure, 2 usage error.
EOF
}

# --- CLI -------------------------------------------------------------------
DRY_RUN=0
VERIFY_ONLY=0
FORCE=0
STEP_ID=""
SHOW_HELP=0
ROOT="${ROOT:-/}"
STATE_DIR="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

while (($#)); do
	case "$1" in
	--plan)
		DRY_RUN=1
		shift
		;;
	--verify)
		VERIFY_ONLY=1
		shift
		;;
	--force)
		FORCE=1
		shift
		;;
	--step)
		(($# >= 2)) || {
			printf 'migrate.sh: --step requires an ID\n' >&2
			exit 2
		}
		STEP_ID=$2
		shift 2
		;;
	--state-dir)
		(($# >= 2)) || {
			printf 'migrate.sh: --state-dir requires a DIR\n' >&2
			exit 2
		}
		STATE_DIR=$2
		shift 2
		;;
	--root)
		(($# >= 2)) || {
			printf 'migrate.sh: --root requires a DIR\n' >&2
			exit 2
		}
		ROOT=$2
		shift 2
		;;
	--os-release)
		(($# >= 2)) || {
			printf 'migrate.sh: --os-release requires a FILE\n' >&2
			exit 2
		}
		OS_RELEASE_FILE=$2
		shift 2
		;;
	--help | -h)
		SHOW_HELP=1
		shift
		;;
	--)
		shift
		break
		;;
	*)
		printf 'migrate.sh: unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done
if (($#)); then
	printf 'migrate.sh: unexpected argument: %s\n' "$1" >&2
	exit 2
fi

if ((SHOW_HELP)); then
	usage
	exit 0
fi

# --- defaults and environment ---------------------------------------------
: "${FEDORA_RELEASE:=45}"
ASSETS_DIR="${ASSETS_DIR:-$STATE_DIR/assets}"
RPMS_DIR="${RPMS_DIR:-$STATE_DIR/rpms}"
MANIFEST_DIR="${MANIFEST_DIR:-$STATE_DIR/manifest}"

export ROOT STATE_DIR REPO_DIR FEDORA_RELEASE ASSETS_DIR RPMS_DIR MANIFEST_DIR \
	DRY_RUN FORCE OS_RELEASE_FILE STEP_ID VERIFY_ONLY

# --- root check ------------------------------------------------------------
# A non-'/' ROOT means a test fixture: never escalate in that case.
if ((EUID != 0)) && [[ "$ROOT" == "/" ]]; then
	exec sudo -E env \
		"REPO_DIR=$REPO_DIR" \
		"ROOT=$ROOT" \
		"STATE_DIR=$STATE_DIR" \
		"DRY_RUN=$DRY_RUN" \
		"FORCE=$FORCE" \
		"OS_RELEASE_FILE=$OS_RELEASE_FILE" \
		"FEDORA_RELEASE=$FEDORA_RELEASE" \
		"ASSETS_DIR=$ASSETS_DIR" \
		"RPMS_DIR=$RPMS_DIR" \
		"MANIFEST_DIR=$MANIFEST_DIR" \
		"$_SELF_PATH" "${_ORIG_ARGS[@]}"
fi

# --- libraries -------------------------------------------------------------
source "$REPO_DIR/migrate/lib/state.sh"
source "$REPO_DIR/migrate/lib/runner.sh"

# The log lives in STATE_DIR, so make sure the directory exists before tee
# opens the file. Everything below (and only here) is tee'd: state_log itself
# writes to stdout only.
mkdir -p -- "$STATE_DIR"
exec 3>&1 4>&2
exec > >(tee -a "$STATE_DIR/migrate.log") 2>&1
_LOG_TEE_PID=$!
LOCK_HELD=0

_finish() {
	local rc=$?
	trap - EXIT
	if ((LOCK_HELD)) && declare -F state_lock_release >/dev/null 2>&1; then
		state_lock_release || true
	fi
	# Restore the caller's streams, then wait for tee to flush and exit.
	exec 1>&3 2>&4
	exec 3>&- 4>&-
	if [[ -n "${_LOG_TEE_PID:-}" ]]; then
		wait "$_LOG_TEE_PID" 2>/dev/null || true
	fi
	exit "$rc"
}
trap _finish EXIT

state_init

CURRENT_STEP=""
_on_signal() {
	local sig=$1
	state_mark_interrupted "${CURRENT_STEP:-unknown}" || true
	printf 'migrate.sh: interrupted by %s at step %s\n' "$sig" "${CURRENT_STEP:-unknown}" >&2
	exit 130
}
trap '_on_signal INT' INT
trap '_on_signal TERM' TERM
trap '_on_signal HUP' HUP

state_lock_acquire
LOCK_HELD=1

runner_init

# Errexit is off for dispatch: runner_* functions report failures explicitly
# and migrate.sh maps them to exit 0 / 1 / 2.
set +e
if ((VERIFY_ONLY)); then
	runner_verify_all
elif [[ -n "$STEP_ID" ]]; then
	runner_run_one "$STEP_ID"
elif ((DRY_RUN)); then
	runner_plan
else
	runner_run_all
fi
rc=$?
set -e
exit "$rc"
