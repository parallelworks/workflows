# GT-SUITE distributed scheduler (`workflows/start_gt_scheduler`)

What running it on a PW cloud SLURM cluster taught (cloud.parallel.works, 2026-11-10,
GT v2026 on Rocky 9). The workflow's README describes what it does; this is what to
know before changing or debugging it.

- **Where things answer.** The scheduler daemon (`gtdistd`, a systemd unit the
  workflow rewrites on every start) serves its jobs as XML on the controller's private
  address, `http://<private ip>:8979/jobs/?xml`: that is the sensing loop's input and a
  quick health check. Its own log is `/var/opt/gtsuite/gtdistd/log/gtdistd.log.0`
  (`/tmp/gtdistd.out` only has the start-up); an executor that reached the scheduler
  shows there as `Connected to SatelliteClientContext[...]`, about 3 s after the
  executor's daemon started. There is no `/executors` route.
- **`systemctl stop gtdistd.service` leaves the unit `failed`**, not `inactive`: java
  exits 143 on the TERM. `failed` is the stopped state; a leftover check tests for
  `active`.
- **The first sensing cycle is the evidence.** A `CORE SUPPLY:` line in the loop's
  `logs.out` means the balance query through the workspace, the daemon's XML and the
  SLURM queries all worked. With a 15 s cycle it appears about 40 s after the launch.
- **A minimum core demand tests the executor path without a GT job.** With
  `adv_pw.min_core_demand: 24` and nothing queued, the loop submits one executor job to a
  24-core partition; the node took 4 min to boot (`CF`). The executor template gives up
  after 600 s without a simulation, so a run left like that keeps replacing its
  executor; the cancel's `scancel -u` ends it.
- **The license server only admits the user workspace** (port 22 from the controller
  is filtered, from the workspace it is open), which is why every job of the workflow
  runs in the workspace and the license tunnel jumps through it. From the controller, a
  connection to a forwarded license port that is closed at once means nothing listens
  at the far end, the tunnel being up; one that stays open reached the license daemon.
  `lmutil` under `GTsuite/bin/linux_x86_64` does not run on the controller (no loader
  for it on Rocky 9), so it cannot make that check.
- **The scheduler gives up on the balance after ten attempts, 20 s apart.** Anything
  that restores its way to the workspace has 200 s: the workflow's monitor checks every
  90 s, and a reverse tunnel killed by hand was back, with the license tunnel, after
  three failed attempts.
- **`scancel -u` at teardown takes every SLURM job of the user on the cluster**, not
  only the executors. It is the source's behaviour and the README says so.
- **`gt-scheduler` is a name, not an identity.** Two runs can each have had a session
  of that name on one controller: launched a second apart (one is refused at the
  launch lock), or a new run started within the eight minutes an old one takes to
  notice its session died. Each run records the id `screen` gave its own session
  (`<pid>.gt-scheduler`) and `app/controller/session.sh` answers from it, so the
  refused or dead run stops nothing of the other's. Both cases were run: the other
  run kept its session, its key on the license server and its SLURM queue.
- **One reverse tunnel serves whoever is on the controller.** Port 2222 there can be
  bound once, so a run that finds the tunnel up uses it, and loses it when the run
  that opened it ends. Its monitor then opens its own: in the two-launches case the
  surviving scheduler failed four of its ten balance attempts first.
