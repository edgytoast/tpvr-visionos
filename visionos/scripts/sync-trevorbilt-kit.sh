#!/usr/bin/env bash
# Brings TrevorbiltKit, the launcher every Trevorbilt Vision Pro port shares, into
# visionos/TrevorbiltKit from a checkout of the repository that holds it (the SHAR port's, until
# the kit has a public repository of its own), at one commit, and records which in
# TrevorbiltKit/VERSION. The kit isn't edited here: changes go to its own repository and come back
# through this script.
#
#   visionos/scripts/sync-trevorbilt-kit.sh <checkout> [<commit>]
#
# <commit> defaults to the checkout's HEAD. The kit comes from the commit itself (git archive),
# never the checkout's working tree, so changes not yet committed there don't come along.
set -euo pipefail

checkout="${1:?usage: sync-trevorbilt-kit.sh <checkout> [<commit>]}"
commit="${2:-HEAD}"
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
target="$root/visionos/TrevorbiltKit"

commit="$(git -C "$checkout" rev-parse --verify "$commit^{commit}")"
# Where the kit lives in that repository: visionos/TrevorbiltKit in the SHAR port's, the root of
# its own.
if git -C "$checkout" cat-file -e "$commit:visionos/TrevorbiltKit/Package.swift" 2>/dev/null; then
    prefix="visionos/TrevorbiltKit"
elif git -C "$checkout" cat-file -e "$commit:Package.swift" 2>/dev/null; then
    prefix="."
else
    echo "No TrevorbiltKit at $commit in $checkout" >&2
    exit 1
fi
# Where it came from, without any credentials a remote's URL carries.
origin="$(git -C "$checkout" remote get-url origin 2>/dev/null | sed -E 's#://[^/@]*@#://#' || true)"
origin="${origin:-a local checkout}"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
git -C "$checkout" archive "$commit" "$prefix" | tar -x -C "$staging"
mkdir -p "$target"
rsync -a --delete --exclude VERSION "$staging/$prefix/" "$target/"
{
    echo "TrevorbiltKit, vendored by visionos/scripts/sync-trevorbilt-kit.sh; edit it in its own repository."
    echo "repository: $origin"
    echo "path: $prefix"
    echo "commit: $commit"
    if [ "$prefix" != "." ]; then
        echo "(TrevorbiltKit has no repository of its own yet: this is the port's repository it came from.)"
    fi
} > "$target/VERSION"
echo "TrevorbiltKit at ${commit:0:10} ($origin) is in visionos/TrevorbiltKit."
