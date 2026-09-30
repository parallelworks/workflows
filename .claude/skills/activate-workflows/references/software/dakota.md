# Dakota as the optimizer of an iterative workflow

> Learned building `workflows/dakota-openfoam` (2026-09): Dakota 6.16 (MOGA) proposing
> generations that the platform evaluates as a guarded static matrix, the
> `tutorials/optimization` loop. The README section "How Dakota fits the iteration
> contract" is the design; this file lists the facts that make it work and the traps.

## Install

- conda-forge `dakota=6.16.0` (a `py310` build; brings its own Python) installs
  without sudo next to other envs in one Miniforge prefix; check
  `conda run -n dakota dakota --version` (`workflows/dakota-openfoam/app/install-dakota.sh`).
  A site `module load dakota` goes through the same sourceable env file
  (`prepare-env.sh`). Launch it as `bash -c 'source "$1" && shift && exec dakota "$@"'`
  so the `exec` keeps Dakota as the session leader the wrapper later kills.

## Pausing Dakota between generations

Dakota drives evaluations itself and has no "emit a batch and exit" mode for
optimization methods, so the wrapper uses its crash-recovery semantics as the pause
button (`workflows/dakota-openfoam/app/optimizer.py`, `driver.py`):

- Every call resumes with `-read_restart` and a **fixed `seed`**, so the method
  deterministically replays to where it stopped; the fork driver serves already
  evaluated points from a results database keyed by a hash of the parameter values.
- New points are **captured**: each fork driver writes its case dir and blocks; once
  the pending set is stable the wrapper kills Dakota's process group and hands the
  cases to the platform. Dakota exiting on its own means its convergence criteria are
  satisfied.
- **Fork drivers run in their own process group** (verified 2026-09-29): `killpg` on
  Dakota's group never reaches a blocked driver, so a blocking driver must watch
  `os.getppid()` and exit when its parent is gone.
- **Killed before any evaluation completed, Dakota writes an EMPTY `-write_restart`
  file** (verified 2026-09-29); the next `-read_restart` of it aborts with a Boost
  archive error. Only read, and only replace the kept restart with, a file of size > 0.
- MOGA offspring that duplicate known points are served from Dakota's **evaluation
  cache** without any proposal, so a small population can yield fewer new points than
  `population_size` per generation; raise the mutation rate (`replace_uniform`, 0.2)
  and let surplus worker slots be skipped.
- A case that crashed must reach Dakota as `FAIL` in its results file with
  `failure_capture recover <values>` declared, or the point is re-proposed forever —
  **also when every case of a generation crashed**: with a fixed seed the replay
  re-requests the same points, so treating an all-failed generation as "the workers
  never ran" and re-proposing it can only fail again (run `01-controller-00025`,
  2026-09-30: two high-camber designs diverged with SIGFPE on the compute nodes and
  converged on the login node). Tell the two apart by evidence the case script ran
  (`exit_code`), and stop only when nothing has ever succeeded or several
  generations fail in a row.
- `asynchronous evaluation_concurrency = <batch>` exists only so the fork drivers of
  one generation block in parallel during the capture.

## File formats the fork interface uses

- Parameters file: line 1 `<n> variables`, then one `<value> <descriptor>` line per
  variable (plus function/derivative blocks after them).
- Results file: one `<value> <label>` line per response, or the single word `FAIL`.
- Compute any replay key from the printed values only, formatted identically on both
  sides (`%.12e`), so a re-requested point finds the objectives the workers produced.
