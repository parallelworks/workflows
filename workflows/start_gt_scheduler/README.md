# GT scheduler

Starts the GT-SUITE distributed scheduler on an elastic SLURM cluster: the GT
daemon (`gtdistd`) on the cluster's controller node, and a loop beside it that
starts executor nodes for the cores the queued GT jobs need and lets them go when
they are idle. A cluster runs one GT scheduler at a time.

## Using it

1. Start the cluster.
2. Run this workflow on it. The run stays open for as long as the scheduler
   serves, and its `scheduler` job shows the scheduler's log.
3. Submit GT jobs:
   - from GTISE, in distributed mode, to the cluster's external IP address (the
     run's notice names it), or
   - from GTISE started on the controller node with the gtise remote desktop
     workflow, to `localhost`.

**Cancel the run to stop the scheduler.** The cancel ends the scheduler's session,
stops `gtdistd`, cancels every SLURM job of the user on that cluster (the
executors, and anything else queued there), closes the tunnels and takes the
controller's key off the license server again. No process, tunnel, SLURM job or
license-server key outlives the run; its directory on the controller stays, for
the logs.

A run only watches, and only stops, the scheduler it started. A second run on a
cluster that already has one fails in seconds without touching it; a run whose
scheduler died ends in error and leaves alone a scheduler that another run started
in the meantime. Two things the run cannot do for itself:

- If the cancel cannot reach the controller, the run ends with an error naming
  the script to run there: `~/pw/jobs/<run>/cancel.sh`.
- If the user workspace restarts, the run ends with no cleanup at all. The
  scheduler's loop stops by itself within minutes, but `gtdistd` keeps running on
  the controller and the controller's key stays on the license server. Starting a
  new run and cancelling it clears both.

## What the scheduler does

Every sensing cycle the loop reads the jobs `gtdistd` holds, counts the cores
their queued and running packets need (the core demand, kept between the form's
minimum and maximum) and compares it with the cores of the executor jobs already
in the queue (the core supply). For the difference it submits executor jobs, one
exclusive node each, largest nodes first so that all GT jobs run at once on as few
nodes as possible. An executor exits once its simulations are done, or after ten
minutes without any; with no demand at all the loop cancels the user's SLURM jobs.
A job on a node the platform reports as failed is cancelled and the partitions of
that size are rotated, so the next attempt lands elsewhere.

License use is metered per GT product. The organization's groups named
`<cluster>-<product>` hold the core-hour allocations, and the loop reads what is
left of each every cycle: a product with nothing left is taken out of the licenses
the scheduler permits, and with nothing left at all no further executor is started.

## Storage

- A persistent disk mounted under `/software`, NFS-exported to the compute nodes,
  holds the GT software (`/software/gtsuite/<version>`).
- A persistent disk mounted under `/var/opt/gtsuite` is the scheduler's work
  directory.

Restarting the cluster deletes everything that is not on those disks.

## License server access

