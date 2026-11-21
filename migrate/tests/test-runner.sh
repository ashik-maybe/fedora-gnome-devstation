#!/usr/bin/env bash
# Self-contained tests for migrate.sh and lib/runner.sh. No root needed:
# every run uses --root <temp dir> and a stub lib/state.sh.
set -euo pipefail

_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_SRC_REPO="$(cd -- "$_SELF_DIR/../.." && pwd -P)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/migrate-runner.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/migrate/lib" "$REPO/migrate/steps" "$REPO/migrate/files"
cp -- "$_SRC_REPO/migrate/migrate.sh" "$REPO/migrate/migrate.sh"
cp -- "$_SRC_REPO/migrate/lib/runner.sh" "$REPO/migrate/lib/runner.sh"
chmod +x "$REPO/migrate/migrate.sh"
MIGRATE="$REPO/migrate/migrate.sh"

# --- stub state.sh ---------------------------------------------------------
cat >"$REPO/migrate/lib/state.sh" <<'EOF'
# Minimal state.sh stub: markers carry the id and a hash of the step file.
state_init() { mkdir -p -- "$STATE_DIR/steps"; }
state_log() { printf '%s\n' "$*"; }
state_is_done() {
  local id=$1 file=$2 marker="$STATE_DIR/steps/$1.done" want
  [[ -f "$marker" && -f "$file" ]] || return 1
  want="$(sha256sum "$file")"
  want="${want%% *}"
  [[ "$(cat "$marker")" == "$id:$want" ]]
}
state_mark_done() {
  local id=$1 file=$2 marker="$STATE_DIR/steps/$1.done" sum
  sum="$(sha256sum "$file")"
  printf '%s:%s\n' "$id" "${sum%% *}" > "$marker"
}
state_mark_interrupted() { printf '%s\n' "$1" > "$STATE_DIR/interrupted"; }
state_clear_interrupted() { rm -f -- "$STATE_DIR/interrupted"; }
state_lock_acquire() { :; }
state_lock_release() { :; }
EOF

# --- stub steps (third one fails unless THIRD_OK=1) ------------------------
cat >"$REPO/migrate/steps/00-first.sh" <<'EOF'
step_run() {
  state_log "STEP 00-first"
  printf done > "$ROOT/first.effect"
}
step_plan() { state_log "PLAN 00-first detail"; }
EOF

cat >"$REPO/migrate/steps/10-second.sh" <<'EOF'
# No step_plan(): the runner must supply a one-line description.
step_run() {
  state_log "STEP 10-second"
  printf done > "$ROOT/second.effect"
}
EOF

cat >"$REPO/migrate/steps/20-third.sh" <<'EOF'
step_run() {
  state_log "STEP 20-third"
  if [[ ${THIRD_OK:-0} == 1 ]]; then
    printf done > "$ROOT/third.effect"
    return 0
  fi
  return 1
}
step_plan() { state_log "PLAN 20-third detail"; }
EOF

cat >"$REPO/migrate/files/verify-devstation.sh" <<'EOF'
#!/usr/bin/env bash
printf 'GATE ROOT=%s\n' "${ROOT:-unset}"
EOF
chmod +x "$REPO/migrate/files/verify-devstation.sh"

