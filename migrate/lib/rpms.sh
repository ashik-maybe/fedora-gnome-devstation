# Staged RPM tree + local dnf repo (segment 20-rpms).
#
# rpms_stage asks dnf to resolve the kickstart's add list into $RPMS_DIR,
# verifies every staged rpm with `rpm -K --nosignature`, deletes and
# re-downloads individually bad ones, then runs `createrepo_c` so the tree
# is a usable local repo. rpms_dnf_arg prints the `--repofrompath` argument
# that makes dnf use it.

# Guard against double sourcing.
if [ "${_LIB_RPMS_LOADED:-0}" = 1 ]; then
	return 0
fi
_LIB_RPMS_LOADED=1

# Environment defaults from migrate/CONTRACT.md.
: "${STATE_DIR:=/var/lib/gnome-devstation-migrate}"
: "${RPMS_DIR:=$STATE_DIR/rpms}"

rpms_dnf_arg() {
	printf '%s\n' "--repofrompath=migrate,file://${RPMS_DIR:-$STATE_DIR/rpms}"
}

rpms_stage() {
	local add_list_file

	if [ $# -ne 1 ]; then
		echo "rpms_stage: usage: rpms_stage <add_list_file>" >&2
		return 1
	fi
	add_list_file="$1"
	if [ ! -f "$add_list_file" ]; then
		echo "rpms_stage: add list not found: $add_list_file" >&2
		return 1
	fi

	local -a packages=()
	local pkg
	while IFS= read -r pkg || [ -n "$pkg" ]; do
		[ -n "$pkg" ] || continue
		packages+=("$pkg")
	done <"$add_list_file"

	command -v dnf >/dev/null 2>&1 || {
		echo "rpms_stage: 'dnf' is not installed or not in PATH" >&2
		return 1
	}
	command -v rpm >/dev/null 2>&1 || {
		echo "rpms_stage: 'rpm' is not installed or not in PATH" >&2
		return 1
	}
	command -v createrepo_c >/dev/null 2>&1 || {
		echo "rpms_stage: 'createrepo_c' is not installed or not in PATH" >&2
		return 1
	}

	mkdir -p "$RPMS_DIR"

	# The initial bulk download must succeed: never index a partial result.
	dnf -y download --resolve --destdir "$RPMS_DIR" "${packages[@]}" || {
		echo "rpms_stage: initial dnf download failed" >&2
		return 1
	}

	# Associate every staged file with the requested package name that
	# produced it. Prefer the rpm NAME header; when the header is unreadable
	# (a corrupt HEADER breaks `rpm -qp` too) fall back to the file-name
	# prefix. This keeps the original requested name available for refetch
	# instead of a NEVRA taken from the file name.
	local -A name_to_file file_to_name
	build_file_map() {
		local f base req header_name mapped
		name_to_file=()
		file_to_name=()
		for f in "$RPMS_DIR"/*.rpm; do
			[ -e "$f" ] || continue
			mapped=""
			header_name="$(rpm -qp --nosignature --qf '%{NAME}\n' "$f" 2>/dev/null || true)"
			if [ -n "$header_name" ]; then
				for req in "${packages[@]}"; do
					if [ "$header_name" = "$req" ]; then
						mapped="$req"
						break
					fi
				done
			fi
			if [ -z "$mapped" ]; then
				base="$(basename "$f" .rpm)"
				for req in "${packages[@]}"; do
					if [ "$base" = "$req" ] || [ "${base#"$req"-}" != "$base" ]; then
						mapped="$req"
						break
					fi
				done
			fi
			if [ -n "$mapped" ]; then
				file_to_name["$f"]="$mapped"
				name_to_file["$mapped"]="$f"
			fi
		done
	}

	# Verify every staged file. A bad one is deleted and re-downloaded using
	# the original requested package name (never a NEVRA from its file name);
	# if it still fails after refetches the repo is broken: stop instead of
	# indexing files we could not verify.
	local round bad_file req name
	for round in 1 2 3; do
		build_file_map
		local -a bad_files=()
		for bad_file in "$RPMS_DIR"/*.rpm; do
			[ -e "$bad_file" ] || continue
			if ! rpm -K --nosignature "$bad_file" >/dev/null 2>&1; then
				bad_files+=("$bad_file")
			fi
		done
		if [ ${#bad_files[@]} -eq 0 ]; then
			break
		fi
		if [ "$round" -ge 3 ]; then
			echo "rpms_stage: rpm verification still failing after refetch: ${bad_files[*]}" >&2
			return 1
		fi
		for bad_file in "${bad_files[@]}"; do
			name="${file_to_name[$bad_file]:-}"
			if [ -z "$name" ]; then
				name="$(rpm -qp --nosignature --qf '%{NAME}\n' "$bad_file" 2>/dev/null || true)"
				[ -n "$name" ] || name="$(basename "$bad_file" .rpm)"
			fi
			local nevra
			nevra="$(rpm -qp --nosignature --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$bad_file" 2>/dev/null || true)"
			[ -n "$nevra" ] || nevra="$(basename "$bad_file" .rpm)"
			echo "rpms_stage: '$name' failed rpm -K; deleting and re-downloading it alone" >&2
			local -A before_refetch=()
			local existing
			for existing in "$RPMS_DIR"/*.rpm; do
				[ -e "$existing" ] || continue
				before_refetch["$(basename "$existing")"]=1
			done
			rm -f -- "$bad_file"
			# Refetch the exact original NEVRA without --resolve so we do not
			# pull dependencies or a different version into the staged tree.
			dnf -y download --destdir "$RPMS_DIR" "$nevra" || {
				echo "rpms_stage: refetch of '$nevra' failed" >&2
				return 1
			}
			# Remove any unexpected files pulled in by the refetch; keep only
			# what was there before plus the requested NEVRA.
			for existing in "$RPMS_DIR"/*.rpm; do
				[ -e "$existing" ] || continue
				local base_existing
				base_existing="$(basename "$existing")"
				if [ -z "${before_refetch[$base_existing]:-}" ] && [ "$base_existing" != "${nevra}.rpm" ]; then
					echo "rpms_stage: removing unexpected refetch artifact '$base_existing'" >&2
					rm -f -- "$existing"
				fi
			done
		done
	done

	# Dedupe by package name: never index a conflicting second version.
	build_file_map
	local -A seen_name_file
	local dedupe_file dedupe_name dedupe_keep
	for dedupe_file in "$RPMS_DIR"/*.rpm; do
		[ -e "$dedupe_file" ] || continue
		dedupe_name="$(rpm -qp --nosignature --qf '%{NAME}\n' "$dedupe_file" 2>/dev/null || true)"
		[ -n "$dedupe_name" ] || dedupe_name="$(basename "$dedupe_file" .rpm)"
		dedupe_keep="${seen_name_file[$dedupe_name]:-}"
		if [ -z "$dedupe_keep" ]; then
			seen_name_file["$dedupe_name"]="$dedupe_file"
			continue
		fi
		# Prefer the file already mapped to a requested package; otherwise keep
		# the already-seen file and drop this duplicate.
		if [ -n "${file_to_name[$dedupe_keep]:-}" ] && [ -z "${file_to_name[$dedupe_file]:-}" ]; then
			echo "rpms_stage: removing duplicate package '$dedupe_name': $(basename "$dedupe_file")" >&2
			rm -f -- "$dedupe_file"
		elif [ -z "${file_to_name[$dedupe_keep]:-}" ] && [ -n "${file_to_name[$dedupe_file]:-}" ]; then
			echo "rpms_stage: removing duplicate package '$dedupe_name': $(basename "$dedupe_keep")" >&2
			rm -f -- "$dedupe_keep"
			seen_name_file["$dedupe_name"]="$dedupe_file"
		else
			echo "rpms_stage: removing duplicate package '$dedupe_name': $(basename "$dedupe_file")" >&2
			rm -f -- "$dedupe_file"
		fi
	done

	# Completeness: every requested package must have a staged rpm before we
	# index the tree. This guards against a dnf download that returned 0 but
	# only staged part of the add list.
	build_file_map
	for req in "${packages[@]}"; do
		if [ -z "${name_to_file[$req]:-}" ] || [ ! -f "${name_to_file[$req]}" ]; then
			echo "rpms_stage: no staged rpm for requested package '$req'" >&2
			return 1
		fi
	done

	createrepo_c --quiet "$RPMS_DIR" || {
		echo "rpms_stage: createrepo_c failed" >&2
		return 1
	}
}
