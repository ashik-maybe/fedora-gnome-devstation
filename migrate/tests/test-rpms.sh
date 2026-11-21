#!/usr/bin/env bash
# Unit tests for migrate/lib/rpms.sh.
#
# Stubs dnf, rpm and createrepo_c on a temporary PATH: no network, no root.
# Covers: rpms_stage asks dnf for every package; a package whose rpm fails
# rpm -K is deleted and re-downloaded using its original requested name;
# partial/failing downloads and permanently unverifiable rpms are fatal and
# never indexed; createrepo_c runs only after a complete verified tree.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../lib/rpms.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export RPMS_DIR="$TMP/rpms"
export DNF_LOG="$TMP/dnf.log"
export REFETCH_LOG="$TMP/refetch.log"
export CREATEREPO_C_LOG="$TMP/createrepo_c.log"
export BAD_RPM_FILES="$TMP/bad_rpm_files"
export DNF_DROP_FILE="$TMP/dnf_drop"
export DNF_FAIL_FILE="$TMP/dnf_fail"
export DNF_FILEMAP="$TMP/dnf_filemap"

ok() {
	printf 'ok   %s\n' "$1"
}

bad() {
	printf 'FAIL %s\n' "$1"
	exit 1
}

# Reset all stub state between cases.
reset_case() {
	rm -rf "$RPMS_DIR"
	mkdir -p "$RPMS_DIR"
	: >"$DNF_LOG"
	: >"$REFETCH_LOG"
	: >"$CREATEREPO_C_LOG"
	: >"$BAD_RPM_FILES"
	: >"$DNF_DROP_FILE"
	: >"$DNF_FAIL_FILE"
	: >"$DNF_FILEMAP"
	unset RPM_K_ALWAYS_FAIL RPM_QP_FAIL
}

# --- stubs --------------------------------------------------------------------

mkdir -p "$TMP/bin"

cat >"$TMP/bin/dnf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Stubs `dnf -y download --resolve --destdir DIR <pkgs...>`.
# Knobs:
#   DNF_LOG        - every requested package name is logged here (one per line)
#   REFETCH_LOG    - on a refetch, "absent-at-refetch:<name>" / "present-at-refetch:<name>"
#   DNF_FAIL_FILE  - a name listed here makes dnf exit nonzero
#   DNF_DROP_FILE  - a name listed here is skipped but dnf still returns 0
#   DNF_FILEMAP    - "name filename" lines: the staged file name for a name
#   BAD_RPM_FILES  - basenames failing rpm -K; the marker is cleared on refetch
dest=""
pkgs=()
while [ $# -gt 0 ]; do
	case "$1" in
		--destdir) dest="$2"; shift 2 ;;
		-y | download | --resolve) shift ;;
		*) pkgs+=("$1"); shift ;;
	esac
done
for p in "${pkgs[@]}"; do
	if [ -f "${DNF_FAIL_FILE:-}" ] && grep -qxF "$p" "$DNF_FAIL_FILE"; then
		echo "dnf stub: download failed for '$p'" >&2
		exit 1
	fi
	staged="$p.rpm"
	if [ -f "${DNF_FILEMAP:-}" ]; then
		mapped="$(awk -v n="$p" '$1 == n { print $2; exit }' "$DNF_FILEMAP")"
		[ -n "$mapped" ] && staged="$mapped"
	fi
	if grep -qxF "$p" "$DNF_LOG" 2>/dev/null; then
		if [ -e "$dest/$staged" ]; then
			printf 'present-at-refetch:%s\n' "$p" >> "$REFETCH_LOG"
		else
			printf 'absent-at-refetch:%s\n' "$p" >> "$REFETCH_LOG"
		fi
		if [ -f "${BAD_RPM_FILES:-}" ]; then
			grep -v -xF "$staged" "$BAD_RPM_FILES" > "$BAD_RPM_FILES.new" || true
			mv -f "$BAD_RPM_FILES.new" "$BAD_RPM_FILES"
		fi
	fi
	printf '%s\n' "$p" >> "$DNF_LOG"
	if [ -f "${DNF_DROP_FILE:-}" ] && grep -qxF "$p" "$DNF_DROP_FILE"; then
		continue # partial success: logged but no file staged
	fi
	mkdir -p "$dest"
	: > "$dest/$staged"
done
EOF

cat >"$TMP/bin/rpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Stubs the two rpm calls rpms_stage makes:
#   rpm -K  --nosignature <file>                 -> 0 unless marked bad
#   rpm -qp --nosignature --qf '%{NAME}' <file>  -> prints the name minus .rpm
# Knobs:
#   BAD_RPM_FILES       - basenames that fail rpm -K
#   RPM_K_ALWAYS_FAIL=1 - rpm -K always fails
#   RPM_QP_FAIL=1       - rpm -qp always fails (simulates a corrupt HEADER)
file=""
for last; do
	file="$last"
done
if [ "${1:-}" = "-K" ]; then
	if [ "${RPM_K_ALWAYS_FAIL:-0}" = 1 ]; then
		exit 1
	fi
	if [ -f "${BAD_RPM_FILES:-}" ] && grep -qxF "$(basename "$file")" "$BAD_RPM_FILES"; then
		exit 1
	fi
	exit 0
elif [ "${1:-}" = "-qp" ]; then
	if [ "${RPM_QP_FAIL:-0}" = 1 ]; then
		exit 1
	fi
	printf '%s\n' "$(basename "$file" .rpm)"
	exit 0
