# Converter contract (v1)

This file is the interface between the orchestrator (Hy4 flash Free) and the
builder agents (Tidepool Alpha). It is owned by the orchestrator. **Do not edit
this file from a segment worktree** — report a contract gap instead.

## Goal

Convert a **fresh Fedora 45 Workstation** into the state described by
`kickstart/gnome-devstation.ks`, in place, without booting an ISO. The kickstart
stays the single source of truth; the converter consumes it, it does not copy it.

Non-goals:

- no distro identity swap (no `fedora-release-common` replacement, no new repos
  beyond the ones the kickstart already uses, no rebranding);
- no changes to `build.sh` or the ISO build path, except the shared verification
  gate in segment 16;
- no `git push`.

## Layout

```
migrate/
  CONTRACT.md               this file
  README.md                 user-facing overview
  migrate.sh                entry point: root check, logging, lock, dispatch
  lib/state.sh              journal, markers, locking
  lib/runner.sh             step discovery and ordered execution
  lib/download.sh           resumable, checksummed asset staging
  lib/rpms.sh               staged RPM tree + local repo
  manifest.py               kickstart %packages -> add/remove/drop-groups lists
  manifests/assets.sha256   pinned checksums for keys/release RPMs
  steps/NN-name.sh          one file per step, sourced by the runner
  tests/                    self-contained tests using temp dirs / stubs
files/verify-devstation.sh   shared gate (segment 16)
```

## Environment (set by `migrate.sh`, overridable for tests)

| Variable | Default | Meaning |
| --- | --- | --- |
| `REPO_DIR` | directory containing `migrate/` | absolute path to this checkout |
| `STATE_DIR` | `/var/lib/gnome-devstation-migrate` | persistent journal + staged downloads |
| `ROOT` | `/` | target root; config/verify steps must honour it so tests can use a temp dir |
| `DRY_RUN` | `0` | `1` = plan only, no writes outside `STATE_DIR` |
| `OS_RELEASE_FILE` | `/etc/os-release` | preflight fixture hook |
| `FEDORA_RELEASE` | `45` | only this release is supported |
| `ASSETS_DIR` | `$STATE_DIR/assets` | staged keys + release RPMs |
| `RPMS_DIR` | `$STATE_DIR/rpms` | staged RPM tree, indexed as a local dnf repo |
| `MANIFEST_DIR` | `$STATE_DIR/manifest` | generated add/remove/drop-groups lists |
| `FORCE` | `0` | `1` = re-run an already completed step |

Log output is tee'd by `migrate.sh` to `$STATE_DIR/migrate.log`. Steps only
write to stdout/stderr and to `$STATE_DIR` / `$ROOT`.

## Step contract

Steps are **sourced**, not executed, by `lib/runner.sh`. Each `steps/NN-name.sh`:

1. defines `step_run()` — the work. Idempotent; safe to re-run at any point.
   Returns non-zero on failure. Must never call `exit` (that would kill the
   runner).
2. may define `step_plan()` — prints what would happen; defaults to a one-line
   description.
3. sources any library it needs with
   `source "$REPO_DIR/migrate/lib/<name>.sh"`, guarding against double sourcing
   with a `_LIB_<NAME>_LOADED` variable.
4. verifies its own result before returning 0. The runner writes the done marker
   **only** after `step_run()` returns 0.
5. uses `state_log` for progress, not bare `echo` where a timestamp matters.
6. refuses to touch the live system when `ROOT != /` unless the step is purely
   a staging step (00, 10, 20). Config steps must prefix every path with `$ROOT`.

Step IDs and order (exact filenames):

```
00-preflight  10-assets  20-rpms  30-upgrade  40-repos
50-add  60-remove  70-config  80-flatpak  90-verify
```

## Library APIs

`lib/state.sh`:

```
state_init
state_log <message...>
state_is_done <id> <step_file>     # 0 when marker exists and its hash matches
state_mark_done <id> <step_file>   # atomic write: sha256(file), UTC time, id
state_mark_interrupted <id>        # writes $STATE_DIR/interrupted
state_clear_interrupted
state_lock_acquire                 # flock -n fd 9 on /run/gnome-devstation-migrate.lock
state_lock_release
```

`lib/download.sh`:

```
download_stage <url> <dest> <sha256>
```

Reuses `<dest>.part` with `curl -C -`, verifies sha256, then atomically renames.
If an existing final file is corrupt, delete only that file. One full retry is
allowed; after that, fail with a clear message. Works with `file://` URLs so the
tests need no network.

`lib/rpms.sh`:

```
rpms_stage <add_list_file>     # dnf download --resolve into $RPMS_DIR,
                               # verify every rpm with rpm -K --nosignature,
                               # delete + refetch only bad rpms, createrepo_c
rpms_dnf_arg                   # prints --repofrompath=migrate,file://$RPMS_DIR
```

`manifest.py`:

```
python3 "$REPO_DIR/migrate/manifest.py" <kickstart> <out_dir>
```

Writes `add.txt`, `remove.txt`, `drop-groups.txt` from the `%packages` section:

- plain `package` -> `add.txt`
- `-package` -> `remove.txt`, minus `colord`, `cups-pk-helper`, `libglvnd-gles`
- `-@group` -> `drop-groups.txt`
- `@^workstation-product-environment` -> ignored (already installed on a fresh
  Workstation)
- any other `@group` -> hard error, so a kickstart change cannot silently leave
  the converter behind

`files/verify-devstation.sh` (segment 16) is the one gate. It reads `ROOT` and
checks required/absent packages, extensions, `libfuse.so.2`, Chrome default and
the bash profile. Both the ISO's chrooted `%post` and `migrate/steps/90-verify.sh`
call it.

## CLI

```
migrate/migrate.sh [--plan] [--verify] [--step NN-name] [--force]
                   [--state-dir DIR] [--root DIR] [--os-release FILE] [--help]
```

No arguments = resume: lock, run unfinished steps in order, stop at first
failure, keep every completed marker. Re-exec with `sudo` when not root. Exit 0
on success, 1 on failure, 2 on usage error.

## Segment ownership

One commit per segment, exact messages are given in each agent prompt. Agents
own only the files listed in their prompt. If two segments need the same file,
the orchestrator sequences them; never edit another segment's file. Commit in
your own worktree with the exact message supplied. Do not merge, cherry-pick,
tag or push.