# --- assertions ------------------------------------------------------------
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	[[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}
assert_contains() {
	[[ "$1" == *"$2"* ]] || fail "output missing '$2':\n$1"
}
assert_not_contains() {
	[[ "$1" != *"$2"* ]] || fail "output unexpectedly contains '$2':\n$1"
}
assert_file() {
	[[ -e "$1" ]] || fail "expected file $1"
}
assert_no_file() {
	[[ ! -e "$1" ]] || fail "unexpected file $1"
}
assert_order() {
	local out=$1 needle prev=0 idx
	shift
	for needle in "$@"; do
		idx="$(printf '%s\n' "$out" | grep -n -F -m1 -- "$needle" | cut -d: -f1)" ||
			fail "missing ordered token '$needle' in:\n$out"
		((idx > prev)) || fail "'$needle' (line $idx) not after line $prev in:\n$out"
		prev=$idx
	done
}

OUT=""
RC=0
run_migrate() {
	RC=0
	OUT="$("$MIGRATE" "$@" 2>&1)" || RC=$?
}
new_case() {
	STATE="$TMP/state-$1"
	ROOTD="$TMP/root-$1"
	mkdir -p -- "$STATE" "$ROOTD"
}

# --- 1. ordered run, stop on first failure, log tee ------------------------
new_case runall
run_migrate --state-dir "$STATE" --root "$ROOTD"
assert_eq "$RC" 1
assert_contains "$OUT" "RUN 00-first"
assert_contains "$OUT" "RUN 10-second"
assert_contains "$OUT" "RUN 20-third"
assert_contains "$OUT" "FAIL 20-third"
assert_contains "$OUT" "ABORT at step 20-third"
assert_order "$OUT" "STEP 00-first" "STEP 10-second" "STEP 20-third"
assert_file "$ROOTD/first.effect"
assert_file "$ROOTD/second.effect"
assert_no_file "$ROOTD/third.effect"
assert_file "$STATE/steps/00-first.done"
assert_file "$STATE/steps/10-second.done"
assert_no_file "$STATE/steps/20-third.done"
LOG="$(cat "$STATE/migrate.log")"
assert_contains "$LOG" "STEP 00-first"
assert_contains "$LOG" "ABORT at step 20-third"
printf "ok - ordered run stops on first failure and is tee'd to migrate.log\n"

# --- 2. skip already-done steps --------------------------------------------
STATE="$TMP/state-runall"
ROOTD="$TMP/root-skip"
mkdir -p -- "$ROOTD"
run_migrate --state-dir "$STATE" --root "$ROOTD"
assert_eq "$RC" 1
assert_contains "$OUT" "SKIP 00-first"
assert_contains "$OUT" "SKIP 10-second"
assert_not_contains "$OUT" "RUN 00-first"
assert_not_contains "$OUT" "RUN 10-second"
assert_contains "$OUT" "RUN 20-third"
assert_no_file "$ROOTD/first.effect"
assert_no_file "$ROOTD/second.effect"
printf 'ok - completed steps are skipped on resume\n'

# --- 3. --force and --step --------------------------------------------------
ROOTD="$TMP/root-force"
mkdir -p -- "$ROOTD"
run_migrate --state-dir "$STATE" --root "$ROOTD" --step 00-first --force
assert_eq "$RC" 0
assert_contains "$OUT" "RUN 00-first"
assert_contains "$OUT" "DONE 00-first"
assert_not_contains "$OUT" "SKIP 00-first"
assert_file "$ROOTD/first.effect"

ROOTD="$TMP/root-step"
mkdir -p -- "$ROOTD"
run_migrate --state-dir "$STATE" --root "$ROOTD" --step 10-second
assert_eq "$RC" 0
assert_contains "$OUT" "SKIP 10-second"
assert_no_file "$ROOTD/second.effect"
printf 'ok - --force re-runs a step; --step without --force still skips\n'

# --- 4. --plan makes no step writes ----------------------------------------
new_case plan
run_migrate --plan --state-dir "$STATE" --root "$ROOTD"
assert_eq "$RC" 0
assert_contains "$OUT" "PLAN 00-first:"
assert_contains "$OUT" "PLAN 00-first detail"
assert_contains "$OUT" "PLAN 10-second:"
assert_contains "$OUT" "apply 10-second"
assert_contains "$OUT" "PLAN 20-third detail"
assert_not_contains "$OUT" "RUN 00-first"
assert_not_contains "$OUT" "DONE 00-first"
assert_no_file "$STATE/steps/00-first.done"
assert_no_file "$STATE/steps/10-second.done"
assert_no_file "$STATE/steps/20-third.done"
assert_no_file "$STATE/interrupted"
assert_no_file "$ROOTD/first.effect"
assert_no_file "$ROOTD/second.effect"
assert_no_file "$ROOTD/third.effect"
printf 'ok - --plan prints plans and writes no markers or effects\n'

# --- 5. --verify checks markers, then the shared gate ----------------------
new_case verify
export THIRD_OK=1
run_migrate --state-dir "$STATE" --root "$ROOTD"
unset THIRD_OK
assert_eq "$RC" 0
assert_contains "$OUT" "ALL STEPS DONE"
for id in 00-first 10-second 20-third; do
	assert_file "$STATE/steps/$id.done"
done

run_migrate --verify --state-dir "$STATE" --root "$ROOTD"
assert_eq "$RC" 0
assert_contains "$OUT" "OK marker 00-first"
assert_contains "$OUT" "OK marker 20-third"
assert_contains "$OUT" "VERIFY gate"
assert_contains "$OUT" "GATE ROOT=$ROOTD"

rm -f -- "$STATE/steps/10-second.done"
run_migrate --verify --state-dir "$STATE" --root "$ROOTD"
assert_eq "$RC" 1
assert_contains "$OUT" "MISSING marker 10-second"
assert_not_contains "$OUT" "GATE ROOT="
printf 'ok - --verify checks every marker before running the gate\n'

# --- 6. help and usage errors ----------------------------------------------
run_migrate --help
assert_eq "$RC" 0
assert_contains "$OUT" "Usage: migrate/migrate.sh"
run_migrate --no-such-option
assert_eq "$RC" 2
run_migrate --step
assert_eq "$RC" 2
printf 'ok --help exits 0 and usage errors exit 2\n'

printf 'all runner tests passed\n'
