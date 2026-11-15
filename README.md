# gnome-devstation

A Fedora 45 GNOME desktop image for developers, built from the Fedora Everything
netinst with `mkksiso` and a kickstart. It ships the full GNOME session, the
media stack Fedora leaves out, a developer toolchain, and — as of this version —
every firmware package and driver Fedora offers, so it boots on whatever machine
it lands on.

No themes. No dotfiles. No kernel arguments. No custom `sysctl` files. If
upstream GNOME or Fedora changes a default, this image inherits the change
instead of fighting it.

---

## Contents

1. [What this is (and is not)](#what-this-is-and-is-not)
2. [What is in the image](#what-is-in-the-image)
3. [Hardware support](#hardware-support)
4. [What was removed](#what-was-removed)
5. [AppImage support](#appimage-support)
6. [Install](#install)
7. [First boot](#first-boot)
8. [Verification gates](#verification-gates)
9. [Building](#building)
10. [What an offline build actually does](#what-an-offline-build-actually-does)
11. [Project layout](#project-layout)
12. [Troubleshooting](#troubleshooting)
13. [License](#license)

## What this is (and is not)

It is the **Fedora Workstation environment group**, minus the applications
nobody uses on a development machine, plus a toolchain, RPM Fusion's codec
packages, and every firmware package.

It is **not** a minimal install and not a tuned image:

- The GNOME session, GDM, portals, keyring, polkit, PipeWire, NetworkManager,
  `localsearch` and `evolution-data-server` all stay. They are what makes the
  desktop work, and several are hard dependencies of `gnome-shell` itself.
- Sleep, FBC/PSR, zram, the default power profile, VA-API driver selection and
  the scheduler are exactly as Fedora ships them. There is no `grubby` call,
  no `/etc/environment.d` pin, no `zram-generator.conf`, no `%post` tuning.
- Bash stays the login shell. No zsh, no shell replacement.

The base is the **Fedora Everything netinst**, not the Workstation live ISO.
The online ISO installs from live repositories, so an ISO built in January
installs June's packages. The offline ISO embeds the resolved package set and
installs exactly that, which is the point of it.

## Measured size, not marketing size

Resolution tested with `dnf --installroot` against Fedora 45 x86_64, so it counts
what an install actually puts on the disk rather than what a development machine
is missing:

| | Stock `@workstation-product-environment` | This image |
| --- | --- | --- |
| Packages installed | 1855 | **1676** |
| Download | ~2 GiB | ~2 GiB |
| Installed size | ~6 GiB | ~6 GiB |

179 fewer packages, and the difference is entirely applications: the firmware,
kernel, toolchain and codec stack are all in. Helium, if you add it later, is
~415 MB plus a Qt5 stack that this image does not otherwise carry.

## What is in the image

### Session

Full GNOME 51 on Fedora 45: `gnome-shell`, `gdm`, `nautilus`, `ptyxis`,
`gnome-text-editor`, `papers`, `loupe`, `file-roller`, `gnome-initial-setup`,
`gnome-control-center`, `evolution-data-server` (hard dependency of
`gnome-shell`), and the whole `@desktop-accessibility` group.

Two extensions are preinstalled and enabled before the first login through a
system dconf database:

- `gnome-shell-extension-caffeine` (v61) — keeps the screen awake when you want
  it to. Enabled but **not inhibiting**: `restore-state=true` only remembers
  whether you turned it on. Suspend and blanking behave normally until you click
  the coffee cup.
- `gnome-shell-extension-appindicator` (v66) — puts Steam, Slack, Discord and
  Flatpak tray icons in the top bar.

Both are Fedora packages that declare shell 45–51. Nothing is locked: Extension
Manager shows them as system extensions, and your own `~/.config/dconf/user`
takes priority as soon as you toggle anything.

### Developer toolchain

`git` `gh` `just` `gitui` `ripgrep` `fd-find` `bat` `eza` `fzf` `zoxide`
`direnv` `jq` `yq` `tmux` `gcc` `make` `pkgconf` `python3` `python3-pip`
`python3-devel` `nodejs24` `podman` `podman-compose` `shellcheck` `btop`
`strace` `lsof` `7zip`

Quality of life: `wl-clipboard` `sshfs` `git-lfs` `ncdu` `poppler-utils` `duf`

Deliberately absent: C/C++ extras beyond `gcc`/`make`, Rust, Go, Java, database
servers, Kubernetes tooling. `uv` and everything else Python-related beyond
`pip`/`devel` is left to the user.

### Media and codecs

Full RPM Fusion stack, preinstalled:

`ffmpeg` · `vlc` · `vlc-plugins-freeworld` ·
`gstreamer1-plugins-bad-freeworld` · `gstreamer1-plugins-ugly` (H.264 encoder) ·
`gstreamer1-plugins-ugly-free` · `gstreamer1-plugin-libav` ·
`gstreamer1-plugin-openh264` · `gstreamer1-plugin-dav1d` ·
`libva-intel-driver` (i965) ·
`libva-intel-media-driver` (iHD) · `libva-utils` · `libheif-freeworld` ·
`mesa-va-drivers-freeworld` (AMD hardware decode) · `unrar`

`ffmpeg` is an ordinary `%packages` entry, not a post-install swap. RPM Fusion's
`ffmpeg-libs` satisfies every `libavcodec`/`libavformat` requirement in the
transaction, so `ffmpeg-free` is never selected and the whole set resolves in
one pass. That matters for more than tidiness: it is what lets the offline ISO
install without a reachable repository.

The GStreamer VA-API plugin needs no extra package: `libgstva.so` ships inside
`gstreamer1-plugins-bad-free`, which is why `gstreamer1-vaapi` only exists as a
virtual provide.

The `-freeworld` packages are **additive** on Fedora 45, not replacements:
verified with `repoquery`, they declare no `Conflicts` and share no plugin files
with their `-free` counterparts. `libheif-freeworld` only ships the
HEVC/AV1/x264/x265 codec plugins and pulls Fedora's `libheif` in as a hard
dependency.

`libdvdcss` is **not available** for Fedora 45 in RPM Fusion, so encrypted DVD
playback is impossible. Unencrypted DVD media still decodes through
`dvdread`/`dvdnav` in `ugly-free`.

### Browser

**Google Chrome** is installed and is the default handler for `http`, `https`,
`text/html` and `application/xhtml+xml`.

Helium's COPR is configured but Helium is not installed:

```bash
sudo dnf install helium-bin
```

Helium is Chromium-based without Google services, but it is beta, has no
Widevine (so no Netflix/Spotify web), and pulls a Qt5 stack that this image does
not otherwise install. Chrome is the safer default; the repo is there when you
want to try the other one.

### Firmware and drivers

This is the catch-all part. Every firmware package Fedora ships is installed,
so the image does not assume which hardware it lands on:

```
alsa-sof-firmware      intel-audio-firmware   cirrus-audio-firmware
amd-gpu-firmware       amd-ucode-firmware     intel-gpu-firmware
nvidia-gpu-firmware    atheros-firmware       brcmfmac-firmware
realtek-firmware       mt7xxx-firmware        nxpwireless-firmware
qcom-wwan-firmware     tiwilink-firmware      libertas-firmware
iwlegacy-firmware      iwlwifi-dvm-firmware   iwlwifi-mvm-firmware
iwlbluetooth-firmware  intel-vsc-firmware     linux-firmware
wireless-regdb
```

`linux-firmware` stays regardless: it carries the wireless regulatory database
the kernel reads at boot, and it is a dependency of the vendor packages above.

The NVIDIA driver is `akmod-nvidia` from RPM Fusion, which builds the kernel
module at install time and rebuilds on every kernel update. Because an offline
ISO has no second dnf pass, the build toolchain is listed explicitly in the same
transaction: `kernel-devel` (pinned to the kernel version the tree contains),
`gcc`, `make`, `kernel-headers`, `glibc-devel`. A missing build dep would fail
the install loudly instead of shipping a broken driver.

`kernel-modules-extra` is also installed: it is the long tail of sensors, old
radios, niche card readers and other devices the main module set does not carry,
at ~3 MB.

`fwupd` and `gnome-firmware` are included: HP publishes EliteBook BIOS images to
LVFS, so firmware updates work without a Windows dual boot.

`kernel` is listed explicitly, not implied. Anaconda adds a kernel by itself only
when it can resolve one from an enabled repository; when it cannot, it logs
`Failed to select a kernel` and carries on installing. An online install never
notices, because Fedora's repos have one. An offline install has only the
embedded tree, so the kernel is in the tree because the kickstart asked for it —
and `%post` gates on `kernel` being installed, so a regression fails the install
instead of shipping an ISO that cannot boot.

### Bash, improved without a framework

One file, `/etc/profile.d/90-devstation.sh`, sourced by both `/etc/profile`
(login shells) and `/etc/bashrc` (interactive shells), with a guard so it loads
once:

- history: 100k entries, shared between windows, appended live, duplicates
  collapsed
- `globstar` (`**`), `direxpand`, `checkwinsize`; `autocd` deliberately off
- case-insensitive completion, complete on the first Tab
- fzf: `Ctrl-R` history, `Ctrl-T` file picker, `Alt-C` directory jump
- `zoxide` (`z`, `zi`) and `direnv`
- prompt: user@host, trimmed path, git branch, last exit status on failure

`EDITOR`/`VISUAL` are **not** set, and no editor beyond `vi` (from `@core`) and
`nano` (the distro default editor) is shipped. Set them yourself if you install
one.

### Flatpaks

Preinstalled from Flathub on the online ISO:

- **Flatseal** — review and change permissions for every Flatpak.
- **Extension Manager** — the only GNOME extension manager worth using; replaces
  `gnome-extensions-app`, `gnome-tweaks` and `dconf-editor`.
- **Gear Lever** — AppImage browser and integrator. It talks to
  `org.freedesktop.Flatpak` so the AppImage runs on the host, not inside the
  sandbox, which is why `fuse` is a package here and not a side effect of the
  Flatpak.

## Hardware support

The image is hardware-agnostic. It was originally written for an **HP EliteBook
840 G3** (Skylake i5-6300U, Intel HD 520, Intel 8260 Wi-Fi/Bluetooth, Intel HDA
audio), and that machine was scanned end to end to prove nothing is missing:

| Component | Driver / module | Ships in | Blob it loads |
| --- | --- | --- | --- |
| HD Graphics 520 | `i915` | `kernel-modules` | `i915/skl_dmc_ver1_27.bin` — `intel-gpu-firmware` |
| Wi-Fi 8260 (iwlmvm) | `iwlwifi`, `iwlmvm` | `kernel-modules` | `iwlwifi-8000C-36.ucode` — `iwlwifi-mvm-firmware` |
| Bluetooth 8087:0a2b | `btusb` | `kernel-modules` | `intel/ibt-11-5.sfi`, `.ddc` — `iwlbluetooth-firmware` |
| Audio (HDA, CX20724) | `snd_hda_intel`, `snd_hda_codec_conexant` | `kernel-modules` | none — legacy HDA uses the kernel mixer, not UCM |
| Ethernet I219-LM | `e1000e` | `kernel-modules-core` | — |
| Card reader RTS522A | `rtsx_pci` | `kernel-modules-core` | — |
| Webcam (Chicony) | `uvcvideo` | `kernel-modules` | — |
| Touchpad (Synaptics PS/2) | `psmouse` | built into the kernel | — |
| Accelerometer LIS3LV02DL | `hp_accel`, `hp_wmi` | `kernel-modules` | — |
| Thermal, RAPL, MEI | `intel_pch_thermal`, `coretemp`, `intel_rapl_msr`, `mei_me` | `kernel-modules-core` | — |
| CPU microcode | — | `microcode_ctl` | `intel-ucode/06-4e-03` (Skylake-U) |

Ownership was verified against which Fedora package ships each blob (not against
a host that happens to have everything installed), and against the running
system for the driver side: every PCI device on the board has a driver bound,
and the kernel log records no failed firmware load. Two things the scan settled:

- **Audio is legacy HDA on the 840 G3, not SOF.** `snd_intel_dspcfg` sits at
  `dsp_driver=0` (auto), the board exposes no SOF ACPI node, and
  `snd_hda_intel` binds the CX20724 codec with HP's own `103c:8079` fixup.
  PipeWire reports no `api.alsa.ucm` property, so this card takes the plain
  kernel-mixer path. `alsa-sof-firmware` is installed anyway now — it costs
  14 MB and the image is no longer Intel-only.
- **`kernel-modules-extra` is not needed for this laptop.** Every module above
  lives in `kernel-modules` or `kernel-modules-core`, both of which come with
  `kernel`. It is installed for other hardware.

On any other machine: the firmware table above covers AMD, NVIDIA (nouveau),
Broadcom, Realtek, MediaTek, Qualcomm, Atheros, old Intel wireless, Cirrus
audio, and Intel VSC. If something is still missing, it is not a Fedora package.

## What was removed

Group level:

```
@libreoffice  @firefox  @printing  @guest-desktop-agents  @domain-client
```

Applications:

`gnome-software` · `gnome-boxes` · `gnome-remote-desktop` · `gnome-connections` ·
`gnome-maps` · `gnome-weather` · `decibels` · `gnome-contacts` · `showtime` ·
`snapshot` · `simple-scan` · `gnome-clocks` · `gnome-characters` ·
`gnome-calendar` · `gnome-calculator` · `baobab` · `gnome-logs` ·
`gnome-system-monitor` · `gnome-font-viewer` · `gnome-color-manager` ·
`seahorse` · `gnome-disk-utility` · `yelp` · `gnome-user-docs` ·
`gnome-extensions-app` · `gnome-tweaks` · `dconf-editor` · `mediawriter` ·
`unoconv` · `gamemode` · `toolbox`

Replaced by tools that are already in the image or one command away:

| Removed | Replacement |
| --- | --- |
| `baobab` | `ncdu`, `duf`, `compsize` |
| `gnome-logs` | `journalctl` |
| `gnome-system-monitor` | `btop` |
| `gnome-font-viewer` | `fc-list`, `fc-match` |
| `gnome-calculator` | `bc`, python |
| `seahorse` | `ssh-keygen`, `gpg` |
| `gnome-disk-utility` | `lsblk`, `udisksctl`, `dd` |
| `gnome-extensions-app`, `gnome-tweaks`, `dconf-editor` | Extension Manager Flatpak |
| GNOME Software | `dnf`, Flatpak CLI, `gnome-firmware` for LVFS |
| `gnome-tour`, Maps, Weather, Music, Video, Camera, Clocks, Characters, Help | — |

Kept on purpose: `nautilus`, `ptyxis`, `gnome-text-editor`, `papers`, `loupe`,
`file-roller`, `gnome-initial-setup`, and the whole `@desktop-accessibility`
group.

`papers` and `loupe` stay because they are the only native PDF and image
viewers in the image; `gnome-initial-setup` stays as a safety net, because GDM
will not show root and an install that somehow ended without a regular user
would otherwise be a dead end.

### Why there is an exclusion list

Fedora installs `Recommends` by default. Omitting an app from `%packages` is not
enough to keep it out:

- `gnome-shell` recommends `gnome-tour`
- `gnome-control-center` recommends `gnome-color-manager`,
  `gnome-remote-desktop`, `rygel` and `malcontent-control`

So every removal is mirrored as a `-package` line, which becomes a dnf exclude.
That is the only mechanism used. There is no post-install `dnf remove`, no
`--nodeps`, and **no `--excludeWeakdeps`** — that switch would drop the
recommends the desktop needs (firmware, portals, Bluetooth) to save a few apps.

The one removal that had to be reverted is documented in the kickstart:
`gnome-shell` links `libecal` and `libedataserver` directly, so
`evolution-data-server` is a hard dependency, not a calendar app. It stays.

## AppImage support

`fuse` + `fuse-libs`. A classic-runtime AppImage `dlopen`s `libfuse.so.2` and
execs `fusermount`, and Fedora ships neither, so it fails with
`dlopen(): error loading libfuse.so.2` — which reads like a corrupt download.
Newer runtimes use libfuse3 (already present) or bundle FUSE statically, so this
covers the ones that would otherwise break. Two packages, not one: `fuse`
requires only `fuse-common`, so it brings the helper and not the library.

If a machine has no `/dev/fuse` at all (some containers, some kernels), the
runtime's own escape hatch still works: `./whatever.AppImage
--appimage-extract-and-run`.

## Install

Two ISOs come out of this repository. They install the same system; they differ
only in where the packages come from.

| ISO | Size | Install needs network | Built by |
| --- | --- | --- | --- |
| `…-45-x86_64.iso` | ~1.3 GB | yes | `./build.sh online` |
| `…-45-x86_64-offline.iso` | ~2.9 GB | **no** | `./build.sh offline` |

Both fit a 4 GB USB stick.

**Requirements:** x86_64 machine, a USB stick of at least 4 GB, and — for the
online ISO only — wired or wireless network during install.

1. Write the ISO to USB:
   ```bash
   sudo dd if=out/gnome-devstation-45-x86_64-offline.iso of=/dev/sdX \
     bs=4M status=progress oflag=sync
   ```
2. Boot it. The Fedora graphical installer starts with this kickstart applied.
3. **Language / keyboard** — as usual.
4. **Installation source** — already configured. The offline ISO points at a
   package repository embedded in the ISO itself.
5. **Software selection** — pre-filled and locked. This is the image.
6. **Installation destination** — your disk, your partitioning, your encryption.
7. **User creation** — your name and password.
8. **Begin installation**.

Partitioning, `rootpw` and user creation are deliberately not in the kickstart.
If they were, Anaconda would install unattended and you would never see the GUI.
Leaving them out is what keeps the installer interactive.

### What "offline" does and does not cover

The offline ISO embeds the resolved RPM closure (~2 GB) as a `createrepo_c`
repository, and the generated kickstart installs from
`file:///run/install/repo/packages`. No mirror is contacted at any point: the
RPM Fusion release packages and the Chrome signing key are shipped on the ISO
too, so `%post` does not download anything either.

Two things still need a network, and the build says so out loud:

- **Flatpaks** (Flatseal, Extension Manager, Gear Lever) are skipped during an
  offline install, with a warning. Install them after first boot with
  `flatpak install flathub …` once you are online; the Flathub remote is only
  added by the online ISO.
- **Updates** obviously need one. Immediately after an offline install your
  system is the package set that was current when the ISO was built.

Everything else — the desktop, the codecs, the browser, the AppImage runtime,
the toolchain, the firmware — is on the ISO.

## First boot

```bash
# The two extensions should already be on
gnome-extensions list --enabled

# Hardware decode: expect H264/HEVC/VP9 profiles on this laptop
vainfo | grep -E 'H264|HEVC|VP9'

# Power profile stack
powerprofilesctl get

# Firmware updates
fwupdmgr get-devices

# AppImage support: both lines must print something
ldconfig -p | grep libfuse.so.2 && command -v fusermount

# NVIDIA (if you have an NVIDIA card; akmod builds at first boot)
nvidia-smi

# Chrome memory saver on an 8 GB machine
# chrome://settings/performance -> Memory Saver -> on
```

## Verification gates

`%post` fails the install if any of these is untrue, so the README cannot drift
away from the image:

- required packages present: `gnome-shell`, `gdm`, both extensions, Chrome,
  `libva-intel-media-driver`, `iwlwifi-mvm-firmware`, `tuned-ppd`, `bash`,
  `ffmpeg`, `fuse`, `kernel`, `akmod-nvidia`, `kernel-devel`, `gcc`, `make`,
  `kernel-headers`, `glibc-devel`, `kernel-modules-extra`,
  `mesa-va-drivers-freeworld`, `fwupd`, `gnome-firmware`, both RPM Fusion
  release packages
- `ldconfig -p` lists `libfuse.so.2` (the AppImage runtime `dlopen`s that
  soname, so the package alone would not prove it)
- trimmed packages absent: Firefox, LibreOffice, GNOME Boxes, GNOME Software,
  `gnome-tour`, Maps, Weather, `rygel`, remote desktop, Helium, `helix`
- `dconf read /org/gnome/shell/enabled-extensions` contains both UUIDs
- both extensions declare the installed shell major version
- exactly one `ppd-service` provider
- `google-chrome.desktop` exists and is the `https` handler
- the bash profile passes `bash -n`

The `build.sh` side has one more gate, before the ISO is built: the resolved
package tree must not contain the trimmed applications. Finding that out after a
15-minute install is worse than failing the build.

## Building

Everything goes through `build.sh`; `just` and the GitHub workflow are thin
wrappers around it.

```bash
./build.sh deps       # lorax, pykickstart, xorriso, isomd5sum, podman
./build.sh base       # netinst ISO + RPM Fusion release RPMs + keys + comps
./build.sh online     # out/gnome-devstation-45-x86_64.iso          (~1.3 GB)
./build.sh offline    # out/gnome-devstation-45-x86_64-offline.iso  (~2.9 GB)
./build.sh packages   # just resolve the package tree (packages/, ~2 GB)
./build.sh check      # kickstart validation + bash -n on every %pre/%post
```

With `just`, the same steps are `just fetch-base`, `just build`,
`just build-offline`, `just packages`, `just check`.

Build a different release:

```bash
FEDORA_RELEASE=46 ./build.sh base
FEDORA_RELEASE=46 ./build.sh offline
```

`$releasever` and `$basearch` flow through the kickstart repo definitions, so a
release bump is one variable. `./build.sh base` keeps an ISO it already has;
`REFRESH=1 ./build.sh base` looks for a newer point release.

`mkksiso` rebuilds the ISO's EFI boot image with `mkfs.vfat`, which needs a loop
device and therefore root. `build.sh` elevates **only that command** and gives
the resulting file back to you; downloads, the package tree and `out/` stay
owned by your user. On a machine without `mkksiso`, run `./build.sh deps` once.

The offline package tree is resolved inside a
`registry.fedoraproject.org/fedora:$FEDORA_RELEASE` container, so a Fedora 44
laptop can still build a correct Fedora 45 image. Set `BUILD_IMAGE=none` when you
are already inside a container of the target release — that is what CI does.

## What an offline build actually does

1. `cache/comps.xml` expands `@^workstation-product-environment` and the
   `-@group` removals into an explicit list, using the same rules Anaconda uses.
2. `dnf install --installroot=<empty> --downloadonly` resolves that list against
   live Fedora, RPM Fusion, Chrome and Helium repositories, and downloads the
   whole closure. An empty rpmdb is what makes the result an installed set
   rather than a delta against your laptop.
3. `createrepo_c` indexes `packages/`, which is then added to the ISO root.
4. The kickstart is copied with two edits: the remote `repo` lines become the
   embedded repository, and `%packages` becomes the resolved list. Everything
   else, `%post` included, is shared with the online image.

The result is verified before packaging: resolving the list against only
`file://…/packages` must succeed with zero problems. On Fedora 45 that is 1676
packages, and the transaction is byte-for-byte what an online install would
fetch.

## Project layout

```
kickstart/gnome-devstation.ks   The image definition. Everything else supports it.
files/90-devstation.sh          System-wide bash quality-of-life.
files/dconf-profile-user        dconf profile: user db + system db.
files/dconf-00-devstation       Pre-enables Caffeine and appindicator.
repos/google-chrome.repo        Shipped to /etc/yum.repos.d.
repos/helium-copr.repo          Shipped, enabled, Helium not installed.
build.sh                        All build entry points, online and offline.
scripts/check-kickstart.sh      ksvalidator + bash -n on every %pre/%post.
scripts/expand-packages.py      comps + %packages -> explicit package list.
scripts/resolve-packages.sh     Downloads that list into packages/.
scripts/make-offline-ks.py      Writes the offline ISO's kickstart.
justfile                        Thin wrappers around build.sh.
.github/workflows/              Validation on push, offline ISO on demand.
```

Two notes on the workflow, since GitHub's free tier is the reason both
repositories are public: Actions minutes are unlimited for public repositories,
and the build job is `workflow_dispatch` only because it produces a 2.9 GB
artifact. Validation runs on every push and costs seconds. The build runs in a
`docker run --privileged` container rather than a `container:` job, because the
EFI step needs loop devices.

## Troubleshooting

- **"dlopen(): error loading libfuse.so.2"** — the AppImage is a classic-runtime
  build and `fuse-libs` is missing. It is in the image; if you see this on a
  different machine, install `fuse-libs`.
- **No network after install** — check `ip link` and `nmcli device status`. The
  image carries every wireless firmware package, so a missing blob is not the
  usual cause; a regulatory-domain problem is. `sudo fwupdmgr refresh &&
  sudo fwupdmgr update` sometimes fixes a stale `wireless-regdb`.
- **NVIDIA black screen** — `akmod-nvidia` builds at install time. If the build
  failed, the install still succeeded and you get nouveau. Rebuild with
  `sudo akmods --force` and check `journalctl -b | grep akmod`.
- **Boot after offline install, no kernel** — this was a real bug before
  `kernel` was listed explicitly. If you have an old ISO, the kickstart in this
  repository is the fix; rebuild.

## License

MIT. See [LICENSE](LICENSE).
