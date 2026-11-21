# migrate/steps/10-assets.sh
#
# Stage the four assets that kickstart/gnome-devstation.ks imports:
# the two RPM Fusion release RPMs and the Chrome/Helium signing keys.
#
# This file is SOURCED by migrate/lib/runner.sh.  It enables no shell options,
# never calls exit, and does its work in a subshell function so that the
# runner's variables and options are left untouched.
#
# The manifest is pinned to FEDORA_RELEASE=45. Local basenames match the
# kickstart's asset names; only the URLs carry the Fedora release number
# (build.sh:109-114).

_ASSETS_KNOWN=(
	rpmfusion-free-release.noarch.rpm
	rpmfusion-nonfree-release.noarch.rpm
	google-chrome.asc
	helium-copr.asc
)

_ASSETS_NAMES=()
_ASSETS_HASHES=()

# Standalone use (tests, `source` from a shell) has no lib/state.sh loaded.
if ! declare -F state_log >/dev/null 2>&1; then
	state_log() { printf '%s\n' "$*"; }
fi

_assets_env() {
	local step_dir
	step_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" || return 1
	REPO_DIR="${REPO_DIR:-$(dirname -- "$(dirname -- "$step_dir")")}"
	STATE_DIR="${STATE_DIR:-/var/lib/gnome-devstation-migrate}"
	ASSETS_DIR="${ASSETS_DIR:-$STATE_DIR/assets}"
	DRY_RUN="${DRY_RUN:-0}"
}

_assets_manifest_path() {
	printf '%s\n' "${REPO_DIR%/}/migrate/manifests/assets.sha256"
}

_assets_url_for() {
	case $1 in
	rpmfusion-free-release.noarch.rpm)
		printf '%s\n' 'https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-45.noarch.rpm'
		;;
	rpmfusion-nonfree-release.noarch.rpm)
		printf '%s\n' 'https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-45.noarch.rpm'
		;;
	google-chrome.asc)
		printf '%s\n' 'https://dl.google.com/linux/linux_signing_key.pub'
		;;
	helium-copr.asc)
		printf '%s\n' 'https://download.copr.fedorainfracloud.org/results/imput/helium/pubkey.gpg'
		;;
	*)
		return 1
		;;
	esac
}

_assets_hash_of() {
	local line
	line="$(sha256sum -- "$1" 2>/dev/null)" || return 1
	printf '%s\n' "${line%% *}"
}

# Load the staging library once.  A test may supply its own download_stage().
_assets_load_download_lib() {
	if declare -F download_stage >/dev/null 2>&1; then
		return 0
	fi
	if [ -z "${_LIB_DOWNLOAD_LOADED:-}" ]; then
		local lib="${REPO_DIR%/}/migrate/lib/download.sh"
		[ -r "$lib" ] || {
			state_log "assets: missing staging library $lib"
			return 1
		}
		# shellcheck source=/dev/null
		source "$lib" || {
			state_log "assets: cannot source $lib"
			return 1
		}
	fi
	declare -F download_stage >/dev/null 2>&1 || {
		state_log 'assets: download_stage is not available'
		return 1
	}
}

