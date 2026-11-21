#version=DEVEL
#
# gnome-devstation — Fedora Workstation, trimmed to a developer laptop
# ====================================================================
#
# Start from Fedora's own Workstation environment and subtract. Everything the
# GNOME session, GDM, portals, keyring, polkit, PipeWire and NetworkManager need
# comes from the environment group; what is removed is the application layer
# nobody on this machine uses. See README.md for the rationale and the measured
# package delta.
#
# No hardware tuning lives here on purpose: no kernel arguments, no sysctl
# files, no zram configuration, no VA-API driver pin, no shell replacement.
# Sleep, FBC/PSR, swap and the default power profile stay exactly as Fedora
# ships them.
#
# IMPORTANT — interactive GUI install by design
# ---------------------------------------------
# Partitioning, rootpw and user creation are deliberately NOT specified here.
# A "complete" kickstart makes Anaconda install unattended without ever showing
# its interface. Omitting those three keeps the graphical installer on screen
# with language, repos and packages pre-filled, and lets the user choose their
# own disk layout and password.
#
# Add `autopart`, `rootpw` and `user` only if you want an unattended install.

# --- Locale and time ------------------------------------------------------
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone UTC --utc

# --- Installer behaviour --------------------------------------------------
# Graphical installer. Never `text` or `cmdline` here.
graphical
firstboot --disable

# --- Security -------------------------------------------------------------
selinux --enforcing
firewall --enabled --service=mdns

# --- Repositories ---------------------------------------------------------
# Fedora's own repositories are inherited from the netinst ISO.
#
# $releasever and $basearch are substituted by Anaconda, so a Fedora release
# bump needs no edits here.
#
# Kickstart commands are line-based: no backslash continuations.
#
# No --gpgkey option exists for `repo`: Anaconda sets pkg_gpgcheck=False for
# installer repositories, so these entries are used unsigned at install time.
# The installed system gets signed repo files instead (see %post), plus an
# explicit `rpm --import` for both third-party keys.

repo --name="google-chrome" --baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64

repo --name="copr-helium" --baseurl=https://download.copr.fedorainfracloud.org/results/imput/helium/fedora-$releasever-$basearch/

repo --name="rpmfusion-free" --baseurl=https://download1.rpmfusion.org/free/fedora/releases/$releasever/Everything/$basearch/os/

repo --name="rpmfusion-free-updates" --baseurl=https://download1.rpmfusion.org/free/fedora/updates/$releasever/$basearch/

repo --name="rpmfusion-nonfree" --baseurl=https://download1.rpmfusion.org/nonfree/fedora/releases/$releasever/Everything/$basearch/os/

repo --name="rpmfusion-nonfree-updates" --baseurl=https://download1.rpmfusion.org/nonfree/fedora/updates/$releasever/$basearch/

# --- Packages -------------------------------------------------------------
# No --ignoremissing: a renamed or retired package must fail the build loudly
# instead of disappearing from the image without a trace.
#
# Negative entries are exclusions, not "just don't mention it". Fedora installs
# Recommends by default, so omitting `gnome-tour` from this file would still
# install it (gnome-shell recommends it). The exclusion list below mirrors every
# removal for that reason — and only for that reason. Nothing here is a
# post-install `dnf remove`, and nothing uses --excludeWeakdeps: a named
# exclusion cannot silently drop the recommends the desktop actually needs.
%packages

@^workstation-product-environment

# The kernel is listed, not implied.
#
# Anaconda only adds `kernel` to the transaction if it can resolve it from an
# enabled repository (get_kernel_package() in pyanaconda). When it cannot, it
# logs "No such package: kernel" and carries on installing without one. The
# online ISO never notices, because Fedora's own repos carry it. The offline
# ISO installs from its embedded package tree and nothing else, so a tree
# resolved from a kickstart that never mentions the kernel contains no kernel
# rpm at all -- and the resulting install cannot boot. Listing it here is what
# puts the kernel into that tree.
kernel

# --- Groups removed -------------------------------------------------------
-@libreoffice
-@firefox
-@printing
-@guest-desktop-agents
-@domain-client

# --- GNOME applications removed -------------------------------------------
# The desktop core stays; these are the apps that duplicate a CLI tool, a
# Flatpak, or nothing at all on this machine.
-gnome-software
-gnome-boxes
-gnome-remote-desktop
-gnome-connections
-gnome-maps
-gnome-weather
-decibels
-gnome-contacts
-showtime
-snapshot
-simple-scan
-gnome-clocks
-gnome-characters
-gnome-calendar
-gnome-calculator
-baobab
-gnome-logs
-gnome-system-monitor
-gnome-font-viewer
-gnome-color-manager
-seahorse
-gnome-disk-utility
-gnome-user-docs
-yelp
-sane-backends-drivers-scanners
-libsane-hpaio

