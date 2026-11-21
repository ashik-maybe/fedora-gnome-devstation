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
check $? "sourcing 50-add.sh leaves caller shell options unchanged"

# --- success path: test first, then apply, with the exclude list ------------
: >"$STUB_DNF_LOG"
: >"$STUB_PY_LOG"
if step_run; then rc=0; else rc=$?; fi
check "$rc" "step_run returns 0 on a clean transaction"

mapfile -t calls <"$STUB_DNF_LOG"
[ "${#calls[@]}" -eq 2 ]
check $? "exactly two dnf calls are made (test then apply)"

[ "${calls[0]:-}" = "CALL --assumeno install --repofrompath=migrate,file:///staged/rpms --disablerepo=* --setopt=cachedir=$tmp/state/dnf-cache kernel git --exclude=gnome-software,gnome-tour" ]
check $? "transaction-test runs first with --assumeno, local repo, cache and excludes"

[ "${calls[1]:-}" = "CALL -y install --repofrompath=migrate,file:///staged/rpms --disablerepo=* --setopt=cachedir=$tmp/state/dnf-cache kernel git --exclude=gnome-software,gnome-tour" ]
check $? "apply runs second with -y using the same arguments"

grep -q -- '--exclude=gnome-software,gnome-tour' "$STUB_DNF_LOG"
check $? "comma-joined remove list is passed via --exclude"

grep -q -- '--repofrompath=migrate,file:///staged/rpms' "$STUB_DNF_LOG"
check $? "staged local repo from rpms_dnf_arg is used"

grep -q -- "--setopt=cachedir=$tmp/state/dnf-cache" "$STUB_DNF_LOG"
check $? "dnf cache is kept under STATE_DIR"

[ "$(wc -l <"$STUB_PY_LOG")" -eq 1 ]
check $? "manifest.py is invoked once from the kickstart"

[ -f "$tmp/manifest/add.txt" ] && [ -f "$tmp/manifest/remove.txt" ]
check $? "add/remove lists are generated into MANIFEST_DIR"

# --- a failed transaction test prevents the apply ---------------------------
: >"$STUB_DNF_LOG"
export STUB_DNF_TEST_FAIL=1
if step_run; then rc=0; else rc=$?; fi
unset STUB_DNF_TEST_FAIL
[ "$rc" -ne 0 ]
check $? "step_run fails loudly when the transaction test fails"
[ "$(wc -l <"$STUB_DNF_LOG")" -eq 1 ]
check $? "only the transaction test runs when it fails"
grep -q -- '--assumeno' "$STUB_DNF_LOG" && ! grep -q -- ' -y ' "$STUB_DNF_LOG"
check $? "a failed test never reaches the -y apply"

# --- DRY_RUN tests but never applies ----------------------------------------
: >"$STUB_DNF_LOG"
DRY_RUN=1
if step_run; then rc=0; else rc=$?; fi
unset DRY_RUN
check "$rc" "step_run succeeds in DRY_RUN after a passing test"
[ "$(wc -l <"$STUB_DNF_LOG")" -eq 1 ]
check $? "DRY_RUN makes exactly one dnf call"
grep -q -- '--assumeno' "$STUB_DNF_LOG" && ! grep -q -- ' -y ' "$STUB_DNF_LOG"
check $? "DRY_RUN never applies (-y)"

# --- step_plan is a harmless one-liner --------------------------------------
plan="$(step_plan)"
[ -n "$plan" ] && [ "$(printf '%s\n' "$plan" | wc -l)" -eq 1 ]
check $? "step_plan prints a single description line"

if [ "$fails" -eq 0 ]; then
	printf 'all checks passed\n'
	exit 0
fi
printf '%d check(s) failed\n' "$fails" >&2
exit 1
