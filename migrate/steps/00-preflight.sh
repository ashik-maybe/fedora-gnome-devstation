# 00-preflight -- fresh Fedora 45 Workstation input checks for the converter.
#
# Sourced by migrate.sh's runner (see migrate/CONTRACT.md, step 00-preflight).
# Like every step it defines step_run()/step_plan(); the runner calls
# step_run() and writes the done marker only when it returns 0, so failures
# come back as a nonzero return, never as exit.
#
# step_run() checks:
#   1. the os-release file says ID=fedora, VARIANT_ID=workstation,
#      VERSION_ID=45 (FEDORA_RELEASE, default 45);
#   2. root privileges (id -u = 0) unless ROOT != /;
#   3. at least 15 GiB free on the filesystem holding STATE_DIR;
#   4. $STATE_DIR/converted is absent;
#   5. records the current dnf history id into $STATE_DIR/dnf-history-before
#      when dnf is installed (skipped in DRY_RUN);
#   6. prints a Btrfs snapshot advice line (a snapshot is advice, not action).
#
# Writes: only $STATE_DIR/dnf-history-before. Everything else goes to
# stdout/stderr. Idempotent: re-running re-checks and re-records the baseline.
#
# This file is SOURCED by the runner: no shell options are set at file scope,
# and step_run uses a subshell body so its `set +e` cannot leak into the runner.

# --- helpers ---------------------------------------------------------------

# Log through the runner's state_log when it provides one, else to stdout.
_preflight_log() {
	if declare -F state_log >/dev/null 2>&1; then
		state_log "$@"
	else
		printf '%s\n' "$*"
	fi
}

# Report a failed check; the caller then returns nonzero.
_preflight_fail() {
	_preflight_log "preflight: FAIL: $*"
	return 1
}

# Print the value of KEY from an os-release file, quotes stripped.
# Returns nonzero when the key line is absent.
_preflight_os_field() {
	local file="$1" key="$2" line
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"$key="*)
			line="${line#"$key="}"
			line="${line#\"}"
			line="${line%\"}"
			printf '%s\n' "$line"
			return 0
			;;
		esac
	done <"$file"
	return 1
}

# --- step API (sourced by the runner) ---------------------------------------

# step_plan(): print what would happen; the runner shows this for --plan.
step_plan() {
	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	_preflight_log "preflight: verify ID=fedora, VARIANT_ID=workstation, VERSION_ID=${FEDORA_RELEASE:-45} in ${OS_RELEASE_FILE:-/etc/os-release}; root unless ROOT!=/; at least 15 GiB free on $state_dir; no $state_dir/converted marker; record dnf history baseline in $state_dir/dnf-history-before; print Btrfs snapshot advice"
}

# step_run(): run the checks above. Returns nonzero on failure. The subshell
# body keeps `set +e` and every local variable out of the runner's shell.
step_run() (
	# -e would exit the runner's shell instead of letting us return the
	# status; the runner reads our return, so report failures by returning.
	set +e

	local state_dir="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	local os_file="${OS_RELEASE_FILE:-/etc/os-release}"
	local os_id os_variant os_version avail_kib current_id
	local required_kib=$((15 * 1024 * 1024)) # 15 GiB in 1K-block units

	# 1. Distro identity from the os-release file.
	if [ ! -r "$os_file" ]; then
		_preflight_fail "cannot read os-release file: $os_file"
		return 1
	fi
	os_id=$(_preflight_os_field "$os_file" ID) || os_id="<missing>"
	os_variant=$(_preflight_os_field "$os_file" VARIANT_ID) || os_variant="<missing>"
	os_version=$(_preflight_os_field "$os_file" VERSION_ID) || os_version="<missing>"

	if [ "$os_id" != "fedora" ]; then
		_preflight_fail "expected ID=fedora in $os_file, found '$os_id'"
		return 1
	fi
	if [ "$os_variant" != "workstation" ]; then
		_preflight_fail "expected VARIANT_ID=workstation in $os_file, found '$os_variant'"
		return 1
	fi
	if [ "$os_version" != "${FEDORA_RELEASE:-45}" ]; then
		_preflight_fail "expected VERSION_ID=${FEDORA_RELEASE:-45} in $os_file, found '$os_version'"
		return 1
	fi

	# 2. Root privileges; waived when ROOT != / (e.g. test sandboxes).
	if [ "${ROOT:-/}" = "/" ] && [ "$(id -u)" != "0" ]; then
		_preflight_fail "must run as root when ROOT=/; found uid $(id -u), run with sudo"
		return 1
	fi

	# 3. At least 15 GiB free on the filesystem holding STATE_DIR.
	# -P keeps GNU df from wrapping a long LVM device name onto its own
	# line, which would make awk read the wrong row on a real Workstation.
	avail_kib=$(df -kP "$state_dir" 2>/dev/null | awk 'NR > 1 { print $4; exit }')
	if [ -z "$avail_kib" ]; then
		_preflight_fail "cannot determine free space on the filesystem holding $state_dir"
		return 1
	fi
	case "$avail_kib" in
	'' | *[!0-9]*)
		_preflight_fail "unexpected df output for $state_dir: '$avail_kib'"
		return 1
		;;
	esac
	if [ "$avail_kib" -lt "$required_kib" ]; then
		_preflight_fail "not enough free space: need 15 GiB, found $((avail_kib / 1048576)) GiB free on $state_dir"
		return 1
	fi

	# 4. Not already converted.
	if [ -e "$state_dir/converted" ]; then
		_preflight_fail "$state_dir/converted already exists: the system is already converted"
		return 1
	fi

	# 5. dnf history baseline (not in DRY_RUN).
	if [ "${DRY_RUN:-0}" = "1" ]; then
		_preflight_log "preflight: DRY_RUN: would record the dnf history baseline to $state_dir/dnf-history-before"
	else
		if command -v dnf >/dev/null 2>&1; then
			# Current transaction id: the highest id in dnf history output.
			current_id=$(dnf history list 2>/dev/null | awk '
				$1 ~ /^[0-9]+$/ && $1 + 0 > max + 0 { max = $1 + 0 }
				END { if (max != 0) print max }
			')
			if [ -n "$current_id" ]; then
				printf '%s\n' "$current_id" >"$state_dir/dnf-history-before" ||
					{
						_preflight_fail "cannot write $state_dir/dnf-history-before"
						return 1
					}
			else
				_preflight_log "preflight: no dnf history transactions found; nothing recorded"
			fi
		fi
	fi

	# 6. Btrfs snapshot advice; no snapshot is created here.
	_preflight_log "advice: take a Btrfs snapshot of / before converting: sudo btrfs subvolume snapshot / gnome-devstation-$(date +%F)"

	return 0
)
