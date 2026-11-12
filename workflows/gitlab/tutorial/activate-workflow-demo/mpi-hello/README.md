# mpi-hello

An MPI hello world and the tests that run it on HPC systems through
[ACTIVATE](https://parallelworks.com).

| File | What it is |
|---|---|
| `hello.c` | the program: every MPI process prints one line |
| `test.sh` | the test: builds the program, runs it on N processes and passes when all N answer |
| `workflow.yaml` | the ACTIVATE workflow that runs the test on a cluster: it clones this project there, loads MPI and submits `test.sh` |
| `tests/<system>.json` | one file per system, named after its ACTIVATE resource: how MPI is loaded there and the scheduler options |
| `.gitlab-ci.yml` | the pipeline of a release: one job per system, each running the workflow there |

To test a change on every system, make a release: **Deploy → Releases → New release**.
