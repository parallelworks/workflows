# Grafana + Prometheus

[Grafana](https://grafana.com/oss/grafana/) over a [Prometheus](https://prometheus.io/)
server, in Docker on a compute cluster, served through a `pw` endpoint named
`grafana-<run-slug>`. Prometheus scrapes the node that runs the stack
([node-exporter](https://github.com/prometheus/node_exporter): CPU, memory, disks, file
systems), its GPUs when it has them
([dcgm-exporter](https://github.com/NVIDIA/dcgm-exporter), with the GPU dashboard
provisioned), the platform agent's experimental exporter on the login node, and any
scrape targets typed into the form. The run completes once the endpoint answers; the
containers run until `pw endpoints delete grafana-<run-slug>`. Visitors are signed in
anonymously as Admin (the platform login protects the endpoint); the `admin` account
takes the form's **Admin Password**.

## How it works

- `app/controller.sh` checks the form's values on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job: pulls the
  images, writes the Prometheus configuration and runs the stack with Docker Compose
  behind `pw endpoints run`. Grafana, Prometheus and node-exporter run as your user, so
  the data directories belong to you; dcgm-exporter joins the stack when `nvidia-smi`
  sees a GPU and Docker has the NVIDIA runtime. With **Platform Agent Metrics** on and
  the stack on the login node, a second platform agent of your user runs inside the
  endpoint's process tree with `--experimental-prometheus-exporter` on port 9091, and
  Prometheus scrapes it as the `pw-agent` job.
- `app/grafana/provisioning/` holds the Prometheus datasource and the GPU dashboard
  (NVIDIA's DCGM exporter dashboard); it is copied into the Run Directory on every
  start, so a dashboard edited in Grafana is kept in Grafana's database, not there.

## Form options

- **Run Directory** (default `${HOME}/grafana-prometheus`): `data/prometheus/` (the time
  series), `data/grafana/` (users, dashboards, settings), `prometheus/prometheus.yml`
  and `grafana/provisioning/` (generated on every start). Reuse it to keep the metrics
  history and the dashboards; only one run at a time can serve it.
- **Admin Password** (default `changeme`): set when the Run Directory is first
  initialized; later runs keep the current one, which you change in Grafana.
- **Prometheus Retention** (default `15d`): how long the metrics are kept.
- **Platform Agent Metrics** (default on): the platform agent's exporter, login node only.
- **Extra Scrape Targets**: one `host:port` per line, scraped as the `extra` job. A
  service on the host that runs the stack is `host.docker.internal:<port>` from inside
  the containers.
- **Grafana Image** (default `grafana/grafana:13.2.3`), **Prometheus Image** (default
  `prom/prometheus:v3.15.0`). node-exporter and dcgm-exporter are pinned in the YAML.

## Requirements

Docker with the Compose plugin on the service node (directly or through `sudo`), and
internet access there on the first launch. Grafana serves at the root of its address,
so the endpoint must be a subdomain one (the default). Run Directories from the
`grafana-prometheus` workflow have `data/` owned by the images' users; `sudo chown -R`
them to reuse them.
