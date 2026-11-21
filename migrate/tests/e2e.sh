#!/usr/bin/env bash
# e2e.sh -- opt-in, DESTRUCTIVE end-to-end harness for the in-place converter.
#
# It drives an EXISTING disposable Fedora 45 Workstation VM over SSH. It never
# provisions the VM and never touches the host: every package, config file and
# staged download is changed on the VM only. Provision, snapshot and revert the
# VM yourself (virt-manager, libvirt, a cloud image, whatever you already use).
#
# Nothing happens unless RUN_E2E=1 is set. With RUN_E2E unset this script just
# prints a skip message and exits 0, so it is safe to leave in CI or a test run.
#
# Usage: migrate/tests/e2e.sh [--help] [--self-test]
set -euo pipefail

# Bash 5.2+ otherwise expands a bare '&' in ${var//pat/repl} to the matched
# text, which would mangle the '&&' in the generated converter command.
shopt -u patsub_replacement 2>/dev/null || true

usage() {
	cat <<'EOF'
Usage: migrate/tests/e2e.sh [--help] [--self-test]

OPT-IN, DESTRUCTIVE end-to-end test for the gnome-devstation converter.

This script does NOT create a VM and does NOT modify the host. It provisions
nothing: it connects over SSH to a disposable Fedora 45 Workstation VM that
YOU already created and drives the converter there. By default it does nothing
at all -- you must opt in with RUN_E2E=1.

  --help        print this text and exit
  --self-test   run the built-in offline unit test: SSH_BIN is replaced by a
                log-and-succeed stub, the full scenario driver runs against it,
                and the recorded commands are checked. No host is contacted.

PREREQUISITES
  1. A disposable x86_64 Fedora 45 Workstation VM, reachable over SSH from the
     machine running this script. Snapshot it first: the converter really does
     install and remove packages and rewrite configuration on that VM.
  2. The converter repo cloned on the VM (kickstart/, migrate/, files/), with
     E2E_REPO_DIR pointing at the checkout. The converter itself is run with
     sudo there, so E2E_USER must be root or a passwordless sudoer.
  3. Network access FROM THE VM to the Fedora repos, RPM Fusion, the Chrome
     repo and the Copr repo. Download failures are reported as test failures.
  4. Enough free disk space on the VM for the staged downloads and package
     transactions (see migrate/README.md; roughly the size of the ISO build).
  5. 'ssh' on the host (or SSH_BIN pointing at an equivalent executable).

ENVIRONMENT
  RUN_E2E=1        REQUIRED. Without it this script prints a skip line and
                   exits 0, changing nothing.
  E2E_HOST         REQUIRED when running. Hostname or IP of the disposable VM.
  E2E_USER         SSH user on the VM (default: unset, i.e. let ssh decide).
  E2E_SSH_OPTS     Extra ssh arguments, whitespace separated, e.g.
                   "-o StrictHostKeyChecking=no -i /path/to/key".
  E2E_STATE_DIR    State dir ON THE VM (default /var/lib/gnome-devstation-migrate).
  E2E_REPO_DIR     Converter checkout ON THE VM (default /root/gnome-devstation).
  E2E_SUDO         Privilege prefix used on the VM (default: sudo; set to the
                   empty string when E2E_USER is root and sudo is absent).
  FEDORA_RELEASE   Expected release (default 45; kept for preflight fixtures).
  SSH_BIN          ssh executable to use (default: ssh). Used by --self-test to
                   substitute a stub. Must be a single executable, not a string
                   of arguments; pass arguments through E2E_SSH_OPTS instead.

SCENARIOS (each prints PASS or FAIL; any FAIL makes the script exit nonzero)
  1. preflight     the VM is Fedora 45 Workstation and the converter repo is
                   present there;
  2. full-run      one full converter run, then --verify passes;
  3. idempotency   a second run reports every step as skipped, --verify passes;
  4. interrupt     a staged converter run is killed with SIGINT while a .part
                   download is in progress (simulated Ctrl+C), the interrupted
                   marker must appear, then a resume and --verify must pass;
  5. corruption    flip a byte in one staged asset/RPM in the VM state dir,
                   resume, and check that only that file is refetched (all other
                   staged files keep their checksums) and --verify passes.

EXAMPLE
  RUN_E2E=1 E2E_HOST=vm.example E2E_USER=root \
    E2E_SSH_OPTS='-o StrictHostKeyChecking=no -i ~/.ssh/vm.key' \
    E2E_REPO_DIR=/root/gnome-devstation \
    migrate/tests/e2e.sh
EOF
}

