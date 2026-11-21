#!/usr/bin/env bash
# Tests for lib/state.sh. Everything runs under a temp STATE_DIR that the
# EXIT trap removes on success or failure; the lock uses $STATE_DIR/lock
# because /run is not writable here.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
	echo "test-state: FAIL: $*" >&2
	exit 1
}

ok() {
	echo "ok: $*"
}

# expect_ok <desc> <cmd...>: the command must exit 0.
expect_ok() {
	local desc="$1"
	shift
	if "$@"; then
		ok "$desc"
	else
		fail "$desc"
	fi
}

# expect_not_ok <desc> <cmd...>: the command must exit nonzero.
expect_not_ok() {
	local desc="$1"
	shift
	if "$@"; then
		fail "$desc"
	else
		ok "$desc"
	fi
}

state_dir="$(mktemp -d)"
export STATE_DIR="$state_dir"

cleanup() {
	trap - EXIT
	if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
		rm -rf "$state_dir"
	fi
}
trap cleanup EXIT

source "$here/../lib/state.sh"

state_init

step_file="$state_dir/00-step.sh"
printf '# test step file\n' >"$step_file"

# --- step markers -----------------------------------------------------------

expect_not_ok "step is not done before mark_done" state_is_done 00-step "$step_file"

expect_ok "state_mark_done writes a marker" state_mark_done 00-step "$step_file"

marker="$STATE_DIR/steps/00-step.done"
[ -f "$marker" ] || fail "marker file missing after state_mark_done"
[ "$(sed -n '1p' "$marker")" = "$(sha256sum "$step_file" | cut -d' ' -f1)" ] ||
	fail "marker line 1 is not the sha256 of the step file"
[ -n "$(sed -n '2p' "$marker")" ] || fail "marker line 2 (UTC timestamp) is empty"
[ "$(sed -n '3p' "$marker")" = "00-step" ] || fail "marker line 3 is not the step id"

expect_ok "state_is_done is true after mark_done" state_is_done 00-step "$step_file"

# Editing the step file changes its hash; the marker must not match anymore.
printf 'edited\n' >>"$step_file"
expect_not_ok "state_is_done is false after the step file is edited" state_is_done 00-step "$step_file"

expect_ok "state_mark_done rewrites the marker after the edit" state_mark_done 00-step "$step_file"
expect_ok "state_is_done is true again after re-marking" state_is_done 00-step "$step_file"

# The id is used as a path component; traversal must be rejected before any
# path is built (and must not create a marker outside steps/).
expect_not_ok "state_is_done rejects an id with a slash" state_is_done "../evil" "$step_file"
expect_not_ok "state_mark_done rejects an id with a slash" state_mark_done "../evil" "$step_file"
expect_not_ok "state_is_done rejects an empty id" state_is_done "" "$step_file"
[ ! -e "$STATE_DIR/evil.done" ] || fail "an invalid id escaped the steps directory"
ok "state ids are validated before paths are built"

# --- interrupted flag -------------------------------------------------------

state_mark_interrupted 00-step
[ -f "$STATE_DIR/interrupted" ] || fail "state_mark_interrupted left no file"
[ "$(cat "$STATE_DIR/interrupted")" = "00-step" ] ||
	fail "state_mark_interrupted wrote a file that does not name the step"
state_clear_interrupted
[ ! -e "$STATE_DIR/interrupted" ] || fail "state_clear_interrupted left the file behind"

# --- log --------------------------------------------------------------------

# migrate.sh tees stdout to migrate.log, so state_log must write to stdout only.
log_out="$state_dir/state-log.stdout"
state_log "alpha line" >"$log_out"
state_log "beta line" >>"$log_out"
grep -q "alpha line" "$log_out" ||
	fail "state_log did not write the first line to stdout"
grep -q "beta line" "$log_out" ||
	fail "state_log did not write the second line to stdout"
[ ! -e "$STATE_DIR/migrate.log" ] ||
	fail "state_log appended to migrate.log; migrate.sh tees stdout, so this double-logs"
ok "state_log writes to stdout only"

# --- lock -------------------------------------------------------------------

expect_ok "state_lock_acquire" state_lock_acquire
expect_ok "state_lock_acquire is idempotent while held" state_lock_acquire
expect_ok "state_lock_release" state_lock_release
expect_ok "state_lock_acquire after release" state_lock_acquire
expect_ok "state_lock_release again" state_lock_release

# Releasing the lock must not redirect the sourcing shell's stderr to /dev/null.
# Run this in a subshell so a regression cannot silence this test's own output.
stderr_probe="$state_dir/stderr-probe.txt"
(
	state_lock_acquire || exit 1
	state_lock_release
	echo AFTER >&2
) 2>"$stderr_probe"
grep -q '^AFTER$' "$stderr_probe" ||
	fail "state_lock_release redirected the sourcing shell's stderr to /dev/null"
ok "echo AFTER >&2 still reaches stderr after state_lock_release"

# A competing process holding the lock must make our acquire fail without
# leaving fd 9 open in the failing shell.
lock_path=/run/gnome-devstation-migrate.lock
[ -w /run ] || lock_path="$STATE_DIR/lock"
holder_ready="$state_dir/holder.ready"
holder_stop="$state_dir/holder.stop"
leak_result="$state_dir/leak.result"
leak_err="$state_dir/leak.err"
(
	trap - EXIT
	exec 9>>"$lock_path" || exit 1
	flock -n 9 || exit 1
	: >"$holder_ready"
	for _ in $(seq 1 200); do
		[ -e "$holder_stop" ] && break
		sleep 0.05
	done
	flock -u 9
	exec 9>&-
) &
holder_pid=$!

for _ in $(seq 1 200); do
	[ -e "$holder_ready" ] && break
	sleep 0.05
done
[ -e "$holder_ready" ] || fail "background lock holder never acquired the lock"

(
	trap - EXIT
	if state_lock_acquire; then
		echo "ACQUIRED" >"$leak_result"
	elif [ -e /proc/self/fd/9 ]; then
		echo "LEAK" >"$leak_result"
	else
		echo "CLEAN" >"$leak_result"
	fi
) 2>"$leak_err"
: >"$holder_stop"
wait "$holder_pid"

case "$(cat "$leak_result")" in
CLEAN) ok "competing acquire fails without leaking fd 9" ;;
LEAK) fail "state_lock_acquire leaked fd 9 after a failed flock" ;;
ACQUIRED) fail "state_lock_acquire succeeded while another process held the lock" ;;
*) fail "unexpected competing-acquire result: $(cat "$leak_result")" ;;
esac

grep -qi 'lock' "$leak_err" ||
	fail "state_lock_acquire should report lock contention on stderr"
ok "state_lock_acquire reports lock contention"

echo "all state.sh tests passed"
