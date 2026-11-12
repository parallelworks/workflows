#!/bin/bash
# The project's test: builds hello.c and runs it on N MPI processes (default 4).
# It passes when every process answers, one line each. MPI must be loaded first.
set -ex -o pipefail
N=${1:-4}
mpicc -o hello hello.c
mpirun -np "$N" ./hello | tee hello.out
[ "$(wc -l < hello.out)" -eq "$N" ]