# ----- configuration (all overridable from the environment) -----------------
SSH_BIN="${SSH_BIN:-ssh}"
E2E_HOST="${E2E_HOST:-}"
E2E_USER="${E2E_USER:-}"
E2E_SSH_OPTS="${E2E_SSH_OPTS:-}"
E2E_STATE_DIR="${E2E_STATE_DIR:-/var/lib/gnome-devstation-migrate}"
E2E_REPO_DIR="${E2E_REPO_DIR:-/root/gnome-devstation}"
E2E_SUDO="${E2E_SUDO:-sudo}"
FEDORA_RELEASE="${FEDORA_RELEASE:-45}"

# Populated by paths(), at driver run time (so --self-test overrides are seen).
REPO_Q=""
STATE_Q=""
fail_count=0

# Single-quote a value for the remote shell.
rq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

paths() {
	REPO_Q="$(rq "$E2E_REPO_DIR")"
	STATE_Q="$(rq "$E2E_STATE_DIR")"
}

# Run the converter on the VM, with optional migrate.sh arguments. The flags we
# pass are trusted literals; the surrounding remote command is quoted as a whole
# by ssh_cmd below.
conv() {
	printf 'cd %s && %s migrate/migrate.sh' "$REPO_Q" "$E2E_SUDO"
}

# Expand the path/command placeholders in a remote-command template into
# already shell-quoted values. Templates are written in single-quoted heredocs,
# so all remote-side $variables survive untouched.
expand() {
	local t="$1"
	t="${t//@REPO@/$REPO_Q}"
	t="${t//@STATE@/$STATE_Q}"
	t="${t//@CONV@/$(conv)}"
	t="${t//@REL@/$FEDORA_RELEASE}"
	printf '%s' "$t"
}

# The one place that talks to the VM. The remote command is passed as a single
# quoted argument: the local shell never interprets it, the remote shell does.
ssh_cmd() {
	local remote="$1" target opts=()
	if [ -n "$E2E_SSH_OPTS" ]; then
		read -r -a opts <<<"$E2E_SSH_OPTS"
	fi
	if [ -n "$E2E_USER" ]; then
		target="$E2E_USER@$E2E_HOST"
	else
		target="$E2E_HOST"
	fi
	"$SSH_BIN" "${opts[@]}" "$target" "$remote"
}

# Read a remote-command template from stdin, expand it, send it over ssh.
ssh_tmpl() {
	local t
	t="$(cat)"
	ssh_cmd "$(expand "$t")"
}

# ----- reporting ------------------------------------------------------------
report() {
	local name="$1" rc="$2"
	if [ "$rc" -eq 0 ]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		fail_count=$((fail_count + 1))
	fi
}

run_scenario() {
	local name="$1" fn="$2" rc=0
	"$fn" || rc=$?
	report "$name" "$rc"
}

# ----- scenario 1: VM identity and converter checkout -----------------------
sc_preflight() {
	ssh_tmpl <<'EOF' || return 1
# e2e:preflight
. /etc/os-release || exit 1
if [ "$ID" != fedora ] || [ "$VERSION_ID" != @REL@ ] || [ "$VARIANT_ID" != workstation ]; then
  echo "e2e: VM is not Fedora @REL@ Workstation (ID=$ID VERSION_ID=$VERSION_ID VARIANT_ID=$VARIANT_ID)" >&2
  exit 1
fi
for f in migrate/migrate.sh files/verify-devstation.sh kickstart/gnome-devstation.ks manifests/assets.sha256; do
  [ -f @REPO@/$f ] || { echo "e2e: converter repo missing $f under @REPO@" >&2; exit 1; }
done
echo "e2e: VM is Fedora @REL@ Workstation; converter repo present"
EOF
}

