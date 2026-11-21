#!/usr/bin/env bash
# Tests for migrate/lib/download.sh.
#
# Self-contained: mktemp -d + EXIT trap cleanup, no network (file:// only),
# no root.

set -euo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/download.sh"
source "$lib"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
	printf 'FAIL %s\n' "$1" >&2
	failures=$((failures + 1))
}

# Run the command; pass when it exits 0.
expect_ok() {
	local desc="$1"
	shift
	if "$@"; then
		pass "$desc"
	else
		fail "$desc"
	fi
}

# Run the command; pass when it exits non-zero.
expect_fail() {
	local desc="$1"
	shift
	if "$@"; then
		fail "$desc"
	else
		pass "$desc"
	fi
}

# Log every curl invocation, then delegate to the real curl (file:// only).
# This lets the tests prove which curl flags were actually used.
curl_calls="$work/curl.calls"
: >"$curl_calls"
real_curl="$(command -v curl)"
curl() {
	printf '%s\n' "$*" >>"$curl_calls"
	"$real_curl" "$@"
}
reset_curl_log() { : >"$curl_calls"; }

curl_line_count() { wc -l <"$curl_calls" | tr -d ' '; }

expect_has_resume() {
	local desc="$1" line="$2"
	case "$line" in
	*"-C -"*) pass "$desc" ;;
	*) fail "$desc" ;;
	esac
}

expect_no_resume() {
	local desc="$1" line="$2"
	case "$line" in
	*"-C -"*) fail "$desc" ;;
	*) pass "$desc" ;;
	esac
}

expect_ok "_LIB_DOWNLOAD_LOADED set by lib" test "${_LIB_DOWNLOAD_LOADED:-0}" = 1

src="$work/src.bin"
head -c 100000 /dev/urandom >"$src"
src_sha="$(sha256sum "$src" | awk '{print $1}')"
src_size="$(stat -c %s "$src")"

# 1. Fresh stage from a file:// URL.
dest="$work/assets/stage.iso"
mkdir -p "$(dirname "$dest")"
reset_curl_log
expect_ok "fresh stage from file://" download_stage "file://$src" "$dest" "$src_sha"
expect_ok "staged content matches source" cmp -s "$src" "$dest"

# 1b. An already-verified dest must not fetch at all.
reset_curl_log
expect_ok "verified dest returns 0 (idempotent)" download_stage "file://$src" "$dest" "$src_sha"
expect_ok "verified dest did not re-fetch" test ! -s "$curl_calls"

# 2. Resume after truncating the .part, and prove -C - was used.
rm -f "$dest" "$dest.part"
head -c $((src_size / 2)) "$src" >"$dest.part"
reset_curl_log
expect_ok "resume after truncating .part" download_stage "file://$src" "$dest" "$src_sha"
expect_ok "resumed content matches source" cmp -s "$src" "$dest"
expect_ok "resume used curl -C -" grep -q -- '-C -' "$curl_calls"

# 2b. An oversized/invalid .part makes curl -C - fail with error 36. The part
# must be dropped and exactly one full download (no -C -) must recover it.
rm -f "$dest" "$dest.part"
head -c $((src_size + 10)) /dev/zero >"$dest.part"
reset_curl_log
expect_ok "oversized .part recovered by full download" \
	download_stage "file://$src" "$dest" "$src_sha"
expect_ok "oversized .part recovery matches source" cmp -s "$src" "$dest"
expect_ok "oversized .part made exactly two curl calls" test "$(curl_line_count)" -eq 2
expect_has_resume "oversized .part first tried -C -" "$(head -n 1 "$curl_calls")"
expect_no_resume "oversized .part full download omitted -C -" "$(tail -n 1 "$curl_calls")"

# 2c. A full-size but bad .part is recovered by the full restart branch.
rm -f "$dest" "$dest.part"
head -c "$src_size" /dev/zero >"$dest.part"
reset_curl_log
expect_ok "bad full-size .part recovered by full restart" \
	download_stage "file://$src" "$dest" "$src_sha"
expect_ok "full-size recovery matches source" cmp -s "$src" "$dest"
expect_ok "full-size .part made exactly two curl calls" test "$(curl_line_count)" -eq 2
expect_has_resume "full-size .part first tried -C -" "$(head -n 1 "$curl_calls")"
expect_no_resume "full restart omitted -C -" "$(tail -n 1 "$curl_calls")"

# 3. Corrupt final dest is replaced.
rm -f "$dest.part"
printf 'stale garbage\n' >"$dest"
expect_ok "corrupt final dest is replaced" download_stage "file://$src" "$dest" "$src_sha"
expect_ok "replaced content matches source" cmp -s "$src" "$dest"

# 4. Wrong expected checksum fails, and leaves nothing behind.
rm -f "$dest" "$dest.part"
expect_fail "wrong expected checksum fails" download_stage "file://$src" "$dest" \
	"0000000000000000000000000000000000000000000000000000000000000000"
if [ -e "$dest" ] || [ -e "$dest.part" ]; then
	fail "bad-checksum stage left files behind"
else
	pass "bad-checksum stage left no files behind"
fi

