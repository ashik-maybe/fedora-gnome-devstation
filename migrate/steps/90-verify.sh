# Step 90: run the verification gate on the converted system.
#
# The gate is files/verify-devstation.sh, the same script the ISO's chrooted
# %post runs, so an install-time regression fails the conversion too. The step
# itself never exits: a nonzero script exit becomes a nonzero step_run()
# return for the runner.

step_run() (
	set -euo pipefail

	: "${REPO_DIR:?REPO_DIR must be set}"
	: "${STATE_DIR:?STATE_DIR must be set}"

	if [ "${DRY_RUN:-0}" = 1 ]; then
		step_plan
		return 0
	fi

	rm -f -- "$STATE_DIR/converted"
	"$REPO_DIR/files/verify-devstation.sh"

	mkdir -p -- "$STATE_DIR"
	: >"$STATE_DIR/converted"
	[ -f "$STATE_DIR/converted" ] || {
		printf '90-verify: converted marker was not written: %s\n' "$STATE_DIR/converted" >&2
		exit 1
	}
)

step_plan() {
	echo "run the verification gate: ${REPO_DIR:-<REPO_DIR>}/files/verify-devstation.sh"
}
