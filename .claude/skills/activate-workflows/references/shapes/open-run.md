# Shape: a run that stays open while it serves

The jobs after preprocessing for a workflow whose run stays with what it started:
the service lives exactly as long as the run, and cancelling the run is the teardown,
as on Kubernetes but on a compute cluster. One workflow has it,
`workflows/start_gt_scheduler` (a scheduler daemon and its autoscaling loop on a
cluster's controller), and it is the copy to start from. Take it only when the
service cannot be left behind an endpoint: here it needs the user workspace for its
whole life (a license server that admits nothing else, a `pw` sign-in that lasts as
long as the service) and serves no web page. A web service is the endpoint shape; a
job that finishes is the batch shape.

## The jobs

All of them run in the **user workspace** (no `ssh:` block) and reach the cluster with
short `ssh` calls of their own, so nothing depends on one connection staying up for
weeks. The files the cluster needs are sent from the workspace's checkout (`rsync`),
not checked out a second time there.

1. **preprocessing** also checks the target before anything is authorized, copied or
   started, and leaves what it found in a file for the other jobs (`controller.env`).
   A run that fails here has touched nothing. It refuses a target that already runs
   the service.
2. **One job per thing that has to be held**, each a single step that starts it and
   stays open, with the step's own `cleanup:` as its teardown (`license_access`: a key
   installed on another host, then `sleep inf`; `scheduler`: the service started in a
   `screen` session, then a loop that watches it). Each carries
   `early-cancel: any-job-failed`.
3. **A wait job** (`wait_for_scheduler`) that completes on evidence the service works
   and fails the run otherwise. It is what a test reads.

The jobs find each other through marker files in the run's directory, which they
share (`license-access.ready`, `scheduler.launched`), not through outputs.

## What "done" and "clean" mean here

- **The run never completes.** The wait job is the evidence; after it, the watching
  step fails the run when the service is gone. It tells a service that is gone, which
  is evidence, from a host that does not answer, which is not, and gives the second
  more time and its own message.
- **Cancelling the run is the teardown**, and the only one: the README says so. A
  step's own `cleanup:` runs after a user cancel and after `early-cancel`
  (pitfalls, 2026-11-10); a job-level `cleanup:` list and handler jobs are not to be
  relied on for a user cancel.
- **A cleanup works from nothing and twice.** It can run in the step's first second,
  before anything was started, and again after the step has already called it.
- **A cleanup only reaches what its own run started.** Record the identity of what
  was started (the session's id, in the run's own directory on the cluster) and act on
  that, never on a name another run's service shares: a run refused because the target
  is busy, or one whose service died before another run started, must leave the other
  alone. Serialize the start itself with a lock that ends with the script that takes
  it (`flock`), so it cannot go stale.
- **What a step starts detached is found by its command line**, not by a pid file the
  step may not have got to write before a cancel.
- **A teardown that cannot reach the cluster says so**: it retries while `ssh` cannot
  connect, then ends in an error naming the command to run there by hand.
- What still escapes: a workspace restart ends the run with no cleanup at all. The
  README says what is left then and how to clear it.

`script_submitter` is not used: it would hold one step open on the cluster for the
run's whole life. The tunnels such a workflow opens are the application's own (a
license server's ports); exposing a service is still `pw endpoints`.

## Tests

`_test.ready_job` names the wait job (`tools/tests/README.md`): pass = it completes
while the run is still running, then the runner cancels the run and makes its leftover
checks, so every recorded launch records a cancel too. The runner only sees the
cluster: what the run touches elsewhere (the workspace, a third host) is checked by
hand. Besides the recorded launch and a failure path, check by hand what only this
shape has: a cancel at several points of the start-up, the service killed under the
run, a second run on a busy target, and a new run started while an old one has not yet
noticed its service died.