# Weak dependencies that would otherwise walk straight back in.
# gnome-shell recommends gnome-tour; gnome-control-center recommends
# gnome-color-manager, gnome-remote-desktop, rygel and malcontent-control.
# Those apps are listed above because the Recommends would reinstall them.
-gnome-tour
-malcontent-control
-rygel

# evolution-data-server deliberately stays. gnome-shell links libecal and
# libedataserver directly, so removing it is not an app trim — it makes the
# whole desktop unresolvable. gnome-calendar and gnome-contacts still go; the
# library they used just remains.

# Extension management is the Extension Manager Flatpak, not the GNOME tools.
-gnome-extensions-app
-gnome-tweaks
-dconf-editor

# --- Workstation extras not used on this machine --------------------------
-mediawriter
-unoconv
-gamemode
-toolbox

# --- Firmware and hardware enablement -------------------------------
#
# Catch-all, not Intel-only. This image is built to boot on whatever it lands
# on, so every vendor's firmware ships. The EliteBook 840 G3 that started this
# project uses the Intel row of this table; a different machine uses a
# different row and nothing else changes.
#
# linux-firmware itself stays regardless: it carries the wireless regulatory
# database the kernel reads at boot, and it is a dependency of the vendor
# packages below, so it is never an extra.
linux-firmware
wireless-regdb
alsa-ucm
alsa-sof-firmware
intel-audio-firmware
cirrus-audio-firmware
amd-gpu-firmware
amd-ucode-firmware
intel-gpu-firmware
nvidia-gpu-firmware
atheros-firmware
brcmfmac-firmware
iwlwifi-dvm-firmware
iwlwifi-mvm-firmware
iwlbluetooth-firmware
realtek-firmware
mt7xxx-firmware
nxpwireless-firmware
qcom-wwan-firmware
tiwilink-firmware
libertas-firmware
iwlegacy-firmware
intel-vsc-firmware
microcode_ctl

# --- Content the environment group does not provide -----------------------

# Session glue lost with the removed groups
# @firefox was the only group member pulling libglvnd-gles; GLES-only apps
# break without it, so it comes back explicitly.
libglvnd-gles

# Shell extensions: packaged by Fedora, enabled through system dconf in %post.
gnome-shell-extension-caffeine
gnome-shell-extension-appindicator

# --- Optional hardware, not in the default set ---------------------
#
# kernel-modules-extra is a separate package from kernel-modules: it is the
# long tail of sensors, old radios, niche card readers and other devices that
# the main module set does not carry. Fedora's Workstation does not install it;
# a catch-all image does, at ~3 MB.
kernel-modules-extra

# --- NVIDIA driver -------------------------------------------------
#
# RPM Fusion's akmod-nvidia builds the kernel module at install time and
# rebuilds it on every kernel update, so it needs the build toolchain and the
# matching kernel-devel in the same transaction. That is why gcc, make,
# kernel-headers and glibc-devel are listed rather than implied: on an offline
# ISO there is no second dnf pass to fetch them, and a missing build dep fails
# the install instead of shipping a broken driver. kernel-devel pins the
# exact kernel version the tree contains, so the module always matches.
akmod-nvidia
kernel-devel
gcc
make
kernel-headers
glibc-devel

# --- Video decode and the non-free codec stack -----------------------
#
# The freeworld packages are additive on Fedora 45, not replacements: verified
# with repoquery, they declare no Conflicts and share no plugin files with
# their -free counterparts. libheif-freeworld only ships the HEVC/AV1/x264/x265
# codec plugins, so Fedora's libheif stays installed and glycin keeps working.
#
# ffmpeg is listed here, not swapped in after the install. Resolution testing
# showed RPM Fusion's ffmpeg-libs satisfies every libavcodec/libavformat
# requirement in the transaction, so ffmpeg-free is never selected and the
# whole set resolves in one pass. That is what makes an offline install
# possible: no post-install dnf transaction needs a repository.
libva-intel-driver
libva-intel-media-driver
libva-utils
mesa-va-drivers-freeworld
mesa-dri-drivers
mesa-vulkan-drivers
vulkan-tools
ffmpeg
vlc
vlc-plugins-freeworld
gstreamer1-plugins-bad-freeworld
gstreamer1-plugins-ugly
gstreamer1-plugins-ugly-free
gstreamer1-plugin-libav
libheif-freeworld
unrar

