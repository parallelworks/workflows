#!/usr/bin/env bash
# find-externals.sh — discover or apply the site externals for ONE node.
#
#   find-externals.sh discover LABEL OUT_YAML   run `spack external find` on THIS
#                                               node and save what it found
#   find-externals.sh apply IN_YAML             make IN_YAML the externals the
#                                               build concretizes against
#
# Discovery runs twice per run: on the login node (controller.sh, label "head")
# and on the inspected worker (detect-fabric.sh, label "compute"). The build
# always applies the COMPUTE file, wherever it compiles, because every binary it
# produces runs on the workers -- an external that exists only on the login node
# would link there and be missing at run time. The head file is kept for the log:
# the two side by side (inspect-head-node.sh diffs them) is how a split image is
# diagnosed without a shell on either node.
#
# Discovery writes through the shared site scope ($SPACK_ROOT/etc/spack/site),
# then copies the managed packages out to OUT_YAML, so the site scope holds
# whichever node ran last. That is why the build re-applies its file explicitly
# instead of trusting what happens to be there.
#
# Consumes (from the sourced inputs.sh): service_install_prefix, app_dir.

set -euo pipefail

ACTION="${1:?usage: find-externals.sh discover LABEL OUT_YAML | apply IN_YAML}"
SPACK_ROOT="${service_install_prefix:?service_install_prefix is required}"
APP_DIR="${app_dir:?app_dir is required}"
SITE_PACKAGES="$SPACK_ROOT/etc/spack/site/packages.yaml"

# slurm and rdma-core must match the running cluster and kernel, so they are
# pinned not-buildable. libfabric and ucx are registered but left buildable on
# purpose: the fabric profile decides whether to bind the vendor library (the
# aws fragment pins it external) or let Spack build one with its own variants.
NOT_BUILDABLE="slurm rdma-core"
BUILDABLE="libfabric ucx"
# shellcheck disable=SC2206
MANAGED=($NOT_BUILDABLE $BUILDABLE gmake)

# shellcheck disable=SC1091
. "$SPACK_ROOT/share/spack/setup-env.sh"

case "$ACTION" in
  discover)
    LABEL="${2:?usage: find-externals.sh discover LABEL OUT_YAML}"
    OUT="${3:?usage: find-externals.sh discover LABEL OUT_YAML}"
    printf '\n=== [externals:%s] discovering site externals on %s ===\n' "$LABEL" "$(hostname)"

    spack python "$APP_DIR/site-externals.py" clear "$SITE_PACKAGES" "${MANAGED[@]}"
    # shellcheck disable=SC2086
    spack external find --scope site --not-buildable $NOT_BUILDABLE || true
    # shellcheck disable=SC2086
    spack external find --scope site $BUILDABLE || true

    # gmake is a build tool, not part of the delivered stack, and compiling it is
    # where padded install paths bite: with config:install_tree:padded_length set,
    # gmake@4.4.1's config.status intermittently dies with
    #   mv: cannot move './confXXXXXX/out' to 'doc/Makefile': No such file or directory
    #   config.status: error: could not create doc/Makefile
    # It is genuinely intermittent rather than deterministic -- the same padded build
    # failed on two clusters and succeeded on a third attempt with identical settings
    # -- so registering the system make and letting Spack reuse it removes the
    # flakiest package from the build entirely.
    #
    # Deliberately NOT --not-buildable: if some package ever needs a newer make than
    # the image ships, Spack should still be free to build one rather than failing to
    # concretize.
    spack external find --scope site gmake || true

    # Drop any external that has libraries but no headers. `external find` detects a
    # package from its libraries, but Spack then compiles against it -- and an image
    # that ships the runtime without the -devel package yields an external that looks
    # valid and fails at configure time. Seen three times now (slurm, rdma-core,
    # libfabric), and it is image-specific: the AWS EFA libfabric under
    # /opt/amazon/efa has headers, the GCE /usr one does not. So it is probed on
    # each node rather than decided in a fabric fragment.
    printf '[externals:%s] pruning externals that lack development headers\n' "$LABEL"
    spack python "$APP_DIR/prune-headerless-externals.py" "$SITE_PACKAGES"

    spack python "$APP_DIR/site-externals.py" extract "$SITE_PACKAGES" "$OUT" "${MANAGED[@]}"

    # The system compilers this node offers. Logged only: the build registers the
    # compiler of the node that actually compiles (build.sh), and this listing is
    # what explains a difference between the two.
    printf '\n=== [externals:%s] system compilers on %s ===\n' "$LABEL" "$(hostname)"
    for c in gcc g++ gfortran clang; do
      if command -v "$c" >/dev/null 2>&1; then
        printf '  %-9s %s (%s)\n' "$c" "$("$c" -dumpfullversion 2>/dev/null || "$c" --version 2>/dev/null | head -1)" "$(command -v "$c")"
      else
        printf '  %-9s <none>\n' "$c"
      fi
    done

    printf '\n=== [externals:%s] site externals found on %s -> %s ===\n' "$LABEL" "$(hostname)" "$OUT"
    cat "$OUT"
    ;;

  apply)
    IN="${2:?usage: find-externals.sh apply IN_YAML}"
    [ -f "$IN" ] || { echo "::error title=Error::no externals file at $IN" >&2; exit 1; }
    spack python "$APP_DIR/site-externals.py" apply "$SITE_PACKAGES" "$IN" "${MANAGED[@]}"
    printf '\n=== [externals] applied %s to the site scope ===\n' "$IN"
    spack config --scope site get packages
    ;;

  *)
    echo "usage: find-externals.sh discover LABEL OUT_YAML | apply IN_YAML" >&2
    exit 2
    ;;
esac
