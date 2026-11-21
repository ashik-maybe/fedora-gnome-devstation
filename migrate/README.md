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
sudo migrate/migrate.sh --verify        # run only the final gate
```

Supported input: x86_64, `ID=fedora`, `VARIANT_ID=workstation`,
`VERSION_ID=45`, with all outstanding updates installable. Anything else fails
preflight. **Back up your machine first** — an in-place package change is not an
atomic image swap.

## Persistence and recovery

State lives in `/var/lib/gnome-devstation-migrate`:

```
state/migrate.log          timestamped log of every run
state/interrupted          written on Ctrl+C / SIGTERM, names the step
state/steps/<id>.done      written only after a step's own verification passes
state/assets/              keys and release RPMs, staged as .part then verified
state/rpms/                downloaded RPMs, indexed as a local dnf repository
state/manifest/            lists generated from the kickstart
```

`/tmp` is deliberately not used: it is often tmpfs and is cleared on reboot, so
it cannot survive the interruption it is meant to protect against. A small
`flock` in `/run/gnome-devstation-migrate.lock` prevents two concurrent runs.

Re-running the same command resumes at the first unfinished step. Staged files
are verified with SHA-256 (assets) and `rpm -K --nosignature` (RPMs); a corrupt
file is deleted and re-fetched on its own, not from the beginning. A step marker
stores the hash of the step script, so editing a step invalidates its marker and
makes it run again.

`--force <step-id>` re-runs one completed step. `--verify` runs the shared gate
from `files/verify-devstation.sh` without changing anything.

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