# Read sha256sum-format lines into _ASSETS_NAMES / _ASSETS_HASHES.  Rejects
# malformed, duplicate or unexpected entries: an edited manifest must fail
# loudly rather than silently stage something else.
_assets_load_manifest() {
	local manifest hash name extra known existing declared count=0
	manifest="$(_assets_manifest_path)"
	[ -r "$manifest" ] || {
		state_log "assets: cannot read $manifest"
		return 1
	}

	_ASSETS_NAMES=()
	_ASSETS_HASHES=()
	while read -r hash name extra || [ -n "${hash:-}${name:-}" ]; do
		[ -n "${hash:-}" ] || continue
		case $hash in \#*) continue ;; esac
		if [ -n "${extra:-}" ]; then
			state_log "assets: malformed manifest line: $hash $name $extra"
			return 1
		fi
		if [[ ! $hash =~ ^[0-9a-f]{64}$ ]]; then
			state_log "assets: bad checksum in $manifest: ${hash}"
			return 1
		fi
		if [ -z "${name:-}" ] || [[ $name == */* ]]; then
			state_log "assets: bad basename in $manifest: ${name}"
			return 1
		fi
		declared=0
		for known in "${_ASSETS_KNOWN[@]}"; do
			if [ "$name" = "$known" ]; then
				declared=1
				break
			fi
		done
		if [ "$declared" -ne 1 ]; then
			state_log "assets: unexpected asset in $manifest: $name"
			return 1
		fi
		for existing in "${_ASSETS_NAMES[@]}"; do
			if [ "$name" = "$existing" ]; then
				state_log "assets: duplicate asset in $manifest: $name"
				return 1
			fi
		done
		_ASSETS_NAMES+=("$name")
		_ASSETS_HASHES+=("$hash")
		count=$((count + 1))
	done <"$manifest"

	if [ "$count" -ne "${#_ASSETS_KNOWN[@]}" ]; then
		state_log "assets: expected ${#_ASSETS_KNOWN[@]} entries in $manifest, found $count"
		return 1
	fi
}

step_plan() (
	_assets_env || return 1
	_assets_load_manifest || return 1
	local i name url hash
	printf 'Stage %d verified assets into %s:\n' "${#_ASSETS_NAMES[@]}" "$ASSETS_DIR"
	for i in "${!_ASSETS_NAMES[@]}"; do
		name=${_ASSETS_NAMES[$i]}
		hash=${_ASSETS_HASHES[$i]}
		url=$(_assets_url_for "$name") || return 1
		printf '  %-38s %s  (sha256 %s)\n' "$name" "$url" "$hash"
	done
	return 0
)

step_run() (
	_assets_env || return 1
	_assets_load_manifest || return 1

	if [ "$DRY_RUN" = 1 ]; then
		step_plan
		return $?
	fi

	_assets_load_download_lib || return 1
	mkdir -p -- "$ASSETS_DIR" || return 1

	local i name hash url dest have
	for i in "${!_ASSETS_NAMES[@]}"; do
		name=${_ASSETS_NAMES[$i]}
		hash=${_ASSETS_HASHES[$i]}
		url=$(_assets_url_for "$name") || {
			state_log "assets: no URL for $name"
			return 1
		}
		dest="$ASSETS_DIR/$name"

		if [ -L "$dest" ]; then
			state_log "assets: $name is a symlink; removing and refetching as a real file"
			rm -f -- "$dest" || return 1
		elif [ -f "$dest" ]; then
			have=$(_assets_hash_of "$dest") || {
				state_log "assets: cannot hash $dest"
				return 1
			}
			if [ "$have" = "$hash" ]; then
				state_log "assets: $name already staged"
				continue
			fi
			# Delete only the corrupt file; other staged assets stay put.
			state_log "assets: $name has the wrong checksum; refetching only $name"
			rm -f -- "$dest" || return 1
		fi

		state_log "assets: staging $name from $url"
		download_stage "$url" "$dest" "$hash" || {
			state_log "assets: failed to stage $name"
			return 1
		}
	done

	# Own verification gate: the runner writes the done marker only on 0.
	for i in "${!_ASSETS_NAMES[@]}"; do
		name=${_ASSETS_NAMES[$i]}
		hash=${_ASSETS_HASHES[$i]}
		dest="$ASSETS_DIR/$name"
		[ -f "$dest" ] && [ ! -L "$dest" ] || {
			state_log "assets: $dest is missing or a symlink"
			return 1
		}
		have=$(_assets_hash_of "$dest") || {
			state_log "assets: cannot hash $dest"
			return 1
		}
		[ "$have" = "$hash" ] || {
			state_log "assets: checksum mismatch for $dest"
			return 1
		}
	done

	state_log "assets: all ${#_ASSETS_NAMES[@]} assets staged and verified in $ASSETS_DIR"
	return 0
)
