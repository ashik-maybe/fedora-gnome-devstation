#!/usr/bin/env bash
# Self-contained tests for migrate/steps/50-add.sh.
#
# dnf and python3 are stubbed through PATH; rpms_dnf_arg comes from a stub
# lib/rpms.sh under a fixture REPO_DIR. No real package manager is touched.

set -uo pipefail

fails=0
check() { # <status> <description> -- status 0 means pass
	if [ "$1" -eq 0 ]; then
		printf 'ok   - %s\n' "$2"
	else
		printf 'FAIL - %s\n' "$2" >&2
		fails=$((fails + 1))
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/repo/migrate/lib" "$tmp/repo/kickstart" \
	"$tmp/state" "$tmp/manifest"

# --- stubs -----------------------------------------------------------------

cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >>"$STUB_PY_LOG"
out="${!#}"
mkdir -p "$out"
printf 'kernel\ngit\n' >"$out/add.txt"
printf 'gnome-software\ngnome-tour\n' >"$out/remove.txt"
: >"$out/drop-groups.txt"
EOF

cat >"$tmp/bin/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >>"$STUB_DNF_LOG"
if [[ " $* " == *" --assumeno "* ]] && [ "${STUB_DNF_TEST_FAIL:-0}" = 1 ]; then
	printf 'stub dnf: forced transaction-test failure\n' >&2
	exit 1
fi
exit 0
EOF

cat >"$tmp/repo/migrate/lib/rpms.sh" <<'EOF'
_LIB_RPMS_LOADED=1
rpms_dnf_arg() {
	printf '%s\n' '--repofrompath=migrate,file:///staged/rpms'
}
EOF

chmod +x "$tmp/bin/python3" "$tmp/bin/dnf"

export PATH="$tmp/bin:$PATH"
export REPO_DIR="$tmp/repo"
export STATE_DIR="$tmp/state"
export MANIFEST_DIR="$tmp/manifest"
export STUB_DNF_LOG="$tmp/dnf.log"
export STUB_PY_LOG="$tmp/py.log"
unset DRY_RUN STUB_DNF_TEST_FAIL

step_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/steps/50-add.sh"

# --- sourcing must not change the caller's shell options --------------------
opts_before="$(set +o)"
source "$step_file"
opts_after="$(set +o)"
[ "$opts_before" = "$opts_after" ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "sourcing 50-add.sh leaves caller shell options unchanged"

# --- success path: test first, then apply, with the exclude list ------------
: >"$STUB_DNF_LOG"
: >"$STUB_PY_LOG"
if step_run; then rc=0; else rc=$?; fi
check "$rc" "step_run returns 0 on a clean transaction"

mapfile -t calls <"$STUB_DNF_LOG"
[ "${#calls[@]}" -eq 2 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "exactly two dnf calls are made (test then apply)"

[ "${calls[0]:-}" = "CALL --assumeno install --repofrompath=migrate,file:///staged/rpms --disablerepo=* --setopt=cachedir=$tmp/state/dnf-cache kernel git --exclude=gnome-software,gnome-tour" ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "transaction-test runs first with --assumeno, local repo, cache and excludes"

[ "${calls[1]:-}" = "CALL -y install --repofrompath=migrate,file:///staged/rpms --disablerepo=* --setopt=cachedir=$tmp/state/dnf-cache kernel git --exclude=gnome-software,gnome-tour" ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "apply runs second with -y using the same arguments"

grep -q -- '--exclude=gnome-software,gnome-tour' "$STUB_DNF_LOG"
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "comma-joined remove list is passed via --exclude"

grep -q -- '--repofrompath=migrate,file:///staged/rpms' "$STUB_DNF_LOG"
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "staged local repo from rpms_dnf_arg is used"

grep -q -- "--setopt=cachedir=$tmp/state/dnf-cache" "$STUB_DNF_LOG"
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "dnf cache is kept under STATE_DIR"

[ "$(wc -l <"$STUB_PY_LOG")" -eq 1 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "manifest.py is invoked once from the kickstart"

[ -f "$tmp/manifest/add.txt" ] && [ -f "$tmp/manifest/remove.txt" ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "add/remove lists are generated into MANIFEST_DIR"

# --- a failed transaction test prevents the apply ---------------------------
: >"$STUB_DNF_LOG"
export STUB_DNF_TEST_FAIL=1
if step_run; then rc=0; else rc=$?; fi
unset STUB_DNF_TEST_FAIL
[ "$rc" -ne 0 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "step_run fails loudly when the transaction test fails"
[ "$(wc -l <"$STUB_DNF_LOG")" -eq 1 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "only the transaction test runs when it fails"
grep -q -- '--assumeno' "$STUB_DNF_LOG" && ! grep -q -- ' -y ' "$STUB_DNF_LOG"
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "a failed test never reaches the -y apply"

# --- DRY_RUN tests but never applies ----------------------------------------
: >"$STUB_DNF_LOG"
# shellcheck disable=SC2034 # read by the sourced step under test
DRY_RUN=1
if step_run; then rc=0; else rc=$?; fi
unset DRY_RUN
check "$rc" "step_run succeeds in DRY_RUN after a passing test"
[ "$(wc -l <"$STUB_DNF_LOG")" -eq 1 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "DRY_RUN makes exactly one dnf call"
grep -q -- '--assumeno' "$STUB_DNF_LOG" && ! grep -q -- ' -y ' "$STUB_DNF_LOG"
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "DRY_RUN never applies (-y)"

# --- DRY_RUN must not write outside STATE_DIR -------------------------------
: >"$STUB_DNF_LOG"
: >"$STUB_PY_LOG"
outside_manifest="$tmp/outside-manifest"
rm -rf "$outside_manifest"
MANIFEST_DIR="$outside_manifest"
# shellcheck disable=SC2034 # read by the sourced step under test
DRY_RUN=1
if step_run; then rc=0; else rc=$?; fi
unset DRY_RUN
MANIFEST_DIR="$tmp/manifest"
check "$rc" "DRY_RUN succeeds when MANIFEST_DIR is outside STATE_DIR"
if [ -e "$outside_manifest" ]; then
	rc=1
else
	rc=0
fi
check "$rc" "DRY_RUN writes no manifest outside STATE_DIR"
# restore manifest dir contents for any later tests
mkdir -p "$tmp/manifest"
printf 'kernel\ngit\n' >"$tmp/manifest/add.txt"
printf 'gnome-software\ngnome-tour\n' >"$tmp/manifest/remove.txt"
: >"$tmp/manifest/drop-groups.txt"

# --- ROOT != / must be refused before touching dnf --------------------------
: >"$STUB_DNF_LOG"
: >"$STUB_PY_LOG"
ROOT="$tmp/fakeroot"
mkdir -p "$ROOT"
if step_run; then rc=0; else rc=$?; fi
unset ROOT
[ "$rc" -ne 0 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "step_run refuses when ROOT is not /"
[ ! -s "$STUB_DNF_LOG" ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "ROOT refusal happens before any dnf call"

# --- repo arg with spaces must not be word-split ----------------------------
: >"$STUB_DNF_LOG"
cat >"$tmp/bin/dnf" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
	printf 'ARG\t%s\n' "$arg"
done >>"$STUB_DNF_LOG"
if [[ " $* " == *" --assumeno "* ]] && [ "${STUB_DNF_TEST_FAIL:-0}" = 1 ]; then
	printf 'stub dnf: forced transaction-test failure\n' >&2
	exit 1
fi
exit 0
STUB
chmod +x "$tmp/bin/dnf"
# _LIB_RPMS_LOADED is set inside step_run's subshell only, so force it here
# to prevent step_run from re-sourcing the stub lib and overwriting our override.
_LIB_RPMS_LOADED=1
rpms_dnf_arg() {
	printf '%s\n' '--repofrompath=migrate,file:///staged/rpm dir'
}
if step_run; then rc=0; else rc=$?; fi
# restore stubs
rpms_dnf_arg() {
	printf '%s\n' '--repofrompath=migrate,file:///staged/rpms'
}
cat >"$tmp/bin/dnf" <<'STUB'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >>"$STUB_DNF_LOG"
if [[ " $* " == *" --assumeno "* ]] && [ "${STUB_DNF_TEST_FAIL:-0}" = 1 ]; then
	printf 'stub dnf: forced transaction-test failure\n' >&2
	exit 1
fi
exit 0
STUB
chmod +x "$tmp/bin/dnf"
check "$rc" "step_run succeeds when rpms_dnf_arg path contains spaces"
grep -qxF $'ARG\t--repofrompath=migrate,file:///staged/rpm dir' "$STUB_DNF_LOG"
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "rpms_dnf_arg with spaces is passed as a single dnf argument"

# --- step_plan is a harmless one-liner --------------------------------------
plan="$(step_plan)"
[ -n "$plan" ] && [ "$(printf '%s\n' "$plan" | wc -l)" -eq 1 ]
# shellcheck disable=SC2319 # status of the preceding assertion
rc=$?
check "$rc" "step_plan prints a single description line"

if [ "$fails" -eq 0 ]; then
	printf 'all checks passed\n'
	exit 0
fi
printf '%d check(s) failed\n' "$fails" >&2
exit 1
