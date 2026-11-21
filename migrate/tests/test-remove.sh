#!/usr/bin/env bash
# Self-contained tests for migrate/steps/60-remove.sh.
# dnf, rpm and python3 are stubbed: no host package database is touched.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
step="$here/../steps/60-remove.sh"

work="$(mktemp -d -p /tmp/opencode 2>/dev/null || mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
ok() {
	printf '  PASS %s\n' "$1"
	passed=$((passed + 1))
}
bad() {
	printf '  FAIL %s\n' "$1"
	failed=$((failed + 1))
}
check() { # <description> <command...>
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}
file_has() { grep -Fq -- "$1" "$2"; }
file_lacks() { ! grep -Fq -- "$1" "$2"; }
no_line() { ! grep -qxF -- "$1" "$2"; }
str_has() { [[ "$2" == *"$1"* ]]; }
str_lacks() { [[ "$2" != *"$1"* ]]; }
line_of() { grep -Fn -- "$1" "$2" | head -1 | cut -d: -f1; }
has_fn() { declare -F "$1" >/dev/null 2>&1; }
unchanged_or_absent() { [ ! -e "$2" ] || cmp -s "$1" "$2"; }

[ -f "$step" ] || {
	echo "test-remove: missing $step" >&2
	exit 1
}

# ---------------------------------------------------------------- stubs ----
bin="$work/bin"
mkdir -p "$bin"

cat >"$bin/rpm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/rpm"
case "$1" in
-qa)
	cat "$INSTALLED"
	exit 0
	;;
-q)
	shift
	if grep -qxF -- "$1" "$INSTALLED"; then exit 0; else exit 1; fi
	;;
esac
exit 1
STUB

cat >"$bin/dnf" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CALLS/dnf"
printf '\n' >> "$CALLS/dnf"

sub=""
assumeno=0
apply=0
allowerasing=0
for a in "$@"; do
	case "$a" in
	group | remove | history | list) [ -z "$sub" ] && sub="$a" ;;
	esac
	case "$a" in
	--assumeno) assumeno=1 ;;
	-y | --assumeyes) apply=1 ;;
	--allowerasing) allowerasing=1 ;;
	esac
done

if [ "$sub" = "history" ]; then
	printf 'ID | Command line | Date and time | Action(s) | Altered\n'
	printf '%s | remove gnome-software | 2026-11-22 | Removed | 3\n' "${HISTORY_ID:-42}"
	exit 0
fi

if [ "${SIMULATE_DIRTY:-0}" = 1 ] && [ "$assumeno" = 1 ]; then
	printf 'ERROR: removing this would break a hard dependency\n' >&2
	exit 1
fi

drop() {
	grep -qxF -- "$1" "$INSTALLED" || return 0
	grep -vxF -- "$1" "$INSTALLED" > "$INSTALLED.tmp" && mv "$INSTALLED.tmp" "$INSTALLED"
}

if [ "$apply" = 1 ]; then
	printf 'apply allowerasing=%s\n' "$allowerasing" >> "$CALLS/gate"
	mode=""
	for a in "$@"; do
		case "$a" in
		group) mode=group ;;
		remove) [ -n "$mode" ] || mode=remove ;;
		esac
	done
	targets=()
	for a in "$@"; do
		case "$a" in
		@*) targets+=("$a") ;;
		-*) ;;
		group | remove) ;;
		*) targets+=("$a") ;;
		esac
	done
	if [ "$mode" = group ]; then
		for g in "${targets[@]}"; do
			case "$g" in
			@libreoffice) members="libreoffice-writer libreoffice-calc" ;;
			@firefox) members="firefox" ;;
			@printing) members="cups-filters" ;;
			@guest-desktop-agents) members="guest-desktop-agents" ;;
			@domain-client) members="sssd" ;;
			*) members="" ;;
			esac
			for m in $members; do drop "$m"; done
		done
	else
		for p in "${targets[@]}"; do drop "$p"; done
	fi
fi
exit 0
STUB

cat >"$bin/python3" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CALLS/python3"
printf '\n' >> "$CALLS/python3"
out="${!#}"
mkdir -p "$out"
cp "$FIXTURE_DIR/drop-groups.txt" "$out/drop-groups.txt"
cp "$FIXTURE_DIR/remove.txt" "$out/remove.txt"
printf '%s\n' kernel > "$out/add.txt"
exit 0
STUB
chmod +x "$bin/rpm" "$bin/dnf" "$bin/python3"

