#!/usr/bin/env bash
# Self-contained tests for migrate/steps/10-assets.sh.
# No network and no real STATE_DIR: download_stage() is stubbed with local
# fixtures and the step reads a temporary manifest through REPO_DIR.

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(dirname -- "$(dirname -- "$TEST_DIR")")"
STEP_FILE="$REPO_ROOT/migrate/steps/10-assets.sh"
REAL_MANIFEST="$REPO_ROOT/migrate/manifests/assets.sha256"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-assets.XXXXXX")" || exit 1
trap 'rm -rf -- "$tmp"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}
pass() { printf 'ok: %s\n' "$*"; }

NAMES=(
	rpmfusion-free-release-45.noarch.rpm
	rpmfusion-nonfree-release-45.noarch.rpm
	google-chrome.asc
	helium-copr.asc
)

FIXTURE="$tmp/fixture"
mkdir -p -- "$FIXTURE/src" "$FIXTURE/repo/migrate/manifests" || exit 1
TEST_MANIFEST="$FIXTURE/repo/migrate/manifests/assets.sha256"
: >"$TEST_MANIFEST" || exit 1
for name in "${NAMES[@]}"; do
	printf 'fixture content for %s\n' "$name" >"$FIXTURE/src/$name" || exit 1
	line="$(sha256sum "$FIXTURE/src/$name")" || exit 1
	printf '%s  %s\n' "${line%% *}" "$name" >>"$TEST_MANIFEST" || exit 1
done

# download_stage() stub: copies the matching fixture, refuses a wrong hash and
# logs every request to a file so the parent shell can count refetches even
# though step_run() runs in a subshell.
STAGE_LOG="$FIXTURE/stage.log"
: >"$STAGE_LOG" || exit 1
download_stage() {
	# shellcheck disable=SC2034 # url is positional; the stub only needs dest/want
	local url=$1 dest=$2 want=$3 base have got
	base=${dest##*/}
	printf '%s\n' "$base" >>"$STAGE_LOG"
	[ -f "$FIXTURE/src/$base" ] || return 1
	if [ -f "$dest" ]; then
		have="$(sha256sum "$dest")" || return 1
		have=${have%% *}
		[ "$have" = "$want" ] && return 0
		rm -f -- "$dest" || return 1
	fi
	cp -- "$FIXTURE/src/$base" "$dest" || return 1
	got="$(sha256sum "$dest")" || {
		rm -f -- "$dest"
		return 1
	}
	got=${got%% *}
	if [ "$got" != "$want" ]; then
		rm -f -- "$dest"
		return 1
	fi
}

# shellcheck source=/dev/null
source "$STEP_FILE" || fail "cannot source $STEP_FILE"
declare -F step_run >/dev/null 2>&1 || fail 'step_run is not defined'
declare -F step_plan >/dev/null 2>&1 || fail 'step_plan is not defined'

export REPO_DIR="$FIXTURE/repo"
export STATE_DIR="$tmp/state"
export ASSETS_DIR="$STATE_DIR/assets"
DRY_RUN=0
export DRY_RUN

run_step() {
	local rc=0
	step_run >"$tmp/step.log" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		cat "$tmp/step.log" >&2
		return "$rc"
	fi
}

check_staged() {
	local name want got
	for name in "${NAMES[@]}"; do
		[ -f "$ASSETS_DIR/$name" ] || fail "missing staged file $ASSETS_DIR/$name"
		got="$(sha256sum "$ASSETS_DIR/$name")" || fail "cannot hash $name"
		got=${got%% *}
		want="$(awk -v n="$name" '$2 == n { print $1 }' "$TEST_MANIFEST")"
		[ -n "$want" ] || fail "no expected hash for $name"
		[ "$got" = "$want" ] || fail "wrong hash for $name"
	done
}

# 1. DRY_RUN plans only: no state dir, no asset dir, no downloads.
DRY_RUN=1 run_step || fail 'step_run failed in DRY_RUN mode'
[ ! -e "$STATE_DIR" ] || fail 'DRY_RUN created STATE_DIR'
[ ! -e "$ASSETS_DIR" ] || fail 'DRY_RUN created ASSETS_DIR'
[ ! -s "$STAGE_LOG" ] || fail 'DRY_RUN called download_stage'
plan="$(DRY_RUN=1 step_plan)" || fail 'step_plan failed'
for name in "${NAMES[@]}"; do
	case $plan in *"$name"*) ;; *) fail "step_plan omitted $name" ;; esac
done
DRY_RUN=0
pass 'DRY_RUN writes nothing and prints a complete plan'

# 2. A normal run stages all four assets with the manifest checksums.
run_step || fail 'step_run failed on a fresh staging'
check_staged
[ "$(wc -l <"$STAGE_LOG")" -eq 4 ] || fail "expected 4 downloads, got $(wc -l <"$STAGE_LOG")"
pass 'all four assets staged and hash-verified'

# 3. A corrupt asset is refetched on its own; valid ones are not touched.
: >"$STAGE_LOG" || exit 1
printf 'corrupt fixture\n' >"$ASSETS_DIR/google-chrome.asc" || exit 1
run_step || fail 'step_run failed after a staged asset was corrupted'
[ "$(wc -l <"$STAGE_LOG")" -eq 1 ] || fail "expected exactly 1 refetch, got $(wc -l <"$STAGE_LOG")"
[ "$(cat "$STAGE_LOG")" = 'google-chrome.asc' ] || fail "refetched the wrong asset: $(cat "$STAGE_LOG")"
check_staged
pass 'corrupt asset is refetched alone and still verifies'

# 4. The committed manifest is sha256sum-format with the four F45 basenames.
[ -f "$REAL_MANIFEST" ] || fail "missing committed manifest $REAL_MANIFEST"
count=0
while read -r hash name extra || [ -n "${hash:-}${name:-}" ]; do
	[ -n "${hash:-}" ] || continue
	[[ $hash =~ ^[0-9a-f]{64}$ ]] || fail "bad checksum in committed manifest: ${hash}"
	[ -z "${extra:-}" ] || fail "malformed committed manifest line: $hash $name $extra"
	case $name in
	rpmfusion-free-release-45.noarch.rpm | rpmfusion-nonfree-release-45.noarch.rpm | google-chrome.asc | helium-copr.asc) ;;
	*) fail "unexpected basename in committed manifest: ${name}" ;;
	esac
	count=$((count + 1))
done <"$REAL_MANIFEST"
[ "$count" -eq 4 ] || fail "committed manifest has $count entries, expected 4"
pass 'committed assets.sha256 has four real sha256sum-format entries'

printf 'all asset tests passed\n'