fi
echo "rpm stub: unsupported call: $*" >&2
exit 2
EOF

cat >"$TMP/bin/createrepo_c" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call: %s\n' "$*" >> "$CREATEREPO_C_LOG"
EOF

chmod +x "$TMP/bin/dnf" "$TMP/bin/rpm" "$TMP/bin/createrepo_c"

export PATH="$TMP/bin:$PATH"

source "$lib"

# --- rpms_dnf_arg -------------------------------------------------------------

want="--repofrompath=migrate,file://$RPMS_DIR"
got="$(rpms_dnf_arg)"
if [ "$got" = "$want" ]; then
	ok "rpms_dnf_arg prints '$want'"
else
	bad "rpms_dnf_arg printed '$got', want '$want'"
fi

# --- case 1: targeted refetch of a bad rpm (retained) -------------------------

reset_case
printf 'badpkg.rpm\n' >"$BAD_RPM_FILES"
printf 'goodpkg\nbadpkg\n' >"$TMP/add.txt"

rpms_stage "$TMP/add.txt" && ok "case1: rpms_stage staged, verified and indexed $RPMS_DIR" || bad "case1: rpms_stage failed"

for p in goodpkg badpkg; do
	if grep -qxF "$p" "$DNF_LOG"; then
		ok "case1: dnf was asked for '$p'"
	else
		bad "case1: dnf was not asked for '$p'"
	fi
done

bad_calls="$(grep -cxF badpkg "$DNF_LOG" 2>/dev/null || true)"
good_calls="$(grep -cxF goodpkg "$DNF_LOG" 2>/dev/null || true)"
if [ "$bad_calls" -eq 2 ]; then
	ok "case1: badpkg was re-downloaded alone (dnf called for it twice)"
else
	bad "case1: badpkg has $bad_calls dnf calls, want 2"
fi
if [ "$good_calls" -eq 1 ]; then
	ok "case1: goodpkg was not re-downloaded"
else
	bad "case1: goodpkg has $good_calls dnf calls, want 1"
fi
if grep -qxF "absent-at-refetch:badpkg" "$REFETCH_LOG"; then
	ok "case1: badpkg.rpm was deleted before the refetch"
else
	bad "case1: no absent-at-refetch record for badpkg in $REFETCH_LOG"
fi
for p in goodpkg badpkg; do
	if [ -f "$RPMS_DIR/$p.rpm" ]; then
		ok "case1: $p.rpm staged in $RPMS_DIR"
	else
		bad "case1: $p.rpm missing from $RPMS_DIR"
	fi
done
if grep -qxF "call: --quiet $RPMS_DIR" "$CREATEREPO_C_LOG"; then
	ok "case1: createrepo_c was called with --quiet on $RPMS_DIR"
else
	bad "case1: createrepo_c was not called with --quiet on $RPMS_DIR"
fi

# --- case (a): dnf stages 1 of 2 packages -> fatal, no indexing ---------------

reset_case
printf 'bar\n' >"$DNF_DROP_FILE"
printf 'foo\nbar\n' >"$TMP/add-a.txt"

if rpms_stage "$TMP/add-a.txt"; then
	bad "case(a): rpms_stage accepted a partial (1 of 2) download"
else
	ok "case(a): rpms_stage rejected a partial (1 of 2) download"
fi
if [ -s "$CREATEREPO_C_LOG" ]; then
	bad "case(a): createrepo_c ran on an incomplete tree"
else
	ok "case(a): createrepo_c was not called"
fi

# --- case (b): rpm -K always fails -> fatal, no indexing ---------------------

reset_case
export RPM_K_ALWAYS_FAIL=1
printf 'foo\n' >"$TMP/add-b.txt"

if rpms_stage "$TMP/add-b.txt"; then
	bad "case(b): rpms_stage accepted an unverifiable rpm"
else
	ok "case(b): rpms_stage rejected an rpm that never verifies"
fi
if [ -s "$CREATEREPO_C_LOG" ]; then
	bad "case(b): createrepo_c ran on an unverified tree"
else
	ok "case(b): createrepo_c was not called"
fi
unset RPM_K_ALWAYS_FAIL

# --- case (c): rpm -qp fails -> refetch uses the true name, not a NEVRA -------

reset_case
export RPM_QP_FAIL=1
printf 'foo foo-1.0-1.fc40.x86_64.rpm\n' >"$DNF_FILEMAP"
printf 'foo-1.0-1.fc40.x86_64.rpm\n' >"$BAD_RPM_FILES"
nevra='foo-1.0-1.fc40.x86_64'
printf 'foo\n' >"$TMP/add-c.txt"

if rpms_stage "$TMP/add-c.txt"; then
	ok "case(c): rpms_stage completed after refetch"
else
	bad "case(c): rpms_stage failed"
fi
if grep -qxF 'foo' "$DNF_LOG" && ! grep -qF "$nevra" "$DNF_LOG"; then
	ok "case(c): refetch used the requested name 'foo', not the NEVRA '$nevra'"
else
	bad "case(c): dnf calls were: $(tr '\n' ' ' <"$DNF_LOG")"
fi
if grep -qxF "call: --quiet $RPMS_DIR" "$CREATEREPO_C_LOG"; then
	ok "case(c): createrepo_c ran on the verified tree"
else
	bad "case(c): createrepo_c did not run"
fi

printf 'all tests passed\n'
