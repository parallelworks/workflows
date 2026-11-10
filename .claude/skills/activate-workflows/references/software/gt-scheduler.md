# GT-SUITE distributed scheduler (`workflows/start_gt_scheduler`)

What running it taught that its README and scripts do not say (GT v2026 on Rocky 9,
2026-11-10).

- **`systemctl stop gtdistd.service` leaves the unit `failed`**, not `inactive`: java
  exits 143 on the TERM. A leftover check tests for `active`.
- **The daemon's log is `/var/opt/gtsuite/gtdistd/log/gtdistd.log.0`.** An executor
  that reached the scheduler shows there as `Connected to SatelliteClientContext[...]`.
- **A minimum core demand tests the executor path without a GT job**: with
  `adv_pw.min_core_demand` at one node's cores and nothing queued, the loop submits
  one executor.
- **`lmutil` does not run on the controller** (no loader for it on Rocky 9). Check a
  forwarded license port by connecting to it: closed at once means the tunnel is up
  and nothing listens at the far end.
