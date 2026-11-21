# Step 90: run the verification gate on the converted system.
#
# The gate is files/verify-devstation.sh, the same script the ISO's chrooted
# %post runs, so an install-time regression fails the conversion too. The step
# itself never exits: a nonzero script exit becomes a nonzero step_run()
# return for the runner.

step_run() {
	rm -f "$STATE_DIR/converted"
	"$REPO_DIR/files/verify-devstation.sh" || return 1
	mkdir -p "$STATE_DIR"
	: >"$STATE_DIR/converted"
	return 0
}

step_plan() {
	echo "run the verification gate: $REPO_DIR/files/verify-devstation.sh"
}
