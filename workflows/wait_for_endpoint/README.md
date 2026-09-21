# wait_for_endpoint

Subworkflow every endpoint workflow calls once its start script has been submitted. It
polls `pw endpoints list` until `endpoint_name` is listed, probes the endpoint URL with
`Authorization: Bearer ${PW_API_KEY}` until the status matches `healthy` (within
`budget`), then touches `skip_cleanups_file` so the script submitter leaves the service
running. It is two steps, `Wait for endpoint` (poll) and `Check endpoint health`
(probe, then skip file), so the run log shows which phase took the time. If the service
never answers, the job fails **without** touching the skip file:
the caller's submitter step (`early-cancel: any-job-failed`) is cancelled and its normal
cleanup tears the job down (`scancel`/`qdel`/kill); on Kubernetes the log-stream step's
cleanups delete the Deployment.

Why the key: an anonymous request only ever gets the platform's `307` login redirect.
With the run's key the proxy returns the service's own status: `503` while nothing
listens behind a registered tunnel yet, the app's answer afterwards.

## Usage

```yaml
  wait_for_endpoint:
    needs: [preprocessing]
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - name: Wait for endpoint
        early-cancel: any-job-failed
        uses: github/parallelworks/workflows@canary
        with:
          $yaml: workflows/wait_for_endpoint/general.yaml
          endpoint_name: ${{ inputs.service.name }}-${PW_RUN_SLUG}
          host: ${{ inputs.cluster.resource.ip }}
          skip_cleanups_file: ${{ needs.preprocessing.outputs.SKIP_CLEANUP_PATH }}
      - name: Cancel Script Submitter
        uses: parallelworks/cancel-jobs
        with:
          jobs: [session_runner]
```

Kubernetes: keep the `pod.running` marker step first, omit `host` (the probe runs from
the workspace) and `skip_cleanups_file`; there is no submitter to cancel.

## Inputs

| input | default | meaning |
|---|---|---|
| `endpoint_name` | required | name as listed by `pw endpoints list`; `${PW_RUN_SLUG}` expands to the calling run's slug |
| `host` | `''` | login-node IP to probe from; empty probes from the workspace |
| `skip_cleanups_file` | `''` | touched once healthy (the path preprocessing published as `SKIP_CLEANUP_PATH`) |
| `healthy` | `2*\|3*` | shell `case` pattern for the HTTP status; `2*\|3*\|401` where a bare GET answers 401 (vLLM with `--api-key`, the kasmweb desktop image) |
| `budget` | `120` | seconds to keep probing every 5 s once listed; minutes when containers, databases or model loads start behind the tunnel |
| `path` | `''` | appended to the listed URL, e.g. `/v1/models` for an API server with no root route |
| `max_time` | `20` | per-request timeout in seconds |

Path-based endpoints (`--no-subdomain`) are listed as a path; it is prefixed with
`https://${PW_PLATFORM_HOST}`. Query strings are kept out of the log (some slugs carry a
password); redirects are logged with their target. The step log
(`pw workflows runs logs <slug> --job wait_for_endpoint`) shows every status seen and
the time to the first healthy answer, which is how to verify a workflow's `healthy` and
`budget` choice.
