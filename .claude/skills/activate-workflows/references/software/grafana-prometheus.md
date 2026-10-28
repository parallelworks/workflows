# Grafana + Prometheus (grafana/grafana, prom/prometheus) in Docker

> From `workflows/grafana-prometheus` (2026-10-12), images `grafana/grafana:13.2.3`,
> `prom/prometheus:v3.15.0`, `prom/node-exporter:v1.12.1`,
> `nvidia/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04`; its `app/start-template.sh` is the
> working copy of all of this.

- All three run as any uid (`user: "<uid>:<gid>"`) on user-owned bind mounts: Grafana's
  `/var/lib/grafana` (SQLite `grafana.db`), Prometheus's `/prometheus` (`--storage.tsdb.path`),
  node-exporter nothing. Prometheus takes a lock on its TSDB and refuses a second server;
  Grafana does not, so the start script holds a `flock` on the Run Directory for the stack's
  life and a second run on it fails in seconds with the run that holds it (run summary-jay).
- A subdomain endpoint serves Grafana at the root: `GF_SERVER_SERVE_FROM_SUB_PATH=false`,
  `GF_SERVER_ROOT_URL=${PW_ENDPOINT_URL}` (links only), no proxy. The source's nginx and
  `X-Forwarded-Prefix` machinery went with the session pattern.
- `GF_SECURITY_ADMIN_PASSWORD__FILE` reads the password from a file (compose `secrets`); it
  applies when `grafana.db` is created, later runs keep the database's password.
- `GF_AUTH_ANONYMOUS_ENABLED=true` + `GF_AUTH_ANONYMOUS_ORG_ROLE=Admin`: `GET /`, `/api/search`,
  `/api/dashboards/uid/<uid>` and the datasource proxy answer 200 without a login (the platform
  login gates the endpoint); `/api/user` answers 401 for the anonymous user. The platform
  proxy forwards the probe's `Authorization: Bearer <PW_API_KEY>` and Grafana ignores it on
  these routes; `/api/health` (`{"database":"ok","version":...}`) is unauthenticated, so
  `wait_for_endpoint` probes `path: /api/health` with the default `healthy` and 300 s of budget
  (healthy 15 s after the endpoint registered, warm images).
- Provisioning: `dashboards.yml` (`type: file`, `options.path: /etc/grafana/provisioning/dashboards`)
  beside the dashboard JSONs under `/etc/grafana/provisioning/dashboards`, `datasource.yml`
  with `uid: DS_PROMETHEUS` under `.../datasources`. A dashboard exported from 12.2.1 loads in
  13.2.3 unchanged.
- Host metrics from a container on the compose network, no host port: `pid: host`,
  `/:/host:ro,rslave` and `--path.rootfs=/host --path.procfs=/host/proc --path.sysfs=/host/sys`
  (`node_memory_MemTotal_bytes` matched `free -b` on a cloud cluster); network interfaces are then
  the container's, which `network_mode: host` would fix at the price of a fixed host port.
- Something listening on the host is `host.docker.internal:<port>` from the containers with
  `extra_hosts: ["host.docker.internal:host-gateway"]` (Docker 29 on a cloud cluster).
- A compose file that reserves a GPU (`deploy.resources.reservations.devices`, driver `nvidia`)
  fails on a node without the driver, so dcgm-exporter is a separate `-f docker-compose.gpu.yml`
  added only when `nvidia-smi -L` succeeds and `docker info` lists the `nvidia` runtime
  (the cloud cluster has the runtime and no driver). Prometheus 3 accepts UTF-8 label names, 2.x does
  not: the source's `exported-by` label is `exported_by` here.
- `pw agent start-existing --experimental-prometheus-exporter --experimental-prometheus-exporter-port N`
  (CLI v7.105.0) serves 15 `pw_agent_*` families (CPU, memory, storage of the node) on `[::]:N`.
  Inside a run the agent has no platform credentials (it ignores `PW_API_KEY`; "no platform
  credentials available", "Pool not found" in its log), so it never registers a tunnel, and it
  also starts an SSH server and a proxy on random ports and writes `~/pw/.proxy_port`,
  `~/pw/.proxy_addrs`, `~/pw/.agent_port.<host>`, `~/.ssh/pw_server_id_rsa*`,
  `~/.ssh/pw_server_port*` and `~/.ssh/pw_authorized_keys`; the stale port files did not
  bother the next run's `pw endpoints run`. As a background child of the start script with
  its pid in `cancel.sh` it dies with the endpoint. Off by default.
- `docker compose logs -f grafana` exits when the container stops, so it is the endpoint's
  liveness process; `cancel.sh` runs `compose -p <project> down --remove-orphans` (no compose
  file needed) and kills the agent.
