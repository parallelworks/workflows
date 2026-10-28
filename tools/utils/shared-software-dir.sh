#!/bin/bash
# Usage: shared-software-dir.sh <login-host>
#
# Prints the shared software directory of the cluster whose login node is
# <login-host> (the resource's ip input), nothing when the cluster has none: cloud
# clusters, the workspace, every other platform. The one host table of the NOAA
# variants; what to do with the directory is the caller's business: install there
# when `mkdir -p` of its subdirectory succeeds, reuse what is staged there
# read-only, fall back to /contrib/pw where it exists on an unknown host.
case "$1" in
    hfe[0-9]*.fairmont.rdhpcs.noaa.gov) echo /contrib/pw ;;              # Hera
    mfe[0-9]*.fairmont.rdhpcs.noaa.gov) echo /contrib/pw ;;              # Mercury
    ufe[0-9]*.fairmont.rdhpcs.noaa.gov) echo /contrib/pw ;;              # Ursa
    gaea[0-9]*.ncrc.gov) echo /usw/rdhpcs/software/pw ;;                 # Gaea
    an[0-9]*.princeton.rdhpcs.noaa.gov) echo /app/pw ;;                  # PPAN
esac