# Firmware updates (HP publishes EliteBook BIOS images to LVFS)
fwupd
gnome-firmware

# System
dnf5-plugin-automatic
flatpak

# Browser — Chrome. Helium's COPR is configured but Helium itself is not
# installed; `sudo dnf install helium-bin` is one command away. See README.md.
google-chrome-stable

# Developer toolchain
git
gh
just
gitui
ripgrep
fd-find
bat
eza
fzf
zoxide
direnv
jq
yq
tmux
# gcc and make ship via the NVIDIA toolchain block above (same transaction)
pkgconf
python3
python3-pip
python3-devel
nodejs24
podman
podman-compose
shellcheck
btop
strace
lsof
7zip

# Small quality-of-life additions
wl-clipboard
sshfs
git-lfs
ncdu
poppler-utils
duf

# AppImage support.
#
# AppImage runtimes differ. The classic one dlopens libfuse.so.2 and fails with
# "dlopen(): error loading libfuse.so.2" when it is missing; newer ones can use
# libfuse3 (Fedora ships that) or bundle FUSE statically. Only the classic one
# needs anything from us, and it is still the most common one in the wild.
#
# Both packages are required, and that is not obvious: `fuse` needs only
# `fuse-common`, not `fuse-libs`, so it installs `fusermount` and leaves the
# library out. The classic runtime needs both. Neither conflicts with fuse3.
#
# It also covers AppImages launched from Gear Lever: that Flatpak talks to
# org.freedesktop.Flatpak so the AppImage runs on the host, not inside the
# sandbox, and therefore needs this same library.
fuse
fuse-libs

%end

# --- Install files shipped on the ISO -------------------------------------
# Runs outside the chroot, so it only copies files. The ISO is mounted at
# /run/install/repo; the installed root is $ANA_INSTALL_PATH.

%post --nochroot --erroronfail --log=/root/ks-post-nochroot.log
set -euxo pipefail

root="${ANA_INSTALL_PATH:-/mnt/sysimage}"
src=/run/install/repo/files

# Bash quality-of-life, loaded by /etc/profile (login) and /etc/bashrc
# (interactive), guarded against double sourcing inside the file itself.
install -Dm0644 "$src/90-devstation.sh" "$root/etc/profile.d/90-devstation.sh"

# System dconf database: pre-enables Caffeine and the appindicator extension
# before the first login, when no user database exists yet.
install -Dm0644 "$src/dconf-profile-user" "$root/etc/dconf/profile/user"
install -Dm0644 "$src/dconf-00-devstation" "$root/etc/dconf/db/local.d/00-devstation"

# Third-party repository definitions for the installed system.
install -Dm0644 /run/install/repo/repos/google-chrome.repo "$root/etc/yum.repos.d/google-chrome.repo"
install -Dm0644 /run/install/repo/repos/helium-copr.repo "$root/etc/yum.repos.d/helium-copr.repo"

# Assets fetched at build time (see build.sh): RPM Fusion's release packages and
# the third-party signing keys. They are copied into the installed system here
# because the ISO mount is not guaranteed to be visible inside the chrooted
# %post, and because the install must work with the network unplugged.
assets=/run/install/repo/assets
for f in rpmfusion-free-release.noarch.rpm rpmfusion-nonfree-release.noarch.rpm \
         google-chrome.asc helium-copr.asc; do
  install -Dm0644 "$assets/$f" "$root/var/tmp/ks-assets/$f"
done

# The verification gate runs from the chrooted %post below, which cannot
# rely on the ISO mount staying visible inside the installed root.
install -Dm0755 "$src/verify-devstation.sh" "$root/var/tmp/ks-assets/verify-devstation.sh"

# Marker written by `build.sh offline`. The chrooted %post uses it to skip the
# steps that can only work with a network.
if [ -e /run/install/repo/offline ]; then
  install -Dm0644 /run/install/repo/offline "$root/var/tmp/ks-assets/offline"
fi

%end

# --- System configuration -------------------------------------------------
# Runs inside the installed system, so rpm/dnf/systemctl/dconf work.

%post --erroronfail --log=/root/ks-post.log
set -euxo pipefail

# 0. Is this the offline ISO? build.sh marks it, and the only steps that need a
#    network (Flathub) are skipped instead of timing out.
offline=0
if [ -e /var/tmp/ks-assets/offline ]; then
  offline=1
fi

