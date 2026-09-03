# Script Submitter

Runs a user-supplied script on a compute cluster over SSH, either directly on
the login node or submitted through SLURM/PBS. It works standalone (with its
own input form) but its main role in this repo is as the shared **subworkflow**
every endpoint workflow submits its service script through
(`uses: github/parallelworks/workflows@canary` with
`$yaml: workflows/script_submitter/v3.6/<variant>.yaml`).

Full documentation — submission modes, monitoring, cleanup scripts,
`skip_cleanups_file`, subworkflow examples: [v3.6/README.md](v3.6/README.md).

## Versioning

Unlike the rest of this repo, each version keeps its own directory (`v3.6/`)
because marketplace registrations and callers reference the path directly. A
new directory is only created for breaking, non-backward-compatible changes.
Always use the latest version in new workflows.
