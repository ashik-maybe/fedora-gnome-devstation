#!/usr/bin/env bash
# Self-contained tests for files/verify-devstation.sh and migrate/steps/90-verify.sh.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
gate="$repo/files/verify-devstation.sh"

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
check() {
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}
str_has() { [[ "$2" == *"$1"* ]]; }

make_stub_bin() {
	local dir="$1"
	mkdir -p "$dir"
	for c in grep awk cut bash cat mkdir rm printf sed sort tr wc; do
		local p
		p="$(command -v "$c" 2>/dev/null)" || continue
		ln -s "$p" "$dir/$c"
	done
}

echo "== gnome-shell missing does not crash gate"
case_dir="$work/gnome-missing"
mkdir -p "$case_dir/root" "$case_dir/bin"
make_stub_bin "$case_dir/bin"
cat >"$case_dir/bin/rpm" <<'RPM'
#!/usr/bin/env bash
case "$1" in
  -q)
    pkg="$2"
    case "$pkg" in
      gnome-shell|gdm|gnome-shell-extension-caffeine|gnome-shell-extension-appindicator|google-chrome-stable|libva-intel-media-driver|iwlwifi-mvm-firmware|bash|tuned-ppd|ffmpeg|fuse|rpmfusion-free-release|rpmfusion-nonfree-release|kernel|akmod-nvidia|kernel-devel|gcc|make|kernel-headers|glibc-devel|kernel-modules-extra|mesa-va-drivers-freeworld|fwupd|gnome-firmware) exit 0 ;;
      firefox|libreoffice-writer|gnome-boxes|gnome-software|gnome-tour|gnome-maps|gnome-weather|rygel|gnome-remote-desktop|helium-bin|helix) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  -qa)
    if [[ "$*" == *"--qf"* ]]; then printf '%s\n' tuned-ppd; else printf '%s\n' gnome-shell tuned-ppd; fi
    ;;
esac
exit 1
RPM
cat >"$case_dir/bin/ldconfig" <<'LD'
#!/usr/bin/env bash
[ "$1" = "-p" ] && { echo "libfuse.so.2 (libc6,x86-64) => /lib64/libfuse.so.2"; exit 0; }
exit 1
LD
cat >"$case_dir/bin/dconf" <<'DC'
#!/usr/bin/env bash
if [ "$1" = "read" ]; then
  printf "%s\n" "['caffeine@patapon.info', 'appindicatorsupport@rgcjonas.gmail.com']"
  exit 0
fi
exit 1
DC
chmod +x "$case_dir/bin/rpm" "$case_dir/bin/ldconfig" "$case_dir/bin/dconf"
mkdir -p "$case_dir/root/usr/share/gnome-shell/extensions/caffeine@patapon.info"
mkdir -p "$case_dir/root/usr/share/gnome-shell/extensions/appindicatorsupport@rgcjonas.gmail.com"
printf '{"shell-version":["50"]}\n' >"$case_dir/root/usr/share/gnome-shell/extensions/caffeine@patapon.info/metadata.json"
printf '{"shell-version":["50"]}\n' >"$case_dir/root/usr/share/gnome-shell/extensions/appindicatorsupport@rgcjonas.gmail.com/metadata.json"
mkdir -p "$case_dir/root/usr/share/applications" "$case_dir/root/etc/xdg" "$case_dir/root/etc/profile.d"
: >"$case_dir/root/usr/share/applications/google-chrome.desktop"
printf 'x-scheme-handler/https=google-chrome.desktop\n' >"$case_dir/root/etc/xdg/mimeapps.list"
printf '# ok\n' >"$case_dir/root/etc/profile.d/90-devstation.sh"

set +e
OUT=$(PATH="$case_dir/bin" ROOT="$case_dir/root" bash "$gate" 2>&1)
RC=$?
set -e
check "gate exits nonzero when gnome-shell missing" [ "$RC" -ne 0 ]
check "gate does not crash with exit 127" [ "$RC" -ne 127 ]
check "gate reports gnome-shell problem" str_has "GNOME-SHELL VERSION UNAVAILABLE" "$OUT"

echo "== 90-verify writes converted marker only on gate success"
case_dir="$work/step90"
mkdir -p "$case_dir/state" "$case_dir/root"
# gate that succeeds
cat >"$case_dir/gate-ok" <<'G'
#!/usr/bin/env bash
exit 0
G
# gate that fails
cat >"$case_dir/gate-fail" <<'G'
#!/usr/bin/env bash
echo "gate failed" >&2
exit 1
G
chmod +x "$case_dir/gate-ok" "$case_dir/gate-fail"

