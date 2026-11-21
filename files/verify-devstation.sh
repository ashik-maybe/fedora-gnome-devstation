#!/usr/bin/env bash
# Verification gate for the devstation image.
#
# Every check below is a claim made in README.md, so a silent regression fails
# the install instead of shipping a broken image.
#
# Shared between the ISO build's chrooted %post (kickstart/gnome-devstation.ks,
# section 8) and the converter (migrate/steps/90-verify.sh): both run it against
# the installed system with ROOT=/, so one gate proves both paths.
#
# ROOT: target root for the path checks. Paths are prefixed with it so tests
# can point the script at a temp tree. rpm, ldconfig and dconf have no read-only
# root mode without chroot, so they stay live; both callers run with ROOT=/,
# which makes live == target.

set -euo pipefail

root="${ROOT:-/}"
root="${root%/}" # "/" -> "" so "$root/..." stays absolute

fail=0

for pkg in gnome-shell gdm gnome-shell-extension-caffeine \
	gnome-shell-extension-appindicator google-chrome-stable \
	libva-intel-media-driver iwlwifi-mvm-firmware bash tuned-ppd \
	ffmpeg fuse rpmfusion-free-release rpmfusion-nonfree-release \
	kernel akmod-nvidia kernel-devel gcc make kernel-headers glibc-devel \
	kernel-modules-extra mesa-va-drivers-freeworld fwupd gnome-firmware; do
	if ! rpm -q "$pkg" >/dev/null 2>&1; then
		echo "MISSING REQUIRED PACKAGE: $pkg" >&2
		fail=1
	fi
done

# The trims must be gone. A package that quietly came back through a weak
# dependency is exactly the failure this list exists to catch.
for pkg in firefox libreoffice-writer gnome-boxes gnome-software gnome-tour \
	gnome-maps gnome-weather rygel gnome-remote-desktop \
	helium-bin helix; do
	if rpm -q "$pkg" >/dev/null 2>&1; then
		echo "PRESENT BUT SHOULD BE TRIMMED: $pkg" >&2
		fail=1
	fi
done

# The AppImage runtime dlopens this exact soname, so check the library rather
# than trusting the package name. Both paths exist because the package ships
# one copy for each prefix.
if ! ldconfig -p | grep -q 'libfuse\.so\.2'; then
	echo "MISSING LIBFUSE.SO.2: AppImages will not run" >&2
	fail=1
fi

# The extensions must actually be enabled for the first login, and the packaged
# metadata must know about the installed shell major version.
enabled="$(dconf read /org/gnome/shell/enabled-extensions || true)"
for uuid in caffeine@patapon.info appindicatorsupport@rgcjonas.gmail.com; do
	case "$enabled" in
	*"$uuid"*) ;;
	*)
		echo "EXTENSION NOT ENABLED IN DCONF: $uuid (got: $enabled)" >&2
		fail=1
		;;
	esac
done

shell_major=""
if command -v gnome-shell >/dev/null 2>&1; then
	shell_major="$(gnome-shell --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)" || true
fi
if [ -z "$shell_major" ]; then
	echo "GNOME-SHELL VERSION UNAVAILABLE: cannot verify extension metadata" >&2
	fail=1
else
	for uuid in caffeine@patapon.info appindicatorsupport@rgcjonas.gmail.com; do
		meta="$root/usr/share/gnome-shell/extensions/$uuid/metadata.json"
		if [ ! -f "$meta" ] || ! grep -q "\"$shell_major\"" "$meta"; then
			echo "EXTENSION DOES NOT DECLARE SHELL $shell_major: $uuid" >&2
			fail=1
		fi
	done
fi

# Exactly one Power Profiles provider: tuned-ppd in the Workstation environment,
# never tuned-ppd and power-profiles-daemon at the same time.
providers="$(rpm -qa --qf '%{NAME}\n' | grep -cxE 'tuned-ppd|power-profiles-daemon' || true)"
if [ "$providers" -ne 1 ]; then
	echo "EXPECTED EXACTLY ONE ppd-service PROVIDER, FOUND $providers" >&2
	fail=1
fi

# The browser default must point at a desktop file that exists.
if [ ! -f "$root/usr/share/applications/google-chrome.desktop" ]; then
	echo "MISSING google-chrome.desktop" >&2
	fail=1
fi
if ! grep -q '^x-scheme-handler/https=google-chrome.desktop' "$root/etc/xdg/mimeapps.list"; then
	echo "CHROME IS NOT THE DEFAULT BROWSER" >&2
	fail=1
fi

# The bash profile must be in place and syntactically valid.
if ! bash -n "$root/etc/profile.d/90-devstation.sh"; then
	echo "BASH PROFILE HAS A SYNTAX ERROR" >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1
