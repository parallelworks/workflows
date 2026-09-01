# Webshell

A browser terminal ([ttyd](https://github.com/tsl0922/ttyd)) on a cluster's login or
compute node, exposed as a `pw` endpoint.

## Run

```bash
pw workflows run ./workflows/webshell/yamls/general.yaml -i '{"cluster":{"resource":"<cluster>","scheduler":false}}'
```

Set `scheduler: true` to run on a compute node via SLURM/PBS. The session is ready
when `webshell-<run-slug>` appears in `pw endpoints list`.

## Variants

| File | Target |
|---|---|
| `yamls/general.yaml` | standard SLURM/PBS clusters |
| `yamls/noaa.yaml` | NOAA deployments |

## Files

- `controller.sh` — installs ttyd on first run (fetched from the
  `interactive_session` repo's `legacy` tag; needs outbound GitHub access)
- `start-template.sh` — starts ttyd on the allocated port behind `pw endpoints run`