# 1. Persist RPM Fusion for the installed system.
#    The `repo` lines above only configure the installer, and Anaconda writes
#    them into /etc/yum.repos.d as a side effect. Drop those generated files
#    first: the release packages ship the maintained, signed versions, and
#    keeping both would duplicate sections.
#
#    The release packages come from the ISO (copied by %post --nochroot), and
#    `rpm -Uvh` is deliberate: their only dependencies are already installed,
#    so this needs no repository metadata and works with no network. `dnf
#    install` here would make the offline install depend on a reachable mirror.
#    --nosignature is the chicken-and-egg: the key that signs these packages
#    ships inside them. They arrive over HTTPS from RPM Fusion's own mirror,
#    and their only content is repository definitions and that key.
rm -f /etc/yum.repos.d/rpmfusion-free.repo \
      /etc/yum.repos.d/rpmfusion-free-updates.repo \
      /etc/yum.repos.d/rpmfusion-nonfree.repo \
      /etc/yum.repos.d/rpmfusion-nonfree-updates.repo \
      /etc/yum.repos.d/ks-offline.repo

rpm -Uvh --nosignature /var/tmp/ks-assets/rpmfusion-free-release.noarch.rpm \
         /var/tmp/ks-assets/rpmfusion-nonfree-release.noarch.rpm

# 2. Trust the two third-party signing keys now, so the first `dnf upgrade`
#    does not stop for a prompt. The repo files themselves are shipped on the
#    ISO and already point at these keys; the copies here are what makes the
#    import work offline.
rpm --import /var/tmp/ks-assets/google-chrome.asc
rpm --import /var/tmp/ks-assets/helium-copr.asc

# 3. Graphical boot with GDM.
systemctl set-default graphical.target
systemctl enable gdm.service

# 4. Compile the system dconf database. Fedora's user profile stack is
#    user-db:user + system-db:local, so the keys below apply until the user
#    changes something through the usual GNOME UI.
dconf update

# 5. Chrome as the default browser. Written as a system-wide XDG default
#    because xdg-settings needs a live user session. Helium's repository stays
#    enabled so it can be installed later without editing anything.
cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
x-scheme-handler/about=google-chrome.desktop
text/html=google-chrome.desktop
application/xhtml+xml=google-chrome.desktop
EOF

# 6. Flathub plus the three Flatpaks this image standardises on. Both steps need
#    network and a usable /var inside the chroot; warn instead of failing an
#    otherwise good install if the network drops here.
if [ "$offline" -eq 1 ]; then
  echo "offline ISO: skipping Flathub; install Flatseal, Extension Manager and Gear Lever after first boot" >&2
else
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo || \
    echo "WARNING: could not add the flathub remote" >&2
  for app in com.github.tchx84.Flatseal com.mattjakeman.ExtensionManager \
             it.mijorus.gearlever; do
    flatpak install -y --system flathub "$app" || \
      echo "WARNING: $app not preinstalled; run 'flatpak install flathub $app' after first boot" >&2
  done
fi

# 7. Security updates in the background. GNOME Software is not part of this
#    image, so the update path is dnf5's own timer.
if [ -f /etc/dnf/automatic.conf ]; then
  sed -i -e 's/^apply_updates = no/apply_updates = yes/' \
         -e 's/^upgrade_type = default/upgrade_type = security/' /etc/dnf/automatic.conf || true
fi
if [ -f /usr/lib/systemd/system/dnf5-automatic.timer ]; then
  systemctl enable dnf5-automatic.timer
elif [ -f /usr/lib/systemd/system/dnf-automatic.timer ]; then
  systemctl enable dnf-automatic.timer
fi

# 8. Verification gate. Every check below is a claim made in README.md, so a
#    silent regression fails the install instead of shipping a broken image.
#    The gate lives in files/verify-devstation.sh so the converter
#    (migrate/steps/90-verify.sh) runs the same checks.
bash /var/tmp/ks-assets/verify-devstation.sh

# 9. Hardware decode: report, never fail. VMs have no VA-API device, and this
#    kickstart must stay installable there.
if ! vainfo 2>/dev/null | grep -q 'VAProfileH264High'; then
  echo "WARNING: vainfo reports no H264 profile (expected in a VM); check 'vainfo' after first boot" >&2
fi

# 10. The build assets have been consumed. Leaving them behind would put RPM
#     Fusion's release files and the third-party keys in /var/tmp forever.
rm -rf /var/tmp/ks-assets

%end

# --- Reboot ---------------------------------------------------------------
reboot
