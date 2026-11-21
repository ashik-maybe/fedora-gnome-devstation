#!/usr/bin/env bash
# Self-contained tests for migrate/steps/20-rpms.sh.
#
# The step is SOURCED by the runner, so these tests source it too, each run in a
# fresh subshell with a fake checkout, a stub python3 on PATH and a stub
# migrate/lib/rpms.sh that provides rpms_stage. No network, no root, no writes
# outside a temp dir.
#
# Assertions:
#   * sourcing is side-effect free (shell options unchanged, no exit);
#   * step_plan describes the work without writing anything;
#   * the manifest is generated from the kickstart with the documented argv;
#   * rpms_stage is called with MANIFEST_DIR/add.txt;
#   * a missing repodata/repomd.xml or too few RPM files fails the step;
#   * an rpms_stage failure fails the step;
#   * DRY_RUN writes nothing;
#   * progress goes through state_log when the runner provides it;
#   * RPMS_DIR/MANIFEST_DIR overrides are honoured and writes stay in STATE_DIR.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
step="$repo_root/migrate/steps/20-rpms.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
ok() { printf 'ok    %s\n' "$*"; }
bad() {
	printf 'FAIL  %s\n' "$*" >&2
	fail=1
}
expect_rc() { # $1 desc, $2 expected, $3 actual
	if [ "$2" -eq "$3" ]; then
		ok "$1"
	else
		bad "$1: expected rc=$2, got rc=$3"
	fi
}

# --- fake checkout and stubs --------------------------------------------------

fake="$work/repo"
mkdir -p "$fake/migrate/lib" "$fake/kickstart" "$work/bin"
: >"$fake/migrate/manifest.py"
printf '%%packages\nbash\n' >"$fake/kickstart/gnome-devstation.ks"

# Stub lib/rpms.sh: records the rpms_stage argv and builds a fake indexed repo.
# STUB_NO_REPODATA and STUB_RPM_COUNT let a case break one verification at a
# time; STUB_RPMS_FAIL makes the staging call itself fail.
cat >"$fake/migrate/lib/rpms.sh" <<'EOF'
if [ "${_LIB_RPMS_LOADED:-0}" = 1 ]; then
	return 0
fi
_LIB_RPMS_LOADED=1

rpms_stage() {
	printf '%s\n' "$*" >>"$STUB_RPMS_LOG"
	[ "$#" -eq 1 ] || return 2
	if [ "${STUB_RPMS_FAIL:-0}" = 1 ]; then
		return 2
	fi
	mkdir -p "$RPMS_DIR/repodata" || return 2
	if [ "${STUB_NO_REPODATA:-0}" != 1 ]; then
		printf '<repomd/>\n' >"$RPMS_DIR/repodata/repomd.xml" || return 2
	fi
	local count="${STUB_RPM_COUNT:-501}" i
	for ((i = 0; i < count; i++)); do
		: >"$RPMS_DIR/pkg-$i.rpm" || return 2
	done
	return 0
}

rpms_dnf_arg() {
	printf '%s\n' "--repofrompath=migrate,file://$RPMS_DIR"
}
EOF

# Stub python3: records argv and writes the three manifest lists.
cat >"$work/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$STUB_PY_LOG"
[ "$#" -eq 3 ] || exit 2
script="$1"
kickstart="$2"
outdir="$3"
[ -f "$script" ] || { echo "python3 stub: no script $script" >&2; exit 2; }
[ -f "$kickstart" ] || { echo "python3 stub: no kickstart $kickstart" >&2; exit 2; }
mkdir -p "$outdir" || exit 2
printf 'bash\n' >"$outdir/add.txt" || exit 2
printf 'colord\n' >"$outdir/remove.txt" || exit 2
: >"$outdir/drop-groups.txt" || exit 2
EOF
chmod +x "$work/bin/python3"

export PATH="$work/bin:$PATH"

# --- helpers -----------------------------------------------------------------

new_case() { # fresh STATE_DIR with overrides pointing inside it
	case_no=$((case_no + 1))
	state="$work/state-$case_no"
	manifest_dir="$state/manifest-custom"
	rpms_dir="$state/rpms-custom"
	mkdir -p "$state"
	: >"$state/python3.log"
	: >"$state/rpms-stage.log"
	: >"$state/step.log"
	export STUB_PY_LOG="$state/python3.log"
	export STUB_RPMS_LOG="$state/rpms-stage.log"
	unset STUB_NO_REPODATA STUB_RPM_COUNT STUB_RPMS_FAIL DRY_RUN_OVERRIDE
}

run_step() { # source + step_run in a clean subshell; returns step_run's status
	(
		export REPO_DIR="$fake"
		export STATE_DIR="$state"
		export MANIFEST_DIR="$manifest_dir"
		export RPMS_DIR="$rpms_dir"
		export DRY_RUN="${DRY_RUN_OVERRIDE:-0}"
		state_log() { printf '%s\n' "$*" >>"$state/step.log"; }
		# shellcheck disable=SC1090
		source "$step"
		step_run
	)
}

all_files() { find "$work" -type f -print | sort; }
outside_state_files() { find "$work" -path "$state" -prune -o -type f -print | sort; }
rpm_count() { find "$rpms_dir" -type f -name '*.rpm' | wc -l; }

case_no=0
state=""
manifest_dir=""
rpms_dir=""

# --- sourcing is side-effect free --------------------------------------------