mkdir -p "$work/fixture"
cat >"$work/fixture/drop-groups.txt" <<'EOF'
@libreoffice
@firefox
@printing
@guest-desktop-agents
@domain-client
EOF
cat >"$work/fixture/remove.txt" <<'EOF'
gnome-software
gnome-boxes
gnome-maps
absent-pkg
EOF
cat >"$work/fixture/installed" <<'EOF'
gnome-software
gnome-boxes
gnome-maps
libreoffice-writer
libreoffice-calc
firefox
cups-filters
guest-desktop-agents
sssd
colord
cups-pk-helper
libglvnd-gles
bash
kernel
EOF

new_case() { # <name> — fresh STATE_DIR, installed set and call logs
	case_name="$1"
	STATE_DIR="$work/state-$case_name"
	CALLS="$work/calls-$case_name"
	mkdir -p "$STATE_DIR" "$CALLS"
	INSTALLED="$work/installed-$case_name"
	cp "$work/fixture/installed" "$INSTALLED"
	export STATE_DIR CALLS INSTALLED
	export FIXTURE_DIR="$work/fixture"
	export REPO_DIR="$repo"
	export MANIFEST_DIR="$STATE_DIR/manifest"
	export PATH="$bin:$PATH"
	export ROOT=/
	unset DRY_RUN ALLOW_ERASING SIMULATE_DIRTY HISTORY_ID
}

run_step() { # -> captures combined output in OUT and status in RC
	OUT="$(
		source "$step"
		step_run 2>&1
	)"
	RC=$?
}

# ------------------------------------------------- sourcing is inert --------
echo "== sourcing"

opts_before="$(set +o)"
flags_before="$-"
pwd_before="$PWD"
source "$step"
opts_after="$(set +o)"
check "sourcing does not change shell options" [ "$opts_before" = "$opts_after" ]
check "sourcing does not change \$-" [ "$flags_before" = "$-" ]
check "sourcing does not change the working directory" [ "$pwd_before" = "$PWD" ]
check "sourcing defines step_run" has_fn step_run
check "sourcing defines step_plan" has_fn step_plan

# ------------------------------------------------------- happy path ---------
echo "== group and package removal"

new_case happy
run_step
check "step_run returns 0" [ "$RC" -eq 0 ]
dnflog="$CALLS/dnf"

check "manifest.py called with kickstart and MANIFEST_DIR" \
	file_has "migrate/manifest.py $repo/kickstart/gnome-devstation.ks $MANIFEST_DIR" "$CALLS/python3"
check "all five groups passed to dnf group remove" \
	file_has 'group remove @libreoffice @firefox @printing @guest-desktop-agents @domain-client' "$dnflog"
check "explicit packages passed to dnf remove" \
	file_has 'remove gnome-software gnome-boxes gnome-maps' "$dnflog"
check "absent package never passed to dnf" file_lacks absent-pkg "$dnflog"
check "--assumeno runs before the group apply" \
	[ "$(line_of '--assumeno group remove' "$dnflog")" -lt "$(line_of '-y group remove' "$dnflog")" ]
check "--assumeno runs before the package apply" \
	[ "$(line_of '--assumeno remove gnome-software' "$dnflog")" -lt "$(line_of '-y remove gnome-software' "$dnflog")" ]
check "no --allowerasing without the gate" file_lacks '--allowerasing' "$dnflog"
check "hard-dependency guard announced" \
	str_has 'ALLOW_ERASING=0: hard-dependency guard active' "$OUT"
check "absent package skip logged" str_has 'skipping absent-pkg: already absent' "$OUT"

check "removed-packages.txt written" [ -f "$STATE_DIR/removed-packages.txt" ]
check "rollback list has an explicit package" file_has gnome-software "$STATE_DIR/removed-packages.txt"
check "rollback list has a group member" file_has libreoffice-writer "$STATE_DIR/removed-packages.txt"
check "rollback list has a domain-client member" file_has sssd "$STATE_DIR/removed-packages.txt"
check "rollback list excludes the absent package" file_lacks absent-pkg "$STATE_DIR/removed-packages.txt"
check "KEEP package not in rollback list" file_lacks libglvnd-gles "$STATE_DIR/removed-packages.txt"
check "dnf history id recorded" [ "$(cat "$STATE_DIR/dnf-history-after" 2>/dev/null)" = 42 ]
check "packages really gone" no_line gnome-software "$INSTALLED"
check "group members really gone" no_line firefox "$INSTALLED"

