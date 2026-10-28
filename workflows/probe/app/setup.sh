#!/bin/bash
# Shared setup of both PROBE workflows, run from the job directory after the checkout.
# The form values arrive as environment variables (TESTS_REPO, TESTS_BRANCH, TESTS_DIR,
# RESULTS_LOCATION, RESULTS_BUCKET_URI, RESULTS_PATH, RESULTS_DIRECTORY, RESTORE_RESULTS);
# a CLI run leaves an omitted input empty or undefined, so the form's defaults are
# applied here as well. Writes probe.env for the later steps and scripts, fetches the
# test definitions into tests/ and locates the results, restoring them from the bucket
# when RESTORE_RESULTS is true.
set -eo pipefail
export PATH=$HOME/pw:$PATH
export PYTHONPATH=$PWD/workflows/probe/app

default() { case "$1" in ''|undefined) echo "$2" ;; *) echo "$1" ;; esac; }

TESTS_REPO=$(default "${TESTS_REPO}" https://github.com/parallelworks/probe-tests-activate-parallel-works.git)
TESTS_BRANCH=$(default "${TESTS_BRANCH}" main)
TESTS_DIR=$(default "${TESTS_DIR}" tests)
# A run launched without a location (the CLI, a definition from before the input
# existed) keeps the bucket
RESULTS_LOCATION=$(default "${RESULTS_LOCATION}" bucket)
RESTORE_RESULTS=$(default "${RESTORE_RESULTS}" false)

set -x
python3 -m probe fetch-tests --repo "${TESTS_REPO}" --branch "${TESTS_BRANCH}" --directory "${TESTS_DIR}" --out tests
python3 -m probe list --tests tests --platform "${PW_PLATFORM_HOST}" --user "${PW_USER}" \
    || echo "::warning::Some test definitions are invalid; see above"

case "${RESULTS_LOCATION}" in
    bucket)
        case "${RESULTS_BUCKET_URI}" in
            ''|undefined|pw://) echo "::error::A results bucket is required"; exit 1 ;;
        esac
        RESULTS_PATH=$(default "${RESULTS_PATH}" probe/results)
        RESULTS_BUCKET="${RESULTS_BUCKET_URI%/}/${RESULTS_PATH}"
        RESULTS_BUCKET="${RESULTS_BUCKET%/}"
        RESULTS_DIR=$PWD/results
        mkdir -p "${RESULTS_DIR}"
        if [ "${RESTORE_RESULTS}" = true ]; then
            if out=$(pw buckets cp -r "${RESULTS_BUCKET}/" "${RESULTS_DIR}/" 2>&1); then
                echo "::notice::Results restored from ${RESULTS_BUCKET}"
            elif echo "${out}" | grep -q "no objects found"; then
                echo "::notice::No results yet at ${RESULTS_BUCKET}"
            else
                echo "${out}"
                echo "::error::Could not restore results from ${RESULTS_BUCKET}"
                exit 1
            fi
        fi
        ;;
    local)
        RESULTS_BUCKET=""
        RESULTS_DIR=$(default "${RESULTS_DIRECTORY}" "${HOME}/pw/probe/results")
        case "${RESULTS_DIR}" in
            /*) ;;
            *) echo "::error::The results directory must be an absolute path: ${RESULTS_DIR}"; exit 1 ;;
        esac
        mkdir -p "${RESULTS_DIR}" || { echo "::error::Cannot create the results directory ${RESULTS_DIR}"; exit 1; }
        echo "::notice::Results read and written in ${RESULTS_DIR} on $(hostname)"
        ;;
    *) echo "::error::Unknown results location: ${RESULTS_LOCATION}"; exit 1 ;;
esac

{
    printf '%s=%q\n' TESTS_REPO "${TESTS_REPO}" TESTS_BRANCH "${TESTS_BRANCH}" TESTS_DIR "${TESTS_DIR}" \
        RESULTS_DIR "${RESULTS_DIR}" RESULTS_BUCKET "${RESULTS_BUCKET}" \
        PW_PLATFORM_HOST "${PW_PLATFORM_HOST}" PW_USER "${PW_USER}" PW_RUN_SLUG "${PW_RUN_SLUG}"
} > probe.env
cat probe.env