# ----- scenario 2: one full run, then the gate ------------------------------
sc_full_run() {
	ssh_tmpl <<'EOF' || return 1
# e2e:full-run
@CONV@ || { echo "e2e: full converter run failed" >&2; exit 1; }
@CONV@ --verify || { echo "e2e: --verify gate failed after the full run" >&2; exit 1; }
echo "e2e: full converter run and --verify passed"
EOF
}

# ----- scenario 3: idempotent re-run ---------------------------------------
sc_idempotent() {
	ssh_tmpl <<'EOF' || return 1
# e2e:idempotency
log=@STATE@/e2e-idempotent.log
@CONV@ >"$log" 2>&1 || { echo "e2e: converter re-run failed" >&2; cat "$log" >&2; exit 1; }
cat "$log"
missing=0
for s in 00-preflight 10-assets 20-rpms 30-upgrade 40-repos 50-add 60-remove 70-config 80-flatpak 90-verify; do
  grep -qiE "($s.*(skip|already|up.to.date)|(skip|already|up.to.date).*$s)" "$log" || {
    echo "e2e: step $s was not reported as skipped on the re-run" >&2
    missing=1
  }
done
[ "$missing" -eq 0 ] || { echo "e2e: not every step was skipped on the re-run" >&2; exit 1; }
@CONV@ --verify || { echo "e2e: --verify gate failed after the re-run" >&2; exit 1; }
echo "e2e: re-run skipped every step and --verify passed"
EOF
}

# ----- scenario 4: simulated Ctrl+C mid-download, then resume ---------------
sc_interrupt_start() {
	ssh_tmpl <<'EOF' || return 1
# e2e:interrupt-start
rm -f @STATE@/interrupted @STATE@/e2e-interrupt.log @STATE@/e2e-interrupt.pid
nohup bash -c "@CONV@" </dev/null >@STATE@/e2e-interrupt.log 2>&1 &
echo $! > @STATE@/e2e-interrupt.pid
sleep 1
kill -0 "$(cat @STATE@/e2e-interrupt.pid)" 2>/dev/null || { echo "e2e: staged converter did not start" >&2; exit 1; }
echo "e2e: staged converter running (pid $(cat @STATE@/e2e-interrupt.pid))"
EOF
}

