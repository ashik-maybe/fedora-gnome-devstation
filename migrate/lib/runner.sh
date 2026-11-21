# lib/runner.sh - discover and run converter steps in order.
# shellcheck shell=bash
#
# Expects these variables from migrate.sh (or a test harness):
#   REPO_DIR  STATE_DIR  FORCE  DRY_RUN  ROOT
# Uses the lib/state.sh API:
#   state_log state_is_done state_mark_done state_clear_interrupted

if [[ ${_LIB_RUNNER_LOADED:-} == 1 ]]; then
	return 0
fi
_LIB_RUNNER_LOADED=1

_RUNNER_STEPS=()
_RUNNER_IDS=()
_RUNNER_INDEX=-1

# Populate the ordered step list from $REPO_DIR/migrate/steps/[0-9][0-9]-*.sh.
# The glob is lexically sorted, which is the step order because every name
# starts with a two-digit id.
runner_init() {
	_RUNNER_STEPS=()
	_RUNNER_IDS=()
	local dir="${REPO_DIR:?REPO_DIR is not set}/migrate/steps"
	local f base
	[[ -d "$dir" ]] || return 0
	for f in "$dir"/[0-9][0-9]-*.sh; do
		[[ -f "$f" ]] || continue
		base=${f##*/}
		_RUNNER_STEPS+=("$f")
		_RUNNER_IDS+=("${base%.sh}")
	done
}

# Source one step file, discarding functions left by the previous step.
_runner_load() {
	unset -f step_run step_plan 2>/dev/null || true
	# shellcheck source=/dev/null
	source "$1"
}

# Look up an id in _RUNNER_IDS; store its position in _RUNNER_INDEX.
_runner_find() {
	local want=$1 i
	_RUNNER_INDEX=-1
	for i in "${!_RUNNER_IDS[@]}"; do
		if [[ "${_RUNNER_IDS[$i]}" == "$want" ]]; then
			_RUNNER_INDEX=$i
			return 0
		fi
	done
	return 1
}

# Print what every step would do. Never writes state or touches ROOT.
runner_plan() {
	local i id file
	if ((${#_RUNNER_IDS[@]} == 0)); then
		state_log "no steps found in $REPO_DIR/migrate/steps"
		return 0
	fi
	for i in "${!_RUNNER_IDS[@]}"; do
		id=${_RUNNER_IDS[$i]}
		file=${_RUNNER_STEPS[$i]}
		_runner_load "$file" || {
			state_log "ERROR cannot load $id"
			return 1
		}
		state_log "PLAN $id:"
		if declare -F step_plan >/dev/null 2>&1; then
			step_plan
		else
			state_log "  apply $id"
		fi
	done
	return 0
}

# Print what one step would do. Never writes state or touches ROOT.
runner_plan_one() {
	local id=$1 i file
	if ! _runner_find "$id"; then
		state_log "ERROR step not found: $id"
		return 1
	fi
	i=$_RUNNER_INDEX
	file=${_RUNNER_STEPS[$i]}
	_runner_load "$file" || {
		state_log "ERROR cannot load $id"
		return 1
	}
	state_log "PLAN $id:"
	if declare -F step_plan >/dev/null 2>&1; then
		step_plan
	else
		state_log "  apply $id"
	fi
	return 0
}

# Run exactly one step by id. Skips completed steps unless FORCE=1.
# Writes the done marker only after step_run() succeeds.
runner_run_one() {
	local id=$1 i file
	if ! _runner_find "$id"; then
		state_log "ERROR step not found: $id"
		return 1
	fi
	i=$_RUNNER_INDEX
	file=${_RUNNER_STEPS[$i]}

	_runner_load "$file" || {
		state_log "ERROR cannot load $id"
		return 1
	}
	if ! declare -F step_run >/dev/null 2>&1; then
		state_log "ERROR step $id does not define step_run()"
		return 1
	fi

	if [[ ${FORCE:-0} != 1 ]] && state_is_done "$id" "$file"; then
		state_log "SKIP $id (already done)"
		return 0
	fi

	# CURRENT_STEP is read by migrate.sh's signal trap.
	# shellcheck disable=SC2034
	CURRENT_STEP="$id"
	state_log "RUN $id"
	if ! step_run; then
		state_log "FAIL $id"
		return 1
	fi

	# shellcheck disable=SC2034
	CURRENT_STEP=""
	if declare -F state_clear_interrupted >/dev/null 2>&1; then
		state_clear_interrupted
	fi
	if ! state_mark_done "$id" "$file"; then
		state_log "ERROR could not mark $id done"
		return 1
	fi
	state_log "DONE $id"
	return 0
}

# Run all steps in order; stop at the first failure.
runner_run_all() {
	local id
	if ((${#_RUNNER_IDS[@]} == 0)); then
		state_log "no steps found; nothing to do"
		return 0
	fi
	for id in "${_RUNNER_IDS[@]}"; do
		if ! runner_run_one "$id"; then
			state_log "ABORT at step $id"
			return 1
		fi
	done
	state_log "ALL STEPS DONE"
	return 0
}

# Check every step marker, then (if all are present) run the shared gate.
runner_verify_all() {
	local i id file rc=0 gate
	for i in "${!_RUNNER_IDS[@]}"; do
		id=${_RUNNER_IDS[$i]}
		file=${_RUNNER_STEPS[$i]}
		if state_is_done "$id" "$file"; then
			state_log "OK marker $id"
		else
			state_log "MISSING marker $id"
			rc=1
		fi
	done
	if ((rc != 0)); then
		state_log "VERIFY FAILED: missing step markers"
		return 1
	fi

	gate="$REPO_DIR/files/verify-devstation.sh"
	if [[ -f "$gate" ]]; then
		state_log "VERIFY gate $gate"
		if [[ -x "$gate" ]]; then
			"$gate"
		else
			bash "$gate"
		fi
		return $?
	fi
	state_log "VERIFY OK (no gate script present)"
	return 0
}
