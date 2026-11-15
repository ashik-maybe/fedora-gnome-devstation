# gnome-devstation

Fedora Workstation, trimmed to a developer laptop, with the media stack Fedora
leaves out and the small bash improvements you would otherwise add by hand.

No themes. No dotfiles. No kernel arguments. No custom `sysctl` files. If
upstream GNOME or Fedora changes a default, this image inherits the change
instead of fighting it.

---

## What this is (and is not)

It is the **Fedora Workstation environment group**, minus the applications
nobody uses on a development machine, plus a toolchain and RPM Fusion's codec
packages.

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
| Packages installed | 1853 | **1564** |
| Download | ~2 GiB | **~1.5 GiB** |
| Installed size | ~6 GiB | **~5 GiB** |

289 fewer packages. Helium, if you add it later, is ~415 MB plus a Qt5 stack
that this image does not otherwise carry.

## Hardware target

Written for an **HP EliteBook 840 G3**: Skylake i5-6300U, Intel HD 520, Intel
8260 Wi-Fi/Bluetooth, Intel HDA audio, no discrete GPU, no optical drive.

That is why the firmware list is Intel-only. Everything else — AMD, NVIDIA,
Broadcom, Realtek, MediaTek, Qualcomm, older Intel wireless — is excluded:

```
-amd-gpu-firmware      -nvidia-gpu-firmware    -atheros-firmware
-brcmfmac-firmware     -realtek-firmware       -mt7xxx-firmware
-nxpwireless-firmware  -qcom-wwan-firmware     -tiwilink-firmware
-libertas-firmware     -iwlegacy-firmware      -iwlwifi-dvm-firmware
-b43-fwcutter          -b43-openfwwf           -cirrus-audio-firmware
-alsa-sof-firmware     -intel-vsc-firmware     -amd-ucode-firmware
```

Kept: `intel-gpu-firmware` (Skylake DMC), `iwlwifi-mvm-firmware` (ships
`iwlwifi-8000C` for the 8260), `iwlbluetooth-firmware` (`ibt-11-5`),
`intel-audio-firmware`, `microcode_ctl`, and `linux-firmware` itself for the
wireless regulatory database.

The image still installs and boots on other hardware; it just will not bring up
a non-Intel Wi-Fi card or GPU without one `dnf install`. That is the trade for
191 MB of blobs this machine cannot use.

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

## What was added

### Session glue and extensions

`libglvnd-gles` (lost with `@firefox`; GLES-only apps break without it) ·
`gnome-shell-extension-caffeine` · `gnome-shell-extension-appindicator`

Both extensions are Fedora packages (v61 and v66, both declaring shell 45–51;
Fedora 45 ships GNOME Shell 51) and both are enabled **before the first login**
through a system dconf database:

```
/etc/dconf/profile/user       user-db:user, system-db:local
/etc/dconf/db/local.d/00-devstation
```

Nothing is locked. Extension Manager shows them as system extensions, and your
own `~/.config/dconf/user` takes priority as soon as you toggle anything.

Caffeine is enabled but **not inhibiting**: `restore-state=true` only remembers
whether you turned it on. Suspend and screen blanking behave normally until you
click the coffee cup in Quick Settings.

`gnome-shell-extension-appindicator` is what puts Steam, Slack, Discord and
Flatpak tray icons in the GNOME top bar.

### Media and codecs

Full RPM Fusion stack, preinstalled:

`ffmpeg` · `vlc` · `vlc-plugins-freeworld` ·
`gstreamer1-plugins-bad-freeworld` · `gstreamer1-plugins-ugly` (H.264 encoder) ·
`gstreamer1-plugins-ugly-free` · `gstreamer1-plugin-libav` ·
`gstreamer1-plugin-openh264` · `gstreamer1-plugin-dav1d` ·
`libva-intel-driver` (i965) ·
`libva-intel-media-driver` (iHD) · `libva-utils` · `libheif-freeworld` ·
`unrar`

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

### Developer toolchain

`git` `gh` `just` `gitui` `ripgrep` `fd-find` `bat` `eza` `fzf` `zoxide`
`direnv` `jq` `yq` `tmux` `gcc` `make` `pkgconf` `python3` `python3-pip`
`python3-devel` `nodejs24` `podman` `podman-compose` `shellcheck` `btop`
`strace` `lsof` `7zip`

