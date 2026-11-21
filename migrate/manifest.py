#!/usr/bin/env python3
"""Convert a kickstart %packages section into the migration manifest lists.

The kickstart is the single source of truth; this script reads its
%packages section and derives the add / remove / drop-group lists that the
migration steps consume (CONTRACT.md, "manifest.py"):

  package                           -> add.txt
  -package                          -> remove.txt, except the KEEP set
  -@group                           -> drop-groups.txt
  @^workstation-product-environment -> ignored: a fresh Workstation has it
  @group                            -> hard error: the converter would
                                       otherwise silently miss it

Entries are de-duplicated, keeping first-seen order.

Usage: python3 migrate/manifest.py <kickstart> <out_dir>
"""

import os
import sys

# Negated names that must survive, so they never enter remove.txt.
KEEP = {"colord", "cups-pk-helper", "libglvnd-gles"}

# The only positive environment reference the converter knows: a fresh
# Workstation already has everything it names, so it is ignored.
IGNORED_ENVIRONMENT = "workstation-product-environment"


def main():
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: python3 {sys.argv[0]} <kickstart> <out_dir>")
    kickstart, out_dir = sys.argv[1], sys.argv[2]

    add, remove, drop_groups = [], [], []
    in_packages = terminated = False
    for raw in open(kickstart):
        line = raw.strip()
        if not in_packages:
            in_packages = line.startswith("%packages")
            continue
        if line == "%end":
            terminated = True
            break
        if not line or line.startswith("#"):
            continue
        if line.startswith("%"):
            raise SystemExit(f"{kickstart}: unexpected directive in %packages: {line}")
        if line.startswith("@^"):
            if line[2:] != IGNORED_ENVIRONMENT:
                raise SystemExit(
                    f"unsupported group in %packages: {line!r} "
                    f"(only @^{IGNORED_ENVIRONMENT} is ignored)"
                )
        elif line.startswith("-@"):
            name = line[2:]
            if not name:
                raise SystemExit(
                    f"{kickstart}: empty drop-group in %packages: {line!r}"
                )
            drop_groups.append(name)
        elif line.startswith("-"):
            name = line[1:]
            if not name:
                raise SystemExit(f"{kickstart}: empty negation in %packages: {line!r}")
            if name not in KEEP:
                remove.append(name)
        elif line.startswith("@"):
            raise SystemExit(
                f"unsupported group in %packages: {line!r} "
                f"(only @^{IGNORED_ENVIRONMENT} is ignored)"
            )
        else:
            add.append(line)

    if not in_packages:
        raise SystemExit(f"{kickstart}: no %packages section")
    if not terminated:
        raise SystemExit(f"{kickstart}: %packages section is unterminated")

    add = list(dict.fromkeys(add))
    remove = list(dict.fromkeys(remove))
    drop_groups = list(dict.fromkeys(drop_groups))

    os.makedirs(out_dir, exist_ok=True)
    for name, entries in (
        ("add.txt", add),
        ("remove.txt", remove),
        ("drop-groups.txt", drop_groups),
    ):
        with open(os.path.join(out_dir, name), "w") as handle:
            for entry in entries:
                handle.write(entry + "\n")
    print(f"add={len(add)} remove={len(remove)} drop-groups={len(drop_groups)}")


if __name__ == "__main__":
    main()
