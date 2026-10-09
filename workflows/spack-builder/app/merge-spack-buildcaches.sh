#!/usr/bin/env bash
#
# merge-spack-buildcaches.sh
#
# Merge two local Spack build caches (mirrors) into a new, combined build
# cache by copying their contents together with rsync and then regenerating
# a single combined index.
#
# Usage:
#   ./merge-spack-buildcaches.sh <buildcache-source-1> <buildcache-source-2> <buildcache-merged>
#
# Assumptions:
#   * Both source build caches were produced with the SAME Spack version, so
#     they share the same on-disk layout version.
#   * All three paths are local directories on the same filesystem.
#   * `spack` is on PATH (the same version that built the caches).
#
# The two source caches are read only and left untouched.

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 <buildcache-source-1> <buildcache-source-2> <buildcache-merged>

Merge two local Spack build caches into a new merged build cache.
The two source caches are left untouched.
EOF
    exit 2
}

# Determine the buildcache layout version of the cache at $1.
#
# The layout version is what governs whether two caches can simply be unioned
# on disk, so we read it straight from each cache's on-disk structure:
#
#   * v3 (content-addressable) layout lives under a top-level 'v3/' area,
#     described by 'v3/layout.json'. The version is also recorded as "version"
#     in every 'v3/manifests/**/*.manifest.json'.
#   * v2 (legacy URL) layout lives under 'build_cache/', and each spec metadata
#     file ('*.spec.json' / '*.spec.json.sig') records "buildcache_layout_version".
#
# Prints one of: an integer version (e.g. 2 or 3), the literal "mixed" if the
# directory contains both layouts, or nothing (with a non-zero return) if no
# recognizable buildcache layout is found.
detect_layout_version() {
    local dir=$1
    local has_v3=0 has_v2=0

    if [[ -e "$dir/v3/layout.json" ]] || compgen -G "$dir/v3/manifests/*" >/dev/null 2>&1; then
        has_v3=1
    fi
    if [[ -d "$dir/build_cache" ]]; then
        has_v2=1
    fi

    if [[ $has_v3 -eq 1 && $has_v2 -eq 1 ]]; then
        echo "mixed"
        return 0
    elif [[ $has_v3 -eq 1 ]]; then
        echo 3
        return 0
    elif [[ $has_v2 -eq 1 ]]; then
        # Refine using the value actually recorded in a spec metadata file, so we
        # report the real number rather than assuming. (The field sits in the
        # cleartext body of clearsigned .sig files, so grep still finds it.)
        local specfile ver=""
        specfile=$(find "$dir/build_cache" -maxdepth 3 \
            \( -name '*.spec.json' -o -name '*.spec.json.sig' \) 2>/dev/null | head -1)
        if [[ -n "$specfile" ]]; then
            ver=$(grep -o '"buildcache_layout_version"[[:space:]]*:[[:space:]]*[0-9]\+' "$specfile" \
                | grep -o '[0-9]\+' | head -1)
        fi
        echo "${ver:-2}"
        return 0
    fi

    return 1
}

# --- Parse and validate arguments ------------------------------------------

if [[ $# -ne 3 ]]; then
    usage
fi

SRC1=$1
SRC2=$2
MERGED=$3

for src in "$SRC1" "$SRC2"; do
    if [[ ! -d "$src" ]]; then
        echo "Error: source build cache '$src' is not a directory." >&2
        exit 1
    fi
done

# Resolve to absolute, canonical paths so Spack gets an unambiguous mirror
# location and so we can guard against merging a source into itself.
SRC1=$(cd "$SRC1" && pwd -P)
SRC2=$(cd "$SRC2" && pwd -P)

mkdir -p "$MERGED"
MERGED=$(cd "$MERGED" && pwd -P)

if [[ "$MERGED" == "$SRC1" || "$MERGED" == "$SRC2" ]]; then
    echo "Error: the merged directory must differ from both source directories." >&2
    exit 1
fi

if ! command -v spack >/dev/null 2>&1; then
    echo "Error: 'spack' was not found on PATH." >&2
    exit 1
fi

echo "Source 1 : $SRC1"
echo "Source 2 : $SRC2"
echo "Merged   : $MERGED"
echo

# --- Preflight: both sources must share a buildcache layout version --------
#
# Merging is a plain file-level union, which is only valid when both caches use
# the same on-disk layout. We compare the two layout versions up front and
# refuse to copy anything if they differ. This script does NOT convert layouts.

LV1=$(detect_layout_version "$SRC1") || true
LV2=$(detect_layout_version "$SRC2") || true

for pair in "1:$SRC1:$LV1" "2:$SRC2:$LV2"; do
    idx=${pair%%:*}
    rest=${pair#*:}
    dir=${rest%:*}
    lv=${rest##*:}
    if [[ -z "$lv" ]]; then
        echo "Error: could not determine the buildcache layout version of source $idx:" >&2
        echo "         $dir" >&2
        echo "       No 'build_cache/' (v2) or 'v3/' (v3) layout was found." >&2
        echo "       Is this actually a Spack build cache directory?" >&2
        exit 1
    fi
    if [[ "$lv" == "mixed" ]]; then
        echo "Error: source $idx contains BOTH a v2 ('build_cache/') and a v3 ('v3/') layout:" >&2
        echo "         $dir" >&2
        echo "       This is ambiguous to merge. Settle it on a single layout first" >&2
        echo "       (e.g. finish 'spack buildcache migrate' and delete the old layout)." >&2
        exit 1
    fi
done

echo "Layout version (source 1): v$LV1"
echo "Layout version (source 2): v$LV2"

if [[ "$LV1" != "$LV2" ]]; then
    echo >&2
    echo "Error: refusing to merge -- buildcache layout versions differ." >&2
    echo "         source 1 ($SRC1): layout v$LV1" >&2
    echo "         source 2 ($SRC2): layout v$LV2" >&2
    echo >&2
    echo "       Caches of different layout versions cannot be safely unioned on disk." >&2
    echo "       Convert one to match the other before merging, for example:" >&2
    echo "           spack buildcache migrate <mirror-name>   # migrates v2 -> v3" >&2
    echo "       (This script intentionally does not convert layouts on the fly.)" >&2
    exit 1
fi

echo "Layout versions match (v$LV1). Proceeding with merge."
echo

# --- Copy both caches into the merged location -----------------------------
#
# A build cache uses a content-addressed layout: every tarball/blob and its
# metadata is keyed by hash, so files common to both caches (shared
# dependencies) are byte-for-byte identical and simply coincide. rsync copies
# the union of the two trees; the trailing slashes copy the *contents* of each
# source into the merged root. GPG public keys stored in the mirror are copied
# along with everything else.
#
# We skip the precomputed top-level index: each source index only describes
# its own cache, and a fresh combined index is generated below.

RSYNC_OPTS=(--archive --human-readable --info=progress2)

RSYNC_EXCLUDES=(
    --exclude='build_cache/index.json'
    --exclude='build_cache/index.json.hash'
)

echo "==> Copying source 1 into merged cache..."
rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRC1"/ "$MERGED"/

echo "==> Copying source 2 into merged cache..."
rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRC2"/ "$MERGED"/

# --- Rebuild the combined index --------------------------------------------

echo
echo "==> Regenerating combined build cache index..."
spack buildcache update-index "file://$MERGED"

echo
echo "Done. Merged build cache is ready at:"
echo "    $MERGED"
echo
echo "Use it with, for example:"
echo "    spack mirror add merged file://$MERGED"
echo
echo "Note: if the two caches were signed with different keys, make sure"
echo "consumers trust both, e.g.:"
echo "    spack buildcache keys --install --trust"