sc_interrupt_wait_download() {
	ssh_tmpl <<'EOF' || return 1
# e2e:interrupt-wait-download
pid="$(cat @STATE@/e2e-interrupt.pid)"
for i in $(seq 1 120); do
  if ls @STATE@/assets/*.part >/dev/null 2>&1 || ls @STATE@/rpms/*.part >/dev/null 2>&1; then
    echo "e2e: download in progress (staged .part file present)"
    exit 0
  fi
  kill -0 "$pid" 2>/dev/null || { echo "e2e: converter exited before a download began" >&2; exit 1; }
  sleep 1
done
echo "e2e: no staged .part file appeared within 120s" >&2
exit 1
EOF
}

sc_interrupt_kill() {
	ssh_tmpl <<'EOF' || return 1
# e2e:interrupt-kill
pid="$(cat @STATE@/e2e-interrupt.pid)"
kill -INT "$pid" || { echo "e2e: could not signal staged converter" >&2; exit 1; }
for i in $(seq 1 30); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
for i in $(seq 1 30); do
  [ -s @STATE@/interrupted ] && break
  sleep 1
done
[ -s @STATE@/interrupted ] || { echo "e2e: no interrupted marker appeared after SIGINT" >&2; exit 1; }
echo "e2e: SIGINT delivered; interrupted marker written"
EOF
}

sc_interrupt_resume() {
	ssh_tmpl <<'EOF' || return 1
# e2e:interrupt-resume
@CONV@ || { echo "e2e: resume after interrupt failed" >&2; exit 1; }
@CONV@ --verify || { echo "e2e: --verify gate failed after interrupt recovery" >&2; exit 1; }
echo "e2e: resume after interrupt completed"
EOF
}

sc_interrupt_all() {
	sc_interrupt_start && sc_interrupt_wait_download && sc_interrupt_kill && sc_interrupt_resume
}

# ----- scenario 5: corrupt one staged file, resume, check isolated refetch --
sc_corrupt() {
	ssh_tmpl <<'EOF' || return 1
# e2e:corrupt
list=@STATE@/e2e-corrupt-files
sums=@STATE@/e2e-corrupt-sums
target=@STATE@/e2e-corrupt-target
orig=@STATE@/e2e-corrupt-orig.sha
find @STATE@/assets @STATE@/rpms -type f \( -name '*.rpm' -o -name '*.asc' -o -name '*.key' \) 2>/dev/null | sort > "$list"
[ -s "$list" ] || { echo "e2e: no staged asset/RPM to corrupt under @STATE@" >&2; exit 1; }
: > "$sums"
while read -r p; do sha256sum "$p"; done < "$list" >> "$sums"
f="$(head -1 "$list")"
before="$(sha256sum "$f" | cut -d' ' -f1)"
printf '%s' "$before" > "$orig"
printf '%s' "$f" > "$target"
printf 'X' | dd of="$f" bs=1 seek=0 conv=notrunc status=none
after="$(sha256sum "$f" | cut -d' ' -f1)"
[ "$before" != "$after" ] || { echo "e2e: flipping a byte did not change $f" >&2; exit 1; }
echo "e2e: flipped a byte in $f"
EOF
}

sc_corrupt_resume() {
	ssh_tmpl <<'EOF' || return 1
# e2e:corrupt-resume
list=@STATE@/e2e-corrupt-files
sums=@STATE@/e2e-corrupt-sums
target=@STATE@/e2e-corrupt-target
orig=@STATE@/e2e-corrupt-orig.sha
f="$(cat "$target")"
base="$(basename "$f")"
want="$(cat "$orig")"
log=@STATE@/e2e-corrupt-resume.log
@CONV@ >"$log" 2>&1 || { echo "e2e: converter run failed after corruption" >&2; cat "$log" >&2; exit 1; }
cat "$log"
grep -qF "$base" "$log" || { echo "e2e: resume log does not mention damaged file $base" >&2; exit 1; }
got="$(sha256sum "$f" | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo "e2e: damaged staged file was not refetched correctly" >&2; exit 1; }
while read -r h p; do
  [ "$p" = "$f" ] && continue
  cur="$(sha256sum "$p" | cut -d' ' -f1)"
  [ "$cur" = "$h" ] || { echo "e2e: unrelated staged file changed: $p" >&2; exit 1; }
done < "$sums"
@CONV@ --verify || { echo "e2e: --verify gate failed after corruption recovery" >&2; exit 1; }
echo "e2e: corruption recovery passed; only the damaged file was refetched"
EOF
}

sc_corrupt_all() {
	sc_corrupt && sc_corrupt_resume
}

# ----- the driver, shared by the real run and --self-test -------------------
run_all_scenarios() {
	fail_count=0
	paths
	run_scenario "VM is Fedora 45 Workstation with the converter repo" sc_preflight
	run_scenario "full converter run and --verify gate" sc_full_run
	run_scenario "idempotent re-run (every step skipped)" sc_idempotent
	run_scenario "simulated Ctrl+C mid-download and resume" sc_interrupt_all
	run_scenario "corrupt staged asset/RPM and recover" sc_corrupt_all
	[ "$fail_count" -eq 0 ]
}

# ----- offline unit test: stub ssh, assert the commands the driver issues ---
run_self_test() {
	local tmp log cmds stub out rc=0 st=0 pass_n fail_n tag cmd_n=0 cur line
	tmp="$(mktemp -d)"
	log="$tmp/ssh.log"
	cmds="$tmp/ssh-cmds.log"
	stub="$tmp/fake-ssh"
	cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$E2E_STUB_LOG"
for a in "$@"; do last="$a"; done
printf '%s\n@@EOC@@\n' "$last" >>"$E2E_STUB_CMDS"
exit 0
EOF
	chmod +x "$stub"

	out="$(
		export SSH_BIN="$stub" E2E_STUB_LOG="$log" E2E_STUB_CMDS="$cmds"
		export E2E_HOST="e2e.invalid" E2E_USER="tester" E2E_SSH_OPTS="-o BatchMode=yes"
		export E2E_STATE_DIR="/tmp/e2e-fake-state" E2E_REPO_DIR="/tmp/e2e-fake-repo"
		export RUN_E2E=1
		run_all_scenarios 2>&1
	)" || rc=$?
	printf '%s\n' "$out"

	[ "$rc" -eq 0 ] || {
		echo "self-test: driver exited $rc" >&2
		st=1
	}
	pass_n="$(printf '%s\n' "$out" | grep -c '^PASS ' || true)"
	fail_n="$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)"
	[ "$pass_n" -eq 5 ] || {
		echo "self-test: expected 5 PASS lines, got $pass_n" >&2
		st=1
	}
	[ "$fail_n" -eq 0 ] || {
		echo "self-test: got $fail_n FAIL lines" >&2
		st=1
	}

	for tag in preflight full-run idempotency interrupt-start interrupt-wait-download \
		interrupt-kill interrupt-resume corrupt corrupt-resume; do
		grep -qF "e2e:$tag" "$log" || {
			echo "self-test: driver never issued scenario command e2e:$tag" >&2
			st=1
		}
	done
	grep -qF 'migrate/migrate.sh --verify' "$log" || {
		echo "self-test: no --verify command was issued" >&2
		st=1
	}
	grep -qF 'kill -INT' "$log" || {
		echo "self-test: no SIGINT was issued" >&2
		st=1
	}
	grep -qF 'dd of=' "$log" || {
		echo "self-test: no byte-flip command was issued" >&2
		st=1
	}
	grep -qF 'sha256sum' "$log" || {
		echo "self-test: no checksum assertion was issued" >&2
		st=1
	}
	grep -qF 'e2e.invalid' "$log" || {
		echo "self-test: driver did not target E2E_HOST" >&2
		st=1
	}

	# Every generated remote command must be complete, fully expanded and
	# syntactically valid before anyone points this at a real VM.
	cur=""
	while IFS= read -r line; do
		if [ "$line" = '@@EOC@@' ]; then
			[ -n "$cur" ] || {
				echo "self-test: empty generated command" >&2
				st=1
			}
			case "$cur" in
			*'@REPO@'* | *'@STATE@'* | *'@CONV@'* | *'@REL@'*)
				echo "self-test: unexpanded placeholder in: $cur" >&2
				st=1
				;;
			esac
			if ! printf '%s\n' "$cur" | bash -n; then
				echo "self-test: generated command has a syntax error: $cur" >&2
				st=1
			fi
			cmd_n=$((cmd_n + 1))
			cur=""
		else
			cur+="${cur:+$'\n'}$line"
		fi
	done <"$cmds"
	[ "$cmd_n" -eq 9 ] || {
		echo "self-test: expected 9 generated commands, got $cmd_n" >&2
		st=1
	}

	rm -rf "$tmp"
	if [ "$st" -eq 0 ]; then
		echo "self-test: OK (SSH stubbed; no host contacted)"
	else
		echo "self-test: FAILED" >&2
	fi
	return "$st"
}

# ----- entry point ----------------------------------------------------------
want_help=0
run_test=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	-h | --help) want_help=1 ;;
	--self-test) run_test=1 ;;
	*)
		echo "e2e: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

if [ "$want_help" -eq 1 ]; then
	usage
	exit 0
fi

if [ "$run_test" -eq 1 ]; then
	run_self_test
	exit $?
fi

if [ "${RUN_E2E:-0}" != "1" ]; then
	echo "e2e: SKIPPED -- destructive VM test is opt-in. Set RUN_E2E=1 (and E2E_HOST/E2E_USER) to run it; see --help."
	exit 0
fi

if [ -z "$E2E_HOST" ]; then
	echo "e2e: E2E_HOST is required when RUN_E2E=1" >&2
	exit 2
fi

if run_all_scenarios; then
	rc=0
else
	rc=$?
fi
if [ "$rc" -eq 0 ]; then
	echo "e2e: all scenarios passed"
else
	echo "e2e: $fail_count scenario(s) failed"
fi
exit "$rc"