src_out="$(
	set +e
	before="$-"
	export REPO_DIR="$fake"
	# shellcheck disable=SC1090
	source "$step"
	after="$-"
	printf '%s\n%s\n' "$before" "$after"
	printf 'source-sentinel\n'
)"
before_opts="$(printf '%s\n' "$src_out" | sed -n '1p')"
after_opts="$(printf '%s\n' "$src_out" | sed -n '2p')"
if [ "$before_opts" = "$after_opts" ]; then
	ok "sourcing the step leaves shell options unchanged ($after_opts)"
else
	bad "sourcing changed shell options: '$before_opts' -> '$after_opts'"
fi
case "$after_opts" in
*e*) bad "sourcing enabled errexit" ;;
*) ok "sourcing does not enable errexit" ;;
esac
if [ "$(printf '%s\n' "$src_out" | tail -n 1)" = "source-sentinel" ]; then
	ok "sourcing does not exit the caller"
else
	bad "sourcing exited the caller (sentinel missing)"
fi

# --- step_plan ----------------------------------------------------------------

plan_out="$(
	export REPO_DIR="$fake" STATE_DIR="$work/plan-state"
	# shellcheck disable=SC1090
	source "$step"
	step_plan
)"
case "$plan_out" in
*"manifest.py"*"gnome-devstation.ks"*"repodata"*)
	ok "step_plan describes the manifest, kickstart and repo verification"
	;;
*) bad "step_plan output is incomplete: $plan_out" ;;
esac
if [ -e "$work/plan-state" ]; then
	bad "step_plan wrote to STATE_DIR"
else
	ok "step_plan writes nothing"
fi

# --- success path -------------------------------------------------------------

new_case
before_outside="$(outside_state_files)"
run_step
expect_rc "success: stage and verify an indexed 501-rpm repo" 0 "$?"

want_py="$fake/migrate/manifest.py $fake/kickstart/gnome-devstation.ks $manifest_dir"
if [ "$(cat "$state/python3.log")" = "$want_py" ]; then
	ok "python3 generated the manifest with the documented argv"
else
	bad "python3 argv: got '$(cat "$state/python3.log")', want '$want_py'"
fi
for list in add.txt remove.txt drop-groups.txt; do
	if [ -f "$manifest_dir/$list" ]; then
		ok "manifest generated $list under MANIFEST_DIR override"
	else
		bad "missing $manifest_dir/$list"
	fi
done
if [ "$(cat "$state/rpms-stage.log")" = "$manifest_dir/add.txt" ]; then
	ok "rpms_stage was called with MANIFEST_DIR/add.txt"
else
	bad "rpms_stage argv: got '$(cat "$state/rpms-stage.log")'"
fi
if [ -s "$rpms_dir/repodata/repomd.xml" ]; then
	ok "staged repo has repodata/repomd.xml"
else
	bad "staged repo has no repodata/repomd.xml"
fi
if [ "$(rpm_count)" -eq 501 ]; then
	ok "staged repo has 501 RPM files"
else
	bad "staged repo has $(rpm_count) RPM files, want 501"
fi
if [ ! -e "$state/manifest" ] && [ ! -e "$state/rpms" ]; then
	ok "MANIFEST_DIR/RPMS_DIR overrides were used instead of the defaults"
else
	bad "step also wrote to the default manifest/ or rpms/ directories"
fi
if grep -q '20-rpms:' "$state/step.log"; then
	ok "progress went through state_log"
else
	bad "state_log received no progress message"
fi
if [ "$(outside_state_files)" = "$before_outside" ]; then
	ok "success path wrote nothing outside STATE_DIR"
else
	bad "success path wrote outside STATE_DIR"
fi

# --- missing repodata fails ---------------------------------------------------

new_case
STUB_NO_REPODATA=1
export STUB_NO_REPODATA
run_step
expect_rc "missing repodata/repomd.xml fails the step" 1 "$?"
if [ "$(rpm_count)" -eq 501 ] && [ ! -e "$rpms_dir/repodata/repomd.xml" ]; then
	ok "missing-repodata case staged RPMs but no index"
else
	bad "missing-repodata fixture did not set up as expected"
fi

# --- too few rpms fails -------------------------------------------------------

new_case
STUB_RPM_COUNT=10
export STUB_RPM_COUNT
run_step
expect_rc "too few staged RPM files fails the step" 1 "$?"
if [ -s "$rpms_dir/repodata/repomd.xml" ] && [ "$(rpm_count)" -eq 10 ]; then
	ok "too-few-rpms case had an index but only 10 RPM files"
else
	bad "too-few-rpms fixture did not set up as expected"
fi

# --- rpms_stage failure fails the step ----------------------------------------

new_case
STUB_RPMS_FAIL=1
export STUB_RPMS_FAIL
run_step
expect_rc "a failing rpms_stage fails the step" 1 "$?"

# --- DRY_RUN writes nothing ---------------------------------------------------

new_case
DRY_RUN_OVERRIDE=1
export DRY_RUN_OVERRIDE
before_all="$(all_files)"
run_step
expect_rc "DRY_RUN plans successfully" 0 "$?"
if [ "$(all_files)" = "$before_all" ]; then
	ok "DRY_RUN created no files or directories"
else
	bad "DRY_RUN wrote something:"
	diff <(printf '%s\n' "$before_all") <(all_files) >&2 || true
fi
if [ ! -s "$state/python3.log" ] && [ ! -s "$state/rpms-stage.log" ]; then
	ok "DRY_RUN called neither python3 nor rpms_stage"
else
	bad "DRY_RUN called python3 or rpms_stage"
fi
if grep -q 'DRY_RUN' "$state/step.log"; then
	ok "DRY_RUN logged what would happen"
else
	bad "DRY_RUN did not log its plan"
fi

if [ "$fail" -eq 0 ]; then
	printf 'all tests passed\n'
fi
exit "$fail"
