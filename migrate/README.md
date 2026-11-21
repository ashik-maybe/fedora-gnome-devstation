# gnome-devstation converter

Turn a **fresh Fedora 45 Workstation** into the machine described by
`kickstart/gnome-devstation.ks`, without booting the ISO.

This is the in-place sibling of the ISO build. It adds the same repositories,
installs the same toolchain, firmware and codecs, removes the same applications,
and applies the same configuration. The kickstart is the single source of truth:
the converter reads its `%packages` section at run time through `manifest.py`.

It does **not** rebrand the system. There is no release-package swap, no custom
identity, no theme. It stays Fedora, exactly like the ISO install.

## Use

```bash
sudo dnf install -y git
git clone <this-repo> && cd gnome-devstation
sudo migrate/migrate.sh --plan          # print the work, change nothing
sudo migrate/migrate.sh                 # apply; re-run to resume
sudo migrate/migrate.sh --verify        # check markers, then run the shared gate
```

`--plan` is a dry run: it walks the steps but writes nothing outside the state
directory. `--verify` first requires a done marker for every step, then calls
the shared gate in `files/verify-devstation.sh`; it changes nothing. The full
command line is listed under
[Options](#options).

## Prerequisites and supported input

- A **fresh** Fedora Workstation install: x86_64, `ID=fedora`,
  `VARIANT_ID=workstation`, `VERSION_ID=45` in `/etc/os-release`. `FEDORA_RELEASE`
  is pinned to 45; anything else fails the `00-preflight` step.
- All outstanding updates must be installable. Preflight checks this instead of
  letting a half-updated machine resolve into a different package set.
- `git` to clone this repository, and `sudo` — `migrate.sh` re-execs itself with
  `sudo` when you call it as a normal user.
- Network access on a first run. The converter stages the third-party keys, the
  RPM Fusion release RPMs and the package closure into the state directory
  before it touches the installed system. Staging is resumable, so losing the
  connection mid-download costs time, not progress.
- Free disk space for the staged RPM tree and the dnf transactions.

A machine that already carries this image's packages, or somebody else's custom
setup, is not "fresh": the remove step uninstalls the applications in the
kickstart's exclusion list regardless of who put them there.

## The ten steps

`lib/runner.sh` discovers `migrate/steps/NN-name.sh` and runs them in this exact
order. Each step is sourced, idempotent, and verifies its own result before the
runner writes its done marker. A failure stops the run; completed steps are
never redone on resume.

| # | Step | What it does |
| --- | --- | --- |
| 00 | `00-preflight` | Checks OS, variant, release, arch and updateability; takes the run lock. |
| 10 | `10-assets` | Stages the RPM Fusion release RPMs and third-party signing keys into `assets/`, SHA-256 checked. |
| 20 | `20-rpms` | Resolves the kickstart's add list, downloads the RPM closure into `rpms/` and indexes it with `createrepo_c`. |
| 30 | `30-upgrade` | Brings installed packages current so the rest of the run resolves against an up-to-date base. |
| 40 | `40-repos` | Installs the repository definitions (RPM Fusion, Google Chrome, Helium COPR) and imports the keys. |
| 50 | `50-add` | Installs the add list from the kickstart: toolchain, firmware, codecs, browser, extensions. |
| 60 | `60-remove` | Removes the applications and groups from the kickstart's negative entries, minus the protected packages. |
| 70 | `70-config` | Applies the bash profile, the system dconf database and the Chrome default handler. |
| 80 | `80-flatpak` | Adds Flathub and installs Flatseal, Extension Manager and Gear Lever. |
| 90 | `90-verify` | Runs `files/verify-devstation.sh`, the same gate the ISO's `%post` uses. |

`manifest.py` derives `add.txt`, `remove.txt` and `drop-groups.txt` from the
kickstart at run time. A plain `package` goes to add, a `-package` to remove
(minus `colord`, `cups-pk-helper` and `libglvnd-gles`), a `-@group` to
drop-groups, and `@^workstation-product-environment` is ignored because a fresh
Workstation already has it. Any other `@group` is a hard error, so a kickstart
change cannot silently leave the converter behind.

## State, resume and corruption recovery

State lives in `/var/lib/gnome-devstation-migrate` (`$STATE_DIR`), never in
`/tmp`: `/tmp` is often tmpfs and is cleared on reboot, so it cannot survive the
interruption it is meant to protect against.

```
/var/lib/gnome-devstation-migrate/   # $STATE_DIR
├── migrate.log            timestamped log of every run (tee'd by migrate.sh)
├── interrupted            written on Ctrl+C / SIGTERM, names the step
├── steps/<id>.done        written only after a step's own verification passes
├── assets/                keys and release RPMs, staged as .part then verified
├── rpms/                  downloaded RPMs, indexed as a local dnf repository
└── manifest/              add.txt / remove.txt / drop-groups.txt
```

A `flock` in `/run/gnome-devstation-migrate.lock` stops two runs at once, so a
stale terminal cannot corrupt a live one.

**Resume.** No arguments means resume: re-acquire the lock and run the first
unfinished step, in order. A done marker stores the SHA-256 of its step script,
UTC time and step ID, so editing a step invalidates its marker and makes it run
again.

- **Ctrl+C / SIGTERM** writes `$STATE_DIR/interrupted` naming the step it
  stopped in. Re-running the same command clears it and carries on from there.
- **Network loss** is just an interrupted download. The partial file stays as
  `<dest>.part` and the next run resumes it with `curl -C -` instead of starting
  over. Nothing already marked done is repeated.
- A **failed step** leaves its marker absent; fix the cause and re-run. The
  runner stops at the first failure on purpose.

**Checksums and targeted refetch.** Assets are SHA-256 pinned in
`manifests/assets.sha256`. `download_stage` reuses `<dest>.part` with `curl -C -`,
verifies the digest, then atomically renames only a verified file. A corrupt
asset final file is deleted and re-fetched on its own; one full retry is allowed
before the step fails with a clear message. RPMs are checked with
`rpm -K --nosignature`; a bad RPM is deleted and re-fetched individually, then
the local repository is re-indexed with `createrepo_c`. Recovery is per file,
never from step zero. `file://` URLs work too, which is how the tests run
without a network.

## Options

```
migrate/migrate.sh [--plan] [--verify] [--step NN-name] [--force]
                   [--state-dir DIR] [--root DIR] [--os-release FILE] [--help]
```

| Option | Effect |
| --- | --- |
| *(none)* | Resume: run unfinished steps in order, stop at the first failure, keep every marker. |
| `--plan` | Print the work and change nothing outside the state dir (`DRY_RUN=1`). |
| `--verify` | Require every step marker, then run the shared gate; no changes. |
| `--step NN-name` | Select one step by ID, e.g. `--step 70-config`. |
| `--force` | Re-run a selected step even when its done marker exists (`FORCE=1`); use with `--step`. |
| `--state-dir DIR` | Use a different state directory instead of `/var/lib/gnome-devstation-migrate`. |
| `--root DIR` | Target root for the config and verify steps instead of `/`; a test hook. |
| `--os-release FILE` | Read a different os-release file during preflight; a test fixture hook. |
| `--help` | Print usage and exit. |

The script re-execs with `sudo` if you are not root. Exit status is 0 on
success, 1 on failure and 2 on a usage error. `--state-dir`, `--root` and
`--os-release` are for tests and dry runs; leave them alone on a real
conversion.

## Rollback

There is no single "unconvert" command, so leave yourself a way back before you
start:

- **dnf history baseline.** Note the current transaction ID with
  `dnf history list` before running. Dnf records every transaction the converter
  makes, so `dnf history info <id>` shows the starting point and
  `dnf history rollback <id>` (or `dnf history undo <id>` for the last one)
  reverses later changes.
- **`removed-packages.txt`.** The remove step records the exact packages it
  uninstalled in `removed-packages.txt` in the state dir. Anything you miss goes
  back with `sudo dnf install <name>`.
- **Btrfs snapshot.** If `/` is a Btrfs subvolume, take a read-only snapshot
  before the run and record how to boot it — for example
  `sudo btrfs subvolume snapshot -r / /pre-migrate-snapshot`, adjusted to your
  layout. A snapshot you can boot is faster and safer than unwinding dnf
  transactions on a system that may not be fully healthy.

## Limits

- **In-place is not atomic.** Every step is idempotent and resumable, but there
  is no instant switch back to the old system: a failed run can leave the
  machine partway through.
- **Back up first.** Snapshot or back up anything you cannot replace before you
  run the converter, especially on a machine that is not disposable.
- **Fresh input only.** It assumes stock Fedora 45 Workstation and removes the
  kickstart's excluded applications wherever they came from.
- **It stays Fedora.** No release-package swap, no custom identity, no theme —
  the converter is subject to the same non-goals as the ISO build.

## Tests

```bash
bash -n migrate/migrate.sh migrate/lib/*.sh migrate/steps/*.sh
python3 -m py_compile migrate/manifest.py
bash migrate/tests/test-state.sh
bash migrate/tests/test-download.sh
bash migrate/tests/test-manifest.sh
bash migrate/tests/test-preflight.sh
bash migrate/tests/test-config.sh
bash migrate/tests/test-flatpak.sh
```

`migrate/tests/e2e.sh` is opt-in and destructive: it drives a disposable Fedora
45 Workstation VM through a full run, a re-run, a Ctrl+C mid-download and a
deliberately corrupted staged RPM.

See `CONTRACT.md` for the interface between components.
