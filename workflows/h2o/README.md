# H2O

Starts an [H2O-3](https://h2o.ai/platform/h2o-open-source/) node on a compute
cluster and serves its Flow UI through a `pw` endpoint named `h2o-<run-slug>` (the
endpoint opens at `/flow/index.html`; the REST API is at the same address). The run
completes once the endpoint answers; H2O keeps running until
`pw endpoints delete h2o-<run-slug>`.

## How it works

1. `app/controller.sh` runs on the login node: downloads the H2O-3 release zip from
   the form's URL and unpacks it under the parent install directory (default
   `${HOME}/pw/software/h2o-<version>`) if missing. It then runs the command that
   loads Java (if any) and, when no `java` is on the PATH, downloads a Temurin 17
   JRE into `<parent install dir>/h2o-jre`.
2. `app/start-template.sh` runs on the login node or inside a scheduler job
   (SLURM/PBS, your choice in the form) and launches `java -jar h2o.jar` behind
   `pw endpoints run`. H2O binds its REST API and Flow to the loopback address the
   tunnel forwards to, and the cloud name is unique per run, so two H2O nodes on one
   network never join each other. H2O's logs go to `h2ologs/` in the job directory.

## Form options

- **Download URL**: the H2O-3 release zip (`https://h2o-release.s3.amazonaws.com/h2o/latest_stable`
  points at the newest one).
- **JVM Arguments**: e.g. `-Xmx8g`; H2O takes a quarter of the node's memory by default.
- **Command to load Java**: e.g. `module load java`. H2O-3 supports Java 8 to 17.

## Variants

- `general.yaml`: cloud and on-premise SLURM/PBS clusters.
- `hsp.yaml`: HPCMP systems (account, QoS, node type).
- `noaa.yaml`: NOAA RDHPCS systems; the release is staged once in the shared
  per-cluster software directory (`/contrib/pw` on Hera, Mercury and Ursa,
  `/usw/rdhpcs/software/pw` on Gaea) and reused read-only by every user.

## Tests

`tests/<variant>/` holds the recorded end-to-end tests. Run them with
`python3 tools/tests/run-workflow-test.py <test.json>` (see `tools/tests/README.md`).
