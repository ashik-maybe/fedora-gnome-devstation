#!/usr/bin/env bash
# Self-contained tests for migrate/steps/30-upgrade.sh.
# Stubs dnf on PATH; no real package transaction is attempted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"
STEP="$REPO_DIR/migrate/steps/30-upgrade.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# 1. Sourcing is side-effect free and defines the expected entry points.
# ---------------------------------------------------------------------------
opts_before="$(set +o)"
# shellcheck disable=SC1090
source "$STEP"
opts_after="$(set +o)"
[ "$opts_before" = "$opts_after" ] || fail "sourcing 30-upgrade.sh changed shell options"
declare -F step_run >/dev/null || fail "step_run is not defined"
declare -F step_plan >/dev/null || fail "step_plan is not defined"
ok "sourcing is side-effect free and defines step_run/step_plan"

# ---------------------------------------------------------------------------
# Stub dnf: record every invocation and optionally fail upgrade/check.
# ---------------------------------------------------------------------------
stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/dnf" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DNF_LOG"
mode=""
for arg in "$@"; do
  case "$arg" in
    --setopt=*|-y|--assumeno) continue ;;
    upgrade|check) mode="$arg" ;;
  esac
done
case "$mode" in
  upgrade) [ "${DNF_UPGRADE_FAIL:-0}" = 1 ] && exit 1 ;;
  check)   [ "${DNF_CHECK_FAIL:-0}"   = 1 ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$stub/dnf"
export PATH="$stub:$PATH"

# ---------------------------------------------------------------------------
# 2. Real run: exact flags, upgrade before check, success -> 0.
# ---------------------------------------------------------------------------
state="$tmp/state/real"
mkdir -p "$state"
export DNF_LOG="$tmp/real.log" DNF_UPGRADE_FAIL=0 DNF_CHECK_FAIL=0
export STATE_DIR="$state" DRY_RUN=0
step_run || fail "step_run returned nonzero on a successful upgrade"
[ -f "$DNF_LOG" ] || fail "dnf was never called"

line1="$(sed -n '1p' "$DNF_LOG")"
line2="$(sed -n '2p' "$DNF_LOG")"
expected1="--setopt=cachedir=${state}/dnf-cache --setopt=keepcache=1 -y upgrade"
expected2="--setopt=cachedir=${state}/dnf-cache --setopt=keepcache=1 check"
[ "$line1" = "$expected1" ] || fail "unexpected upgrade argv: '$line1' (want '$expected1')"
[ "$line2" = "$expected2" ] || fail "unexpected check argv: '$line2' (want '$expected2')"
[ "$(wc -l <"$DNF_LOG")" -eq 2 ] || fail "expected exactly two dnf calls"
printf '%s\n' "$line1" | grep -qE '(^| )-y( |$)' || fail "real upgrade missing -y"
printf '%s\n' "$line1" | grep -q -- '--assumeno' && fail "real upgrade must not use --assumeno"
ok "real run uses exact flags and calls upgrade before check"

# ---------------------------------------------------------------------------
# 3. Failed upgrade -> nonzero, no check, no marker.
# ---------------------------------------------------------------------------
state="$tmp/state/failup"
mkdir -p "$state"
: >"$tmp/fail.log"
export DNF_LOG="$tmp/fail.log" DNF_UPGRADE_FAIL=1 DNF_CHECK_FAIL=0
export STATE_DIR="$state" DRY_RUN=0
if step_run; then fail "step_run returned 0 when dnf upgrade failed"; fi
[ "$(wc -l <"$tmp/fail.log")" -eq 1 ] || fail "check should not run after a failed upgrade"
grep -q -- ' upgrade$' "$tmp/fail.log" || fail "expected a single upgrade call"
find "$state" -name '*.done' -print -quit | grep -q . && fail "failed upgrade wrote a done marker"
ok "failed upgrade returns nonzero, skips check, writes no marker"

# ---------------------------------------------------------------------------
# 4. Failed verification (dnf check) -> nonzero.
# ---------------------------------------------------------------------------
state="$tmp/state/failcheck"
mkdir -p "$state"
: >"$tmp/failcheck.log"
export DNF_LOG="$tmp/failcheck.log" DNF_UPGRADE_FAIL=0 DNF_CHECK_FAIL=1
export STATE_DIR="$state" DRY_RUN=0
if step_run; then fail "step_run returned 0 when dnf check failed"; fi
[ "$(wc -l <"$tmp/failcheck.log")" -eq 2 ] || fail "check should run after a successful upgrade"
ok "failed verification returns nonzero"

# ---------------------------------------------------------------------------
# 5. DRY_RUN: --assumeno, never -y, no state files written.
# ---------------------------------------------------------------------------
state="$tmp/state/dry"
mkdir -p "$state"
: >"$tmp/dry.log"
export DNF_LOG="$tmp/dry.log" DNF_UPGRADE_FAIL=0 DNF_CHECK_FAIL=0
export STATE_DIR="$state" DRY_RUN=1
step_run || fail "step_run returned nonzero in DRY_RUN"
[ -f "$DNF_LOG" ] || fail "DRY_RUN should still resolve the transaction with dnf"
dry_line="$(cat "$tmp/dry.log")"
printf '%s\n' "$dry_line" | grep -q -- '--assumeno' || fail "DRY_RUN missing --assumeno"
if printf '%s\n' "$dry_line" | grep -qE '(^| )-y( |$)'; then fail "DRY_RUN used -y"; fi
printf '%s\n' "$dry_line" | grep -q -- ' upgrade$' || fail "DRY_RUN did not target upgrade"
[ ! -e "$state/dnf-cache" ] || fail "DRY_RUN created a cache directory"
[ -z "$(find "$state" -type f -print -quit)" ] || fail "DRY_RUN wrote files under STATE_DIR"
ok "DRY_RUN uses --assumeno, never -y, and writes nothing"

# ---------------------------------------------------------------------------
# 6. DRY_RUN must still refuse when ROOT is not / (not a staging step).
# ---------------------------------------------------------------------------
state="$tmp/state/dry-root"
mkdir -p "$state"
: >"$tmp/dry-root.log"
export DNF_LOG="$tmp/dry-root.log" DNF_UPGRADE_FAIL=0 DNF_CHECK_FAIL=0
export STATE_DIR="$state" DRY_RUN=1 ROOT="$tmp/fake-root"
if step_run; then fail "DRY_RUN with ROOT!=/ should refuse"; fi
[ ! -s "$tmp/dry-root.log" ] || fail "DRY_RUN with ROOT!=/ must not call dnf"
find "$state" -type f -print -quit | grep -q . && fail "DRY_RUN with ROOT!=/ wrote files under STATE_DIR"
ok "DRY_RUN refuses when ROOT is not /"

# ---------------------------------------------------------------------------
# 7. step_plan prints a description without calling dnf or writing files.
# ---------------------------------------------------------------------------
: >"$tmp/plan.log"
export DNF_LOG="$tmp/plan.log"
plan_text="$(step_plan)"
[ -z "$(cat "$tmp/plan.log")" ] || fail "step_plan called dnf"
printf '%s\n' "$plan_text" | grep -q -- '-y upgrade' || fail "step_plan does not describe the upgrade"
printf '%s\n' "$plan_text" | grep -q -- 'dnf check' || fail "step_plan does not describe the verification"
ok "step_plan is a no-write description"

printf '\nAll upgrade tests passed.\n'
