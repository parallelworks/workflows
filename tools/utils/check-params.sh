#!/bin/bash
# Usage: check-params.sh <design-parameters.txt> <params.in> [source]
#
# Checks a design file against the design parameters a runner publishes:
#   design-parameters.txt  one name per line (the first word; '#' starts a comment)
#   params.in              one "<value> <name>" line per design parameter
# Every name in params.in must be listed, and every value must be a number. A
# runner calls this before it solves anything, so a misspelled name fails the
# case instead of being ignored. Prints one ::error:: line per problem and exits
# 1 when there is any, 0 otherwise. [source] names where the design came from in
# the messages (default: the params.in path).
#
# The convention: .claude/skills/activate-workflows/references/design-parameters.md
names="$1"
params="$2"
source="${3:-$2}"
if [ ! -f "${names}" ] || [ ! -f "${params}" ]; then
    echo "::error::usage: check-params.sh <design-parameters.txt> <params.in> [source]"
    exit 1
fi
awk -v src="${source}" -v list="${names}" '
    NR == FNR {
        sub(/#.*/, "")
        if (NF) { known[$1] = 1; order = order (order ? ", " : "") $1 }
        next
    }
    /^[[:space:]]*(#|$)/ { next }
    NF < 2 {
        printf "::error::%s, line %d: expected \"<value> <name>\", got \"%s\"\n", src, FNR, $0
        bad = 1
        next
    }
    !($2 in known) {
        if (!($2 in unknown)) { unknown[$2] = 1; names_bad = names_bad (names_bad ? ", " : "") $2 }
        bad = 1
        next
    }
    $1 !~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ {
        printf "::error::%s: %s = \"%s\" is not a number\n", src, $2, $1
        bad = 1
    }
    END {
        if (names_bad != "")
            printf "::error::%s has %s, which this runner does not read. Its design parameters are %s (%s).\n", src, names_bad, order, list
        exit bad
    }
' "${names}" "${params}"
