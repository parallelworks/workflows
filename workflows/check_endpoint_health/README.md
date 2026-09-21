# check_endpoint_health

Subworkflow that verifies an endpoint is healthy: it takes the endpoint's URL from
`pw endpoints list`, sends an authenticated GET (`Authorization: Bearer ${PW_API_KEY}`),
retries every 5 seconds within a budget, and on failure deletes the endpoint (or only
fails, on Kubernetes) so the calling run ends in error. Every `wait_for_endpoint` job in
this repository ends with it, right after the submitter is cancelled; the workflow, not
the test runner, is responsible for checking that its endpoint is healthy before it exits.

Why the key: an anonymous request only ever gets the platform's `307` login redirect,
whatever the service does. With the run's key the proxy forwards the request and returns
the service's own status: `503` while nothing listens behind a registered tunnel yet, the
app's answer afterwards.

## Usage

```yaml
      - name: Check endpoint health
        uses: github/parallelworks/workflows@canary
        with:
          $yaml: workflows/check_endpoint_health/general.yaml
          endpoint_name: ${{ inputs.service.name }}-${PW_RUN_SLUG}
          host: ${{ inputs.cluster.resource.ip }}
          healthy: '2*|3*'
          budget: 120
```

On Kubernetes omit `host` (the probe runs from the workspace) and pass
`on_failure: fail`; the wait job's failure cancels the log-stream step, whose cleanups
delete the Deployment, and the endpoint deregisters with the sidecar.

## Inputs

| input | default | meaning |
|---|---|---|
| `endpoint_name` | required | name as listed by `pw endpoints list`; shell variables such as `${PW_RUN_SLUG}` are expanded on the probing host |
| `host` | `''` | login-node IP to probe from (`inputs.cluster.resource.ip`); empty probes from the workspace |
| `healthy` | `2*\|3*` | shell `case` pattern the HTTP status must match; `2*\|3*\|401` for services that answer 401 to a bare GET (vLLM with `--api-key`, the kasmweb desktop image) |
| `budget` | `120` | seconds to keep retrying; use minutes when containers, databases or model loads start behind the tunnel |
| `path` | `''` | appended to the listed URL, e.g. `/v1/models` for an API server whose root has no route |
| `max_time` | `20` | per-request timeout in seconds (agent-orchestrator's root runs a discovery fan-out and needs 90) |
| `on_failure` | `delete` | `delete` runs `pw endpoints delete` before failing; `fail` only fails (Kubernetes) |

Path-based endpoints (`--no-subdomain`) are listed as a path; the step prefixes it with
`https://${PW_PLATFORM_HOST}`. Query strings (some slugs carry a password) are stripped
from the log lines, and redirects are logged with their target so an app redirect can be
told from the platform's login page.

## Choosing the criteria for a workflow

- Web UIs: `2*|3*` at the listed URL. Budget 120 s when the tunnel registers after the
  app is ready or the app is light; 300 to 900 s when a SIF conversion, a docker pull, a
  database or a model load happens behind the tunnel (librechat, open-notebook, n8n,
  langflow, rag-service, ollama-openwebui).
- API servers: probe a route that exists (`/v1/models`, `/health`) and accept what a
  healthy server returns to it.
- Verify the choice in the test's step log
  (`pw workflows runs logs <slug> --job wait_for_endpoint`): it prints every status seen
  and the time to the first healthy answer.