# 4b. The destination directory is created by download_stage itself (the
# caller deliberately does not mkdir it).
dest_nodir="$work/no-mkdir/deep/er/stage.bin"
expect_ok "download_stage creates the destination directory" \
	download_stage "file://$src" "$dest_nodir" "$src_sha"
expect_ok "content matches without caller mkdir" cmp -s "$src" "$dest_nodir"

# 4c. Replacing a corrupt final file must not disturb a real sibling file.
sibdir="$work/siblings"
mkdir -p "$sibdir"
sibling="$sibdir/keep-me.txt"
printf 'do not touch\n' >"$sibling"
printf 'stale garbage\n' >"$sibdir/stage.iso"
expect_ok "corrupt dest replaced beside a real sibling" \
	download_stage "file://$src" "$sibdir/stage.iso" "$src_sha"
expect_ok "replaced sibling dest matches source" cmp -s "$src" "$sibdir/stage.iso"
expect_ok "unrelated sibling still present" test -f "$sibling"
expect_ok "unrelated sibling untouched" test "$(cat "$sibling")" = "do not touch"

# 4d. A symlink .part must never be written through: remove it, stage a real
# file, and leave the symlink target's original content untouched.
sym_victim="$work/sym-victim.txt"
printf 'KEEP ME\n' >"$sym_victim"
sym_dest="$work/assets/sym-part.bin"
mkdir -p "$(dirname "$sym_dest")"
ln -s "$sym_victim" "$sym_dest.part"
reset_curl_log
expect_ok "symlink .part is replaced, not written through" \
	download_stage "file://$src" "$sym_dest" "$src_sha"
expect_ok "symlink .part staging produced correct content" cmp -s "$src" "$sym_dest"
expect_ok "symlink .part victim untouched" test "$(cat "$sym_victim")" = "KEEP ME"
if [ -L "$sym_dest" ]; then
	fail "symlink .part left dest as a symlink"
else
	pass "symlink .part left dest as a regular file"
fi

# 4e. A symlink dest must be replaced with a real verified file, not trusted
# or written through.
sym_dest_victim="$work/sym-dest-victim.txt"
printf 'ORIGINAL\n' >"$sym_dest_victim"
sym_dest2="$work/assets/sym-dest.bin"
mkdir -p "$(dirname "$sym_dest2")"
ln -s "$sym_dest_victim" "$sym_dest2"
expect_ok "symlink dest is replaced by a real file" \
	download_stage "file://$src" "$sym_dest2" "$src_sha"
expect_ok "symlink dest replacement has correct content" cmp -s "$src" "$sym_dest2"
expect_ok "symlink dest victim untouched" test "$(cat "$sym_dest_victim")" = "ORIGINAL"
if [ -L "$sym_dest2" ]; then
	fail "symlink dest left in place"
else
	pass "symlink dest replaced with a regular file"
fi

# 4f. A symlink dest with correct content must not be trusted as staged; it
# must be replaced by a real regular file.
sym_good_victim="$work/sym-good-victim.bin"
cp "$src" "$sym_good_victim"
sym_dest3="$work/assets/sym-good.bin"
mkdir -p "$(dirname "$sym_dest3")"
ln -s "$sym_good_victim" "$sym_dest3"
expect_ok "symlink dest with correct hash is restaged" \
	download_stage "file://$src" "$sym_dest3" "$src_sha"
expect_ok "restaged symlink dest has correct content" cmp -s "$src" "$sym_dest3"
if [ -L "$sym_dest3" ]; then
	fail "symlink dest with correct hash left in place"
else
	pass "symlink dest with correct hash replaced with regular file"
fi

# 4g. mkdir failure is reported clearly and does not stage anything.
blocker="$work/mkdir-blocker"
printf 'not a dir\n' >"$blocker"
expect_fail "mkdir failure is reported" \
	download_stage "file://$src" "$blocker/sub/file.bin" "$src_sha"
if [ -e "$blocker/sub/file.bin" ] || [ -e "$blocker/sub/file.bin.part" ]; then
	fail "mkdir failure left files behind"
else
	pass "mkdir failure left no files behind"
fi

# 5. Sourcing the library must not mutate a caller that turned strict mode off.
# The download itself also runs with strict mode off and no pre-made directory.
expect_ok "sourcing lib leaves caller shell options untouched (set +e)" bash -c '
	set +euo pipefail
	before_flags="$-"
	before_pipe="$(set -o | grep "^pipefail" | tr -s " " | cut -d " " -f 2)"
	source "$1"
	after_flags="$-"
	after_pipe="$(set -o | grep "^pipefail" | tr -s " " | cut -d " " -f 2)"
	if [ "$before_flags" != "$after_flags" ] || [ "$before_pipe" != "$after_pipe" ]; then
		printf "shell options changed: [%s/%s] -> [%s/%s]\n" \
			"$before_flags" "$before_pipe" "$after_flags" "$after_pipe" >&2
		exit 1
	fi
	download_stage "file://$2" "$3" "$4" || exit 1
	cmp -s "$2" "$3" || exit 1
' _ "$lib" "$src" "$work/no-strict/stage.bin" "$src_sha"

if [ "$failures" -eq 0 ]; then
	printf 'download tests: all passed\n'
else
	printf 'download tests: %d failure(s)\n' "$failures" >&2
	exit 1
fi