Quality of life: `wl-clipboard` `sshfs` `git-lfs` `ncdu` `poppler-utils` `duf`

Flatpaks preinstalled from Flathub: **Flatseal** and **Extension Manager**.

Deliberately absent: C/C++ extras beyond `gcc`/`make`, Rust, Go, Java, database
servers, Kubernetes tooling. `uv` and everything else Python-related beyond
`pip`/`devel` is left to the user.

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

## Power and hardware

Fedora's own stack, untouched: `tuned` + `tuned-ppd` (the Power Profiles D-Bus
API in the Workstation environment), `thermald`, `upower`,
`power-profiles-daemon` **not** installed (two providers of `ppd-service`
would fight over the same D-Bus name — the kickstart asserts exactly one).

`fwupd` and `gnome-firmware` are included: HP publishes EliteBook BIOS images
to LVFS, so firmware updates work without a Windows dual boot.

## Install

Two ISOs come out of this repository. They install the same system; they differ
only in where the packages come from.

| ISO | Size | Install needs network | Built by |
| --- | --- | --- | --- |
| `…-45-x86_64.iso` | ~1.3 GB | yes | `./build.sh online` |
| `…-45-x86_64-offline.iso` | ~2.7 GB | **no** | `./build.sh offline` |

Both fit a 4 GB USB stick.

**Requirements:** x86_64 machine (written for an 840 G3), a USB stick of at
least 4 GB, and — for the online ISO only — wired or wireless network during
install.

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

The offline ISO embeds the resolved RPM closure (~1.5 GB) as a `createrepo_c`
repository, and the generated kickstart installs from
`file:///run/install/repo/packages`. No mirror is contacted at any point: the
RPM Fusion release packages and the Chrome signing key are shipped on the ISO
too, so `%post` does not download anything either.

Two things still need a network, and the build says so out loud:

- **Flatpaks** (Flatseal, Extension Manager) are skipped during an offline
  install, with a warning. Install them after first boot with
  `flatpak install flathub …` once you are online; the Flathub remote is only
  added by the online ISO.
- **Updates** obviously need one. Immediately after an offline install your
  system is the package set that was current when the ISO was built.

Everything else — the desktop, the codecs, the browser, the toolchain — is on
the ISO.

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

# Chrome memory saver on an 8 GB machine
# chrome://settings/performance -> Memory Saver -> on
```

## Verification gates in the build

`%post` fails the install if any of these is untrue, so the README cannot drift
away from the image:

- required packages present: `gnome-shell`, `gdm`, both extensions, Chrome,
  `libva-intel-media-driver`, `iwlwifi-mvm-firmware`, `tuned-ppd`, `bash`,
  `ffmpeg`, both RPM Fusion release packages
- trimmed packages absent: Firefox, LibreOffice, GNOME Boxes, GNOME Software,
  `gnome-tour`, Maps, Weather, `rygel`, remote desktop, Helium, `helix`,
  NVIDIA/AMD firmware, `alsa-sof-firmware`
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
./build.sh offline    # out/gnome-devstation-45-x86_64-offline.iso  (~2.7 GB)
./build.sh packages   # just resolve the package tree (packages/, ~1.5 GB)
./build.sh check      # kickstart validation only
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

The offline package tree is resolved inside a `registry.fedoraproject.org/fedora:$FEDORA_RELEASE`
container, so a Fedora 44 laptop can still build a correct Fedora 45 image. Set
`BUILD_IMAGE=none` when you are already inside a container of the target
release — that is what CI does.

### What an offline build actually does

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
`file://…/packages` must succeed with zero problems. On Fedora 45 that is 1564
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
scripts/expand-packages.py      comps + %packages -> explicit package list.
scripts/resolve-packages.sh     Downloads that list into packages/.
scripts/make-offline-ks.py      Writes the offline ISO's kickstart.
justfile                        Thin wrappers around build.sh.
.github/workflows/              Validation on push, offline ISO on demand.
```

Two notes on the workflow, since GitHub's free tier is the reason both
repositories are public: Actions minutes are unlimited for public repositories,
and the build job is `workflow_dispatch` only because it produces a 2.7 GB
artifact. Validation runs on every push and costs seconds. The build runs in a
`docker run --privileged` container rather than a `container:` job, because the
EFI step needs loop devices.

## License

MIT. See [LICENSE](LICENSE).
