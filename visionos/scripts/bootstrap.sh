#!/usr/bin/env bash
# Prepares a fresh clone of this fork for the visionOS build: fetches the
# submodules the build needs (aurora from JoeyAW/aurora-vr, whose pinned commit
# is not on encounter/aurora) and applies visionos/patches/{aurora,borealis}.
# Idempotent: a patch that is already applied is skipped; one that neither
# applies nor is applied stops the script.
#
#   visionos/scripts/bootstrap.sh            fetch the submodules, apply the patches
#   visionos/scripts/bootstrap.sh --reset    the same, after putting both submodules back
#                                            at their pinned commits (an update changed a
#                                            patch; local edits there are lost)
#   visionos/scripts/bootstrap.sh --check    only say whether both submodules are their
#                                            pinned commits plus the patches, nothing else
#                                            (exit 1 if not); changes nothing
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "${root}"

mode="${1:-}"
case "${mode}" in
    ""|--reset|--check) ;;
    *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac

# Whether a submodule's files are its pinned commit with the patches applied: the tree they
# should make (the pin, the patches applied through a scratch index) against the tree they do
# make (tracked and untracked files, ignored ones aside, through another). Neither the
# submodule's own index nor its files change.
matches() {
    local dir="$1" target="$2" scratch pinned expected actual
    [[ -e "${target}/.git" ]] || return 1
    pinned="$(git ls-tree HEAD "${target}" | awk '{print $3}')"
    [[ -n "${pinned}" ]] || return 1
    scratch="$(mktemp -d)"
    if ! GIT_INDEX_FILE="${scratch}/expected" git -C "${target}" read-tree "${pinned}" 2>/dev/null; then
        rm -rf "${scratch}"
        return 1
    fi
    shopt -s nullglob
    local patches=("${root}/${dir}"/*.patch)
    shopt -u nullglob
    for patch in "${patches[@]}"; do
        if ! GIT_INDEX_FILE="${scratch}/expected" git -C "${target}" apply --cached "${patch}" 2>/dev/null; then
            rm -rf "${scratch}"
            return 1
        fi
    done
    expected="$(GIT_INDEX_FILE="${scratch}/expected" git -C "${target}" write-tree)"
    # Starting from the submodule's own index (its file stamps), so only changed files are read.
    cp "$(git -C "${target}" rev-parse --path-format=absolute --git-path index)" "${scratch}/actual" 2>/dev/null || true
    GIT_INDEX_FILE="${scratch}/actual" git -C "${target}" add -A
    actual="$(GIT_INDEX_FILE="${scratch}/actual" git -C "${target}" write-tree)"
    rm -rf "${scratch}"
    [[ "${expected}" == "${actual}" ]]
}

if [[ "${mode}" == "--check" ]]; then
    ok=0
    for pair in "visionos/patches/aurora extern/aurora" "visionos/patches/borealis extern/borealis"; do
        set -- ${pair}
        if matches "$1" "$2"; then
            echo "$2: its pinned commit plus $1"
        else
            echo "$2: NOT its pinned commit plus $1 (visionos/scripts/bootstrap.sh --reset puts it back)"
            ok=1
        fi
    done
    exit "${ok}"
fi

if [[ "${mode}" == "--reset" ]]; then
    for target in extern/aurora extern/borealis; do
        if [[ -e "${target}/.git" ]]; then
            git -C "${target}" checkout -q -f -- .
            git -C "${target}" clean -fdq
            echo "reset ${target}"
        fi
    done
fi

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
            echo "ERROR: ${name} neither applies to nor is applied in ${target}." >&2
            echo "  If an update changed it: visionos/scripts/bootstrap.sh --reset" >&2
            exit 1
        fi
    done
}

apply_series visionos/patches/aurora extern/aurora
apply_series visionos/patches/borealis extern/borealis
echo "Ready. Build with visionos/scripts/build-visionos.sh --team TEAMID"
