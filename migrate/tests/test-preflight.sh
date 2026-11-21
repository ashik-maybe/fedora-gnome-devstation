#!/usr/bin/env bash
# Self-contained tests for migrate/steps/00-preflight.sh.
#
# The step is meant to be sourced by the runner, so these tests source it too,
# each time with a temp STATE_DIR and fixture os-release files. A stub `df`
# (plenty of free space) and a stub `dnf` (one history transaction) go on PATH
# and ROOT points outside /, so no root, network or real system state is
# needed.
#
# Assertions:
#   * the valid fixture passes;
#   * wrong ID, VARIANT_ID and VERSION_ID each fail;
#   * the converted marker blocks the step;
#   * the dnf history baseline is recorded inside the temp STATE_DIR;
#   * nothing is written outside the temp dir (fixture diff + /etc/os-release).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
step="$repo_root/migrate/steps/00-preflight.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
state="$work/state"

fail=0
ok() { printf 'ok    %s\n' "$*"; }
bad() {
	printf 'FAIL  %s\n' "$*" >&2
	fail=1
}

expect_rc() { # $1 desc, $2 expected rc, $3 actual rc
	if [ "$2" -eq "$3" ]; then
		ok "$1"
	else
		bad "$1: expected rc=$2, got rc=$3"
	fi
}

mkdir -p "$work/bin" "$work/fixtures" "$state"

# Stub df: report a filesystem with plenty of space (data line: $4 = 1TiB).
# Without -P it also emits a wrapped device-name line, like GNU df does for
# long LVM names. The step must pass -P; otherwise awk reads the wrong row.
cat >"$work/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
case "$*" in
*-kP*) ;;
*) echo "/dev/mapper/very-long-fedora-workstation-root-volume-name" ;;
esac
echo "stubfs 1000000000000 0 1000000000000 0% /"
EOF
chmod +x "$work/bin/df"

# Stub dnf: print one history transaction so the baseline records id 12345.
cat >"$work/bin/dnf" <<'EOF'
#!/bin/sh
# Test stub for dnf: print one history transaction.
echo "ID        | Command line                             | Date and time       | Action(s) | Altered"
echo "12345     | install dnf-plugins-core                  | 2026-11-21 10:00    | Install   | 1"
EOF
chmod +x "$work/bin/dnf"

printf 'ID="fedora"\nVARIANT_ID="workstation"\nVERSION_ID="45"\n' >"$work/fixtures/good"
printf 'ID="arch"\nVARIANT_ID="workstation"\nVERSION_ID="45"\n' >"$work/fixtures/bad-id"
printf 'ID="fedora"\nVARIANT_ID="server"\nVERSION_ID="45"\n' >"$work/fixtures/bad-variant"
printf 'ID="fedora"\nVARIANT_ID="workstation"\nVERSION_ID="44"\n' >"$work/fixtures/bad-version"

os_release_before=$(sha256sum /etc/os-release 2>/dev/null || printf 'missing\n')

run_step() { # $1 = fixture; uses $state; returns step_run's status
	(
		export REPO_DIR="$repo_root"
		export STATE_DIR="$state"
		export ROOT="$work/root"
		export OS_RELEASE_FILE="$1"
		export FEDORA_RELEASE="${FEDORA_RELEASE:-45}"
		export DRY_RUN="${DRY_RUN:-0}"
		export PATH="$work/bin:$PATH"
		# shellcheck source=../steps/00-preflight.sh
		source "$step"
		step_run
	)
}

# All regular files under $work that are outside $work/state, sorted.
outside_state() {
	find "$work" -path "$work/state" -prune -o -type f -print | sort
}

# --- valid fixture passes ---
outside_before=$(outside_state)

run_step "$work/fixtures/good"
expect_rc "valid fixture passes" 0 "$?"

# --- dnf history baseline recorded inside the temp STATE_DIR ---
if [ -f "$state/dnf-history-before" ] && [ "$(cat "$state/dnf-history-before")" = "12345" ]; then
	ok "dnf history baseline recorded in STATE_DIR"
else
	bad "dnf history baseline missing or wrong in $state"
fi

# --- nothing written outside the temp dir ---
outside_after=$(outside_state)
if diff -u <(printf '%s\n' "$outside_before") <(printf '%s\n' "$outside_after") >/dev/null; then
	ok "nothing written outside the temp dir"
else
	bad "files written outside the temp dir:"
	diff -u <(printf '%s\n' "$outside_before") <(printf '%s\n' "$outside_after") >&2
fi

os_release_after=$(sha256sum /etc/os-release 2>/dev/null || printf 'missing\n')
if [ "$os_release_before" = "$os_release_after" ]; then
	ok "/etc/os-release untouched"
else
	bad "/etc/os-release modified"
fi

# --- converted marker blocks ---
touch "$state/converted"
run_step "$work/fixtures/good"
expect_rc "converted marker blocks the step" 1 "$?"
rm "$state/converted"

# --- wrong ID / VARIANT_ID / VERSION_ID fail ---
run_step "$work/fixtures/bad-id"
expect_rc "wrong ID fails" 1 "$?"

run_step "$work/fixtures/bad-variant"
expect_rc "wrong VARIANT_ID fails" 1 "$?"

run_step "$work/fixtures/bad-version"
expect_rc "wrong VERSION_ID fails" 1 "$?"

# --- dry run passes and writes nothing ---
rm -rf "$state"
mkdir -p "$state"
DRY_RUN=1
run_step "$work/fixtures/good"
rc=$?
DRY_RUN=0
expect_rc "dry run passes" 0 "$rc"
if [ ! -e "$state/dnf-history-before" ]; then
	ok "dry run writes nothing"
else
	bad "dry run wrote $state/dnf-history-before"
fi

# --- sourcing the step must not change the caller's shell options -----------
set +e
opts_before="$-"
# shellcheck disable=SC1090
source "$step"
opts_after="$-"
set -e
if [ "$opts_before" = "$opts_after" ]; then
	ok "sourcing the step leaves shell options unchanged"
else
	bad "sourcing the step changed shell options: $opts_before -> $opts_after"
fi
# A failing step_run must not enable errexit in the runner either.
set +e
run_step "$work/fixtures/bad-id" >/dev/null 2>&1
opts_after_run="$-"
set -e
if [ "$opts_before" = "$opts_after_run" ]; then
	ok "a failing step_run leaves shell options unchanged"
else
	bad "a failing step_run changed shell options: $opts_before -> $opts_after_run"
fi

if [ "$fail" -eq 0 ]; then
	ok "all test-preflight checks passed"
else
	bad "some test-preflight checks failed"
fi
exit "$fail"
