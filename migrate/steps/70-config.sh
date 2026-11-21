#!/usr/bin/env bash
# Step 70-config: apply the devstation configuration.
#
# Mirrors the config work of the kickstart %posts: the file installs in
# the nochroot %post (kickstart/gnome-devstation.ks:320-358) and the
# system configuration in the chrooted one (:364-450) — profile.d, the
# dconf profile and db, repos/*.repo, Chrome's system-wide
# default-browser mimeapps.list, the dnf-automatic security-updates sed
# edits and timer, and the live `dconf update`. Every path is prefixed
# with $ROOT, so the step works for the live system (ROOT=/) and for the
# in-place converter on a target root.
#
# Sources: files/90-devstation.sh, files/dconf-profile-user,
# files/dconf-00-devstation, repos/*.repo, and the [Default Applications]
# block quoted from the kickstart.
#
# Sourced by lib/runner.sh; see CONTRACT.md "Step contract".

step_plan() {
	cat <<'EOF'
apply devstation config:
  - files/90-devstation.sh     -> $ROOT/etc/profile.d/90-devstation.sh
  - files/dconf-profile-user   -> $ROOT/etc/dconf/profile/user
  - files/dconf-00-devstation  -> $ROOT/etc/dconf/db/local.d/00-devstation
  - repos/*.repo               -> $ROOT/etc/yum.repos.d/
  - write $ROOT/etc/xdg/mimeapps.list (Chrome defaults from the kickstart)
  - sed $ROOT/etc/dnf/automatic.conf: apply_updates=yes, upgrade_type=security
  - systemctl enable dnf5-automatic.timer / dnf-automatic.timer (when ROOT=/)
  - dconf update (when ROOT=/)
EOF
}

step_run() {
	# Body in a subshell with -euo pipefail: a failing command exits the
	# subshell with its status, so step_run returns nonzero without
	# ever exiting the runner (CONTRACT.md, "Step contract").
	(
		set -euo pipefail

		REPO_DIR=${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}
		ROOT=${ROOT:-/}
		STATE_DIR=${STATE_DIR:-/var/lib/gnome-devstation-migrate}
		DRY_RUN=${DRY_RUN:-0}

		# Progress goes through state_log when the runner provides it
		# (migrate/lib/state.sh); standalone runs get a timestamped line.
		if declare -F state_log >/dev/null 2>&1; then
			:
		else
			state_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
		fi

		# install_if_changed <src> <dest>: `install -Dm0644` (atomic,
		# mode-correct copy) plus a cmp -s guard so an already-identical
		# destination is not rewritten; a same-content destination is
		# chmod'ed to 0644 instead. Fails when src is missing or the
		# copy does not verify.
		install_if_changed() {
			local src="$1" dest="$2"
			if [ ! -f "$src" ]; then
				state_log "missing source: $src"
				return 1
			fi
			if [ "$DRY_RUN" = 1 ]; then
				state_log "DRY RUN: would install $src -> $dest"
				return 0
			fi
			if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
				chmod 0644 "$dest"
				return 0
			fi
			install -Dm0644 "$src" "$dest"
			cmp -s "$src" "$dest"
		}

		state_log "applying devstation config (ROOT=$ROOT)"

		# 1. Files from the ISO: profile.d, dconf profile, dconf db.
		install_if_changed "$REPO_DIR/files/90-devstation.sh" \
			"$ROOT/etc/profile.d/90-devstation.sh"
		install_if_changed "$REPO_DIR/files/dconf-profile-user" \
			"$ROOT/etc/dconf/profile/user"
		install_if_changed "$REPO_DIR/files/dconf-00-devstation" \
			"$ROOT/etc/dconf/db/local.d/00-devstation"

		# 2. Third-party repo definitions for the installed system.
		repos=("$REPO_DIR"/repos/*.repo)
		if [ ! -f "${repos[0]:-}" ]; then
			state_log "no repos/*.repo under $REPO_DIR/repos"
			return 1
		fi
		for repo in "${repos[@]}"; do
			install_if_changed "$repo" \
				"$ROOT/etc/yum.repos.d/$(basename "$repo")"
		done

		# 3. Chrome as the system-wide default browser. xdg-settings
		#    needs a live user session, so this is a system-wide
		#    /etc/xdg/mimeapps.list; the Helium repo stays enabled so
		#    it can be installed later without editing anything.
		dest="$ROOT/etc/xdg/mimeapps.list"
		if [ "$DRY_RUN" = 1 ]; then
			state_log "DRY RUN: would write $dest"
		else
			mkdir -p "$STATE_DIR"
			tmp=$(mktemp "$STATE_DIR/mimeapps.XXXXXX")
			# The subshell's EXIT trap cleans the temp file up on both success
			# and failure; nothing is left behind in STATE_DIR.
			trap 'rm -f "$tmp"' EXIT
			cat >"$tmp" <<'EOF'
[Default Applications]
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
x-scheme-handler/about=google-chrome.desktop
text/html=google-chrome.desktop
application/xhtml+xml=google-chrome.desktop
EOF
			if [ ! -f "$dest" ] || ! cmp -s "$tmp" "$dest"; then
				install -Dm0644 "$tmp" "$dest"
			else
				chmod 0644 "$dest"
			fi
			cmp -s "$tmp" "$dest" || return 1
		fi

		# 4. Security updates in the background (dnf-automatic). The
		#    sed edits mirror the kickstart; `|| true` keeps the step
		#    going when the file or the patterns are absent.
		if [ -f "$ROOT/etc/dnf/automatic.conf" ]; then
			if [ "$DRY_RUN" = 1 ]; then
				state_log "DRY RUN: would sed apply_updates=yes, upgrade_type=security in $ROOT/etc/dnf/automatic.conf"
			else
				sed -i -e 's/^apply_updates = no/apply_updates = yes/' \
					-e 's/^upgrade_type = default/upgrade_type = security/' \
					"$ROOT/etc/dnf/automatic.conf" || true
			fi
		fi

		# 5. Enable the automatic timer. Live-system action, so it runs
		#    only when ROOT=/ and the unit file exists in the target
		#    tree; with any other ROOT, `systemctl enable` would write
		#    to the live system.
		if [ "$ROOT" = "/" ]; then
			if [ -f "$ROOT/usr/lib/systemd/system/dnf5-automatic.timer" ]; then
				if [ "$DRY_RUN" = 1 ]; then
					state_log "DRY RUN: would systemctl enable dnf5-automatic.timer"
				else
					systemctl enable dnf5-automatic.timer
				fi
			elif [ -f "$ROOT/usr/lib/systemd/system/dnf-automatic.timer" ]; then
				if [ "$DRY_RUN" = 1 ]; then
					state_log "DRY RUN: would systemctl enable dnf-automatic.timer"
				else
					systemctl enable dnf-automatic.timer
				fi
			fi
		fi

		# 6. Compile the system dconf database. Live-system action:
		#    only when ROOT=/ and dconf is installed.
		if [ "$ROOT" = "/" ] && command -v dconf >/dev/null 2>&1; then
			if [ "$DRY_RUN" = 1 ]; then
				state_log "DRY RUN: would dconf update"
			else
				dconf update
			fi
		fi

		# Final gate: every target is on disk and byte-identical to its
		# source or expected content. Anything else fails the step.
		if [ "$DRY_RUN" = 1 ]; then
			state_log "DRY RUN: skipped install verification"
			return 0
		fi

		cmp -s "$REPO_DIR/files/90-devstation.sh" \
			"$ROOT/etc/profile.d/90-devstation.sh" || return 1
		cmp -s "$REPO_DIR/files/dconf-profile-user" \
			"$ROOT/etc/dconf/profile/user" || return 1
		cmp -s "$REPO_DIR/files/dconf-00-devstation" \
			"$ROOT/etc/dconf/db/local.d/00-devstation" || return 1
		for repo in "${repos[@]}"; do
			cmp -s "$repo" \
				"$ROOT/etc/yum.repos.d/$(basename "$repo")" || return 1
		done
		# A same-content destination may have been created with the wrong
		# mode, so verify 0644 on every installed target as well.
		targets=(
			"$ROOT/etc/profile.d/90-devstation.sh"
			"$ROOT/etc/dconf/profile/user"
			"$ROOT/etc/dconf/db/local.d/00-devstation"
			"$ROOT/etc/xdg/mimeapps.list"
		)
		for repo in "${repos[@]}"; do
			targets+=("$ROOT/etc/yum.repos.d/$(basename "$repo")")
		done
		for f in "${targets[@]}"; do
			if [ "$(stat -c %a "$f")" != 644 ]; then
				state_log "wrong mode on $f"
				return 1
			fi
		done
	)
}
