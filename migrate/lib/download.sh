# Resumable, checksummed asset staging.
#
# Standalone: sources nothing, only needs curl, sha256sum and mv. Sourced by
# steps; defines _LIB_DOWNLOAD_LOADED and the download_stage function.
# This library never changes shell options: sourcing it leaves the caller's
# `$-` and pipefail setting exactly as they were.

if [ "${_LIB_DOWNLOAD_LOADED:-0}" != 1 ]; then
	_LIB_DOWNLOAD_LOADED=1

	# _file_matches <file> <sha256>: 0 when <file> is a regular file (not a
	# symlink) and its digest equals <sha256>. Missing, unreadable or symlinked
	# files never match: a staged file is only usable when the sum was actually
	# checked on a real file in place.
	_file_matches() {
		[ -f "$1" ] && [ ! -L "$1" ] || return 1
		[ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]
	}

	# _fetch_full <url> <part> <dest> <sha256>: discard any existing part and
	# make exactly one full download (no -C -), verify it, then publish it.
	# On failure no part is left behind.
	_fetch_full() {
		local url="$1" part="$2" dest="$3" want="$4" got
		rm -f "$part"
		if ! curl -fL --retry 3 -o "$part" "$url"; then
			echo "download: failed to fetch $url (full download)" >&2
			return 1
		fi
		if _file_matches "$part" "$want"; then
			mv -f "$part" "$dest"
			echo "download: staged $dest"
			return 0
		fi
		got="$(sha256sum "$part" | awk '{print $1}')"
		rm -f "$part"
		echo "download: sha256 mismatch for $dest: expected $want, got $got" >&2
		return 1
	}

	# download_stage <url> <dest> <sha256>: fetch <url> into <dest>, verified
	# with <sha256> before it is published.
	#
	# The transfer resumes into <dest>.part (`curl -fL -C -`, bounded retries),
	# the sum is verified, then the part is renamed into place. A corrupt
	# <dest> is removed and replaced. If the resume fails (e.g. curl error 36
	# from an oversized/invalid part) or the resumed part fails verification,
	# the part is deleted and one full download without -C - is allowed, after
	# which the function fails loudly instead of looping forever.
	download_stage() {
		[ $# -eq 3 ] || {
			echo "download_stage: usage: download_stage <url> <dest> <sha256>" >&2
			return 1
		}
		local url="$1" dest="$2" want="$3"
		local part="$dest.part"

		# Already staged and verified: return immediately, nothing to do.
		if _file_matches "$dest" "$want"; then
			echo "download: $dest is already staged and verified"
			return 0
		fi

		# Never write through a symlink: remove a symlinked dest or part so a
		# planted link cannot redirect the download to another file.
		if [ -L "$dest" ]; then
			rm -f -- "$dest"
		fi
		if [ -L "$part" ]; then
			rm -f -- "$part"
		fi

		# A corrupt final file must be replaced, not reused. Only the stale
		# file is removed; a partial part next to it is kept for the resume.
		if [ -e "$dest" ] && [ ! -e "$part" ]; then
			rm -f -- "$dest"
		fi

		# The caller may not have created the destination directory.
		mkdir -p -- "$(dirname -- "$dest")" || {
			echo "download: cannot create directory for $dest" >&2
			return 1
		}

		# Attempt 1: resume whatever is already in the .part (or start fresh).
		if ! curl -fL -C - --retry 3 -o "$part" "$url"; then
			# A stale .part can be oversized or otherwise unresumable (curl
			# exits 36). Delete it and make one full download before failing.
			echo "download: resume failed for $url; retrying with a full download" >&2
			rm -f "$part"
			_fetch_full "$url" "$part" "$dest" "$want" || return 1
			return 0
		fi
		if _file_matches "$part" "$want"; then
			mv -f "$part" "$dest"
			echo "download: staged $dest"
			return 0
		fi

		# The transfer completed but the sum is wrong: the part may be
		# truncated or corrupt, so restart the whole download once, without
		# resuming, then fail loudly if that still does not verify.
		_fetch_full "$url" "$part" "$dest" "$want" || return 1
		return 0
	}
fi