happy_installed="$INSTALLED"
happy_removed="$STATE_DIR/removed-packages.txt"

# ------------------------------------------------------------- DRY_RUN -----
echo "== DRY_RUN"

new_case dry
export DRY_RUN=1
run_step
check "DRY_RUN step_run returns 0" [ "$RC" -eq 0 ]
check "DRY_RUN runs --assumeno" file_has '--assumeno group remove' "$CALLS/dnf"
check "DRY_RUN runs no -y apply" file_lacks '-y ' "$CALLS/dnf"
check "DRY_RUN does not query dnf history" file_lacks 'history list' "$CALLS/dnf"
check "DRY_RUN leaves rollback list untouched" [ ! -e "$STATE_DIR/removed-packages.txt" ]
check "DRY_RUN leaves history id untouched" [ ! -e "$STATE_DIR/dnf-history-after" ]
check "DRY_RUN changes no installed package" grep -qxF firefox "$INSTALLED"
check "DRY_RUN announced" str_has 'DRY_RUN=1' "$OUT"

# ------------------------------------------------------- ALLOW_ERASING ------
echo "== ALLOW_ERASING gate"

new_case erasing
export ALLOW_ERASING=1
run_step
check "ALLOW_ERASING step_run returns 0" [ "$RC" -eq 0 ]
check "--allowerasing used with --assumeno" \
	file_has '--assumeno --allowerasing group remove' "$CALLS/dnf"
check "--allowerasing used with -y" \
	file_has '-y --allowerasing group remove' "$CALLS/dnf"
check "--allowerasing used for packages too" \
	file_has '-y --allowerasing remove gnome-software' "$CALLS/dnf"
check "choice logged" str_has 'ALLOW_ERASING=1: --allowerasing is enabled' "$OUT"
check "every apply had --allowerasing" \
	[ "$(grep -c 'apply allowerasing=1' "$CALLS/gate")" -eq 2 ]

# ------------------------------------------- dirty simulation stops apply --
echo "== --assumeno failure is a hard stop"

new_case dirty
export SIMULATE_DIRTY=1
run_step
check "dirty simulation returns nonzero" [ "$RC" -ne 0 ]
check "no -y apply after a dirty simulation" file_lacks '-y ' "$CALLS/dnf"
check "dirty simulation keeps all packages installed" grep -qxF firefox "$INSTALLED"
check "refusal logged" str_has 'refusing to apply' "$OUT"
check "no rollback list on failure" [ ! -e "$STATE_DIR/removed-packages.txt" ]

# ------------------------------------------------------------- re-run -------
echo "== idempotent re-run"

new_case rerun
cp "$happy_installed" "$INSTALLED"
run_step
check "re-run returns 0" [ "$RC" -eq 0 ]
check "re-run skips absent explicit packages" \
	str_has 'skipping gnome-software: already absent' "$OUT"
check "re-run performs no package apply" file_lacks '-y remove ' "$CALLS/dnf"
check "re-run keeps rollback list unchanged" \
	unchanged_or_absent "$happy_removed" "$STATE_DIR/removed-packages.txt"

# --------------------------------------------------------- ROOT guard -------
echo "== ROOT guard"

new_case rootguard
export ROOT="$work/other-root"
run_step
check "ROOT != / is refused" [ "$RC" -ne 0 ]
check "ROOT refusal logged" str_has 'refusing to run with ROOT=' "$OUT"
check "ROOT guard makes no dnf call" [ ! -e "$CALLS/dnf" ]

# ------------------------------------------------- state_log integration ----
echo "== state_log integration"

new_case statelog
OUT="$(
	state_log() { printf 'TAGGED %s\n' "$*"; }
	source "$step"
	step_run 2>&1
)"
RC=$?
check "step_run honours an existing state_log" [ "$RC" -eq 0 ]
check "state_log received the messages" str_has 'TAGGED' "$OUT"

# ------------------------------------------------------------- step_plan ----
echo "== step_plan"

new_case plan
OUT="$(
	source "$step"
	step_plan 2>&1
)"
check "step_plan describes the work" str_has 'group remove' "$OUT"
check "step_plan mentions --allowerasing" str_has '--allowerasing' "$OUT"

# ------------------------------------------------------------- summary -----
echo
echo "test-remove: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