set +e
OUT=$(
	REPO_DIR="$case_dir/repo" STATE_DIR="$case_dir/state" ROOT="$case_dir/root"
	mkdir -p "$REPO_DIR/files"
	cp "$case_dir/gate-ok" "$REPO_DIR/files/verify-devstation.sh"
	source "$repo/migrate/steps/90-verify.sh"
	step_run 2>&1
)
RC=$?
set -e
check "90-verify returns 0 on gate success" [ "$RC" -eq 0 ]
check "90-verify writes converted marker" [ -f "$case_dir/state/converted" ]

printf 'sentinel\n' >"$case_dir/state/converted"
set +e
OUT=$(
	REPO_DIR="$case_dir/repo2" STATE_DIR="$case_dir/state" ROOT="$case_dir/root"
	mkdir -p "$REPO_DIR/files"
	cp "$case_dir/gate-fail" "$REPO_DIR/files/verify-devstation.sh"
	source "$repo/migrate/steps/90-verify.sh"
	step_run 2>&1
)
RC=$?
set -e
check "90-verify returns nonzero on gate failure" [ "$RC" -ne 0 ]
check "90-verify removes converted marker on gate failure" [ ! -e "$case_dir/state/converted" ]

echo "== 90-verify fails if converted marker cannot be written"
case_dir="$work/step90-writefail"
mkdir -p "$case_dir/state" "$case_dir/root" "$case_dir/repo/files"
cp "$work/step90/gate-ok" "$case_dir/repo/files/verify-devstation.sh"
chmod 0755 "$case_dir/repo/files/verify-devstation.sh"
cat >"$case_dir/run.sh" <<RUN
#!/usr/bin/env bash
# shellcheck disable=SC2034 # consumed by the sourced step
REPO_DIR="$case_dir/repo" STATE_DIR="$case_dir/state" ROOT="$case_dir/root"
source "$repo/migrate/steps/90-verify.sh"
step_run 2>&1
RUN
chmod 0755 "$case_dir/run.sh"
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
	if command -v setpriv >/dev/null 2>&1; then
		# State dir must be readable but not writable by the dropped-privilege user.
		chmod 0755 "$work" "$case_dir" "$case_dir/state" "$case_dir/root" "$case_dir/repo" "$case_dir/repo/files"
		set +e
		OUT=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$case_dir/run.sh" 2>&1)
		RC=$?
		set -e
		check "90-verify returns nonzero when marker cannot be written" [ "$RC" -ne 0 ]
	else
		printf '  SKIP 90-verify returns nonzero when marker cannot be written (skipped: root without setpriv)\n'
	fi
else
	chmod -R a-w "$case_dir/state"
	set +e
	OUT=$(bash "$case_dir/run.sh" 2>&1)
	RC=$?
	set -e
	chmod -R u+w "$case_dir/state" 2>/dev/null || true
	check "90-verify returns nonzero when marker cannot be written" [ "$RC" -ne 0 ]
fi

echo "== 90-verify honors DRY_RUN"
case_dir="$work/step90-dry"
mkdir -p "$case_dir/state" "$case_dir/root" "$case_dir/repo/files"
printf 'sentinel\n' >"$case_dir/state/converted"
cat >"$case_dir/repo/files/verify-devstation.sh" <<'GATE'
#!/usr/bin/env bash
printf 'called\n' >>"${CALL_LOG:?CALL_LOG must be set}"
exit 0
GATE
chmod +x "$case_dir/repo/files/verify-devstation.sh"
set +e
OUT=$(
	# shellcheck disable=SC2034 # consumed by the sourced step
	REPO_DIR="$case_dir/repo" STATE_DIR="$case_dir/state" ROOT="$case_dir/root" DRY_RUN=1
	export CALL_LOG="$case_dir/gate.calls"
	source "$repo/migrate/steps/90-verify.sh"
	step_run 2>&1
)
RC=$?
set -e
check "90-verify DRY_RUN returns 0" [ "$RC" -eq 0 ]
check "90-verify DRY_RUN does not call gate" [ ! -e "$case_dir/gate.calls" ]
check "90-verify DRY_RUN leaves converted marker unchanged" [ "$(cat "$case_dir/state/converted")" = "sentinel" ]

echo
echo "test-verify: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
