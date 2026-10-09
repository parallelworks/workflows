# PostgreSQL (official `postgres` image) and pgweb in Docker

> From `workflows/postgres` (2026-10-09), images `postgres:18` and `sosedoff/pgweb:0.17.0`;
> its `app/start-template.sh` and `yamls/general_k8s.yaml` are the working copies.

- **A database is not an endpoint.** `pw endpoints` forwards HTTP only, so the endpoint
  serves a web SQL client (pgweb) and the database itself is reached over TCP: from the
  cluster at `<node>:<port>`, from a laptop through `pw forward -L p:<node>:p <resource>`
  (on Kubernetes, a ClusterIP Service and `kubectl port-forward`).
- **Two servers on one data directory both start.** In a container every postmaster is
  PID 1, so a second container takes the first one's `postmaster.pid` for a stale lock
  of its own, runs crash recovery on the live files and serves them (verified on
  gcpsmall: `database system was interrupted ... automatic recovery in progress`, then
  `ready to accept connections`). Guard the data directory outside the container: the
  start script holds `flock -n -E 75` on `<data_dir>/workflow.lock` for the server's life.
  On Kubernetes use `strategy: Recreate`, or a rolling update starts the new pod on the
  volume before the old one stops.
- **Run it as the workflow user** (`user: "<uid>:<gid>"` in compose, data directory owned
  by that user): the Debian images fake the passwd entry with nss_wrapper, initdb and
  the server run as that uid, and the files stay deletable without sudo. Mode-600
  password files bind-mounted as compose `secrets` are then readable inside.
- **Set `PGDATA` explicitly.** From 18 the image's default is
  `/var/lib/postgresql/<major>/docker` under a `VOLUME /var/lib/postgresql`, and the
  entrypoint refuses to start when it finds data at the pre-18 paths. With an explicit
  `PGDATA` (`/var/lib/postgresql/data/pgdata` on a bind of the data directory) the same
  layout works for every major; `down --volumes` drops the unused anonymous volume.
- **`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` act on an empty data directory
  only.** A reused one keeps the user and password of the run that created it, so a
  changed password only shows up as a client's `password authentication failed`. Check
  the login before the endpoint registers and create a missing database with
  `SELECT format('CREATE DATABASE %I', :'db') WHERE NOT EXISTS (...)\gexec` fed on stdin
  (`psql -c` does not interpolate `:'var'`).
- **The image trusts the loopback.** initdb's `pg_hba.conf` keeps `trust` for `127.0.0.1`
  and `::1` and the entrypoint only appends `host all all all scram-sha-256`, so a
  password check through `psql -h 127.0.0.1` inside the container passes with any
  password (a wrong-password test ran on, run cute-ray), and so does every connection
  through `kubectl port-forward`, which arrives on the pod's loopback (verified with
  `wrong` on k3sgpu, run lenient-crane). `POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256`
  makes a new cluster ask for the password there too (only the in-container Unix socket
  stays `trust`; `pg_isready` still works). A data directory initialized without it
  keeps the trust lines, so check the login against the container's own address,
  `psql -h "$(hostname -i | cut -d" " -f1)"` (the pod IP on Kubernetes).
- **Readiness: `pg_isready -h 127.0.0.1`.** During first initialization the entrypoint
  runs a temporary server on the Unix socket only, so a TCP check only passes for the
  final server. Compose: `healthcheck` with `start_period` and `up --wait`; Kubernetes: a
  `readinessProbe` running the same command.
- **pgweb** (`/usr/bin/pgweb --bind=0.0.0.0 --listen=8081` entrypoint, uid 1000):
  `--passfile=<pgpass>` keeps the password off its command line (pgpass escapes `\` and
  `:`); `--open-retry=N --open-retry-delay=S` waits for a server that is still starting,
  but only a refused connection is retried: a failed login (`Error: authentication
  failed`) or a missing database exits at once. In a pod that crash-loops the container,
  the pod never turns Ready, and a `kubectl wait` on the Deployment times out after 600 s
  with no cause (k3sgpu, run strong-gopher). Wait for the database container alone
  (`containerStatuses[?(@.name=="postgres")].ready`), check the login, then wait for the
  Deployment. `GET /api/connection` answers 200 only while it holds a connection (400 with
  the driver error otherwise), so it is the health route for the whole chain. pgweb has
  no login: publish it on `127.0.0.1` only (compose `ports: "127.0.0.1:${PORT}:8081"`,
  `--bind=127.0.0.1` in a pod), where the endpoint reaches it.
- Give the server more than Docker's 64 MB of `/dev/shm` (`shm_size`, or a memory
  `emptyDir` on Kubernetes): parallel queries allocate dynamic shared memory there.
