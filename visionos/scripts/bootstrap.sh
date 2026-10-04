#!/usr/bin/env bash
# Prepares a fresh clone of this fork for the visionOS build: fetches the
# submodules the build needs (aurora from JoeyAW/aurora-vr, whose pinned commit
# is not on encounter/aurora) and applies visionos/patches/{aurora,borealis}.
# Idempotent: a patch that is already applied is skipped; one that neither
# applies nor is applied stops the script.
#
#   visionos/scripts/bootstrap.sh
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "${root}"

git submodule init extern/aurora extern/borealis
git config submodule.extern/aurora.url https://github.com/JoeyAW/aurora-vr.git
git submodule update --recursive extern/aurora extern/borealis

apply_series() {
    local dir="$1" target="$2"
    shopt -s nullglob
    # Absolute paths: `git -C <submodule> apply` opens a relative patch path from inside the
    # submodule, where it doesn't exist (a fresh clone stopped here).
    local patches=("${root}/${dir}"/*.patch)
    shopt -u nullglob
    for patch in "${patches[@]}"; do
        local name
        name="$(basename "${patch}")"
        if git -C "${target}" apply --check "${patch}" 2>/dev/null; then
            git -C "${target}" apply "${patch}"
            echo "applied ${name} to ${target}"
        elif git -C "${target}" apply --reverse --check "${patch}" 2>/dev/null; then
            echo "already applied: ${name} (${target})"
        else
            echo "ERROR: ${name} neither applies to nor is applied in ${target}" >&2
            exit 1
        fi
    done
}

apply_series visionos/patches/aurora extern/aurora
apply_series visionos/patches/borealis extern/borealis
echo "Ready. Build with visionos/scripts/build-visionos.sh --team TEAMID"