Executors take their licenses from ports on the controller, which an SSH tunnel
forwards to the license server. The license server only accepts connections from
the user workspace, so that tunnel jumps through it: the run installs the
controller's public key on the license server for its duration, and keeps a reverse
tunnel from the controller back to the workspace (the `usercontainer` host entry in
the controller's `~/.ssh/config`), which the scheduler's balance queries use too.
The workspace must already be able to `ssh` to the license server; the key the
controller uses for the hop back stays authorized in the workspace between runs.

## Variants

One YAML per license server; its address, ports and organization are hidden inputs.
The jobs and every script are the same in all of them.

| Variant | For | GT versions |
|---|---|---|
| `gtproduction-dev` | the development license server | v2024 to v2026 |
| `gtproduction-production` | the production license server | v2024 to v2026 |
| `gtcustomers-americanbattery`, `-isuzu` | hosted customers | v2023 to v2026 |
| `gtcustomers-martintechnologies` | hosted customer | v2022 to v2026 |
| `gtcustomers-echogen` | hosted customer | v2020 to v2024 |
| `gtcustomers-sanden`, `-serma`, `-shell`, `-wisk` | hosted customers | v2024 to v2026 |

`gtproduction-dev` alone has **Max parallel cores per solver**; `gtcustomers-sanden`
has a minimum core demand of 2 by default, which keeps one executor node running.

## The form

- **Service host**: the cluster. The scheduler runs on its controller node.
- **GT version**: must be installed under `/software/gtsuite` there.
- **Advanced GT inputs**: the job summary service, the parallel solver and, where
  the variant has it, the cores a parallel solver may use.
- **Advanced PW inputs**: the sensing cycle in seconds, and the minimum and maximum
  core demand the loop serves.

## The jobs

All four run in the user workspace and reach the controller over `ssh`: the
workspace is the one host the license server admits, and the one signed in to the
platform for the balance queries however long the run lasts.

1. **preprocessing** checks out `workflows/start_gt_scheduler/app`, writes
   `inputs.sh` and checks the cluster before anything is authorized or started: it
   is running and reachable, holds the GT version, has what the scheduler needs and
   does not already run a scheduler. A run that fails here has touched nothing.
2. **license_access** installs the controller's public key on the license server
   and in the workspace, then stays open; its cleanup removes the key from both.
3. **scheduler** sets up the controller's connection back to the workspace, copies
   `app/controller/` to the controller, opens the license tunnel, starts the
   scheduler there in a `screen` session named `gt-scheduler` and streams its log.
   Every 90 s it checks the tunnels, reopening one that dropped, and the session:
   five checks without it end the run in error, as do ten without an answer from
   the controller. Its cleanup stops everything this run started.
4. **wait_for_scheduler** completes once the first sensing cycle ran with `gtdistd`
   active, and fails the run if the scheduler exits or never gets there.

## Where to look

| | |
|---|---|
| `/tmp/runs/<run>/` in the workspace | `inputs.sh`, `controller.env` (the controller's address and directory), `reverse-tunnel.out` |
| `~/pw/jobs/<run>/` on the controller | `logs.out` (the scheduler's log), `inputs.sh`, `balance.json`, `node_info.json`, `webapp.xml`, `CORE_DEMAND`, `partitions.list`, `cancel.sh` |
| `~/pw/jobs/<run>/slurm-jobs/<date>/` | each executor's batch script and output |
| `/var/opt/gtsuite/gtdistd/log/`, `/tmp/gtdistd.out` | the GT daemon's own logs |

`<run>` is `<workflow>/<run number>` for a registered workflow and the run's slug
for one launched from a file. The loop reads `inputs.sh` and `scheduler-libs.sh`
again every cycle, so a limit edited in the controller's copy applies from the next
one.

## The properties files

`app/controller/properties_files/` holds one scheduler and one executor file per GT
version, and the scripts set these parameters in the copy they start a daemon with;
anything else can be changed in the file, and a parameter that is commented out
stays so.

- Executor: `GTDistributed.work-dir`, `GTDistributed.license-file`,
  `GTDistributed.client.hostname`, `GTDistributed.executor.core-count`.
- Scheduler: `GTDistributed.work-dir`, `GTDistributed.job-summary-service-enable`,
  `GTDistributed.scheduler.max-parallel-cores-per-solver` and its `validation` line
  (with the parallel solver allowed), and every cycle, from the balance,
  `GTDistributed.scheduler.max-licenses.<product>` and
  `GTDistributed.scheduler.validation.permitted-licenses`.

## What the cluster needs

A SLURM cloud cluster with the two disks above, `sudo` without a password, and
`screen`, `netstat`, `curl`, `jq`, `rsync` and `python3`; partition names of at most
eight characters. The run checks all but the last before it starts anything.

## Tests

`tests/gtproduction-dev/` holds the recorded tests, run with
`python3 tools/tests/run-workflow-test.py` on the development cluster: `dev` starts
the scheduler, waits for `wait_for_scheduler` and cancels the run, checking that
nothing is left on the controller; `dev-min-cores` does the same with a minimum core
demand, so that an executor job is in the queue when the cancel comes (it starts one
compute node); `dev-gt-not-installed` asks for a GT version the cluster does not hold
and expects the run to end in error at preprocessing. The runner only sees the
controller: the workspace and the license server are checked by hand.

The other variants point at production license servers and are not run from here.
They share every job and script with the tested one; what only they take is the
form without a license hostname (the `gtcustomers` variants, run once against the
development license server from a copy with its address) and, for GT before v2024,
`get_core_demand.py` and the older properties files, which no test here starts.
