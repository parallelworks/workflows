# H2O

Starts an [H2O-3](https://h2o.ai/platform/h2o-open-source/) node on a compute
cluster and serves its Flow UI through a `pw` endpoint named `h2o-<run-slug>`; the
REST API is at the same address. The run completes once the endpoint answers; H2O
keeps running until `pw endpoints delete h2o-<run-slug>`.

## How it works

1. `app/controller.sh` runs on the login node: downloads the H2O-3 release zip from
   the form's URL and unpacks it under the parent install directory (default
   `${HOME}/pw/software/h2o-<version>`) if missing. It then runs the command that
   loads Java, if any, and downloads a Temurin 17 JRE into
   `<parent install dir>/h2o-jre` when no `java` is on the PATH.
2. `app/start-template.sh` runs on the login node or inside a scheduler job
   (SLURM/PBS, your choice in the form) and launches `java -jar h2o.jar` behind
   `pw endpoints run`. H2O binds its REST API and Flow to the loopback address the
   tunnel forwards to, with a cloud name unique to the run so two H2O nodes on one
   network never join each other. H2O's own logs go to `h2ologs/` in the job directory.

## Form options

- **Download URL**: the H2O-3 release zip;
  `https://h2o-release.s3.amazonaws.com/h2o/latest_stable` points at the newest one.
- **JVM Arguments**: e.g. `-Xmx8g`; H2O takes a quarter of the node's memory by default.
- **Command to load Java**: e.g. `module load java`. H2O-3 supports Java 8 to 17.
  Left empty, the `java` on the PATH is used, or a Temurin 17 JRE is downloaded.
