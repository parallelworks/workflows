# GitLab

Runs a self-hosted [GitLab](https://about.gitlab.com/) (repositories, merge requests,
issues, CI/CD) on a cluster's node in Docker and serves it as a `pw` endpoint on a fixed
subdomain. Users can sign in with their ACTIVATE account, and the workflow registers
CI/CD runners that run pipelines on the cluster: on the service host, and through the
SLURM scheduler with [Jacamar CI](https://gitlab.com/ecp-ci/jacamar-ci).

```
form ──► preprocessing ──► start script ──► GitLab ──► https://<subdomain>.<sessions domain>/
         (checks, runner    (container,     answers      the run completes; GitLab and its
          tools)             runners)       /users/sign_in   runners run until you delete the endpoint
```

The first start of a run directory takes about five minutes (GitLab configures itself
and creates its database); later starts two to three. The run completes when the
sign-in page answers; the service outlives the run until
`pw endpoints delete gitlab-<run-slug>`, which also stops the runners.

## Requirements

- Docker on the service host, directly or through `sudo`, with about 5 GB for the image
  and 4 GB of RAM free for GitLab (8 GB recommended). GitLab's Linux package runs as root
  with its own init system, which is why there is no Singularity runtime.
- A platform with session subdomains (GitLab serves at the root of its address).
- For the SLURM runner: `sbatch`, `squeue`, `scancel` and `sacct` on the service host, and
  SLURM accounting on (Jacamar reads every job's final state from `sacct`; the
  controller refuses the runner on a cluster without `AccountingStorageType`).

## Signing in

The first login is `root` with the password of the form, or the one the workflow
generated into `<run directory>/.root_password` (mode 600) when the form left it empty.
The root password only applies when the database is created; change it in GitLab
afterwards.

### Sign in with ACTIVATE

GitLab's OpenID Connect provider is in every edition, so this needs no license.

1. **Pick the address, then register an application for it** (organization admin,
   once). An application is registered for one exact redirect URI, which is built from
   the GitLab address the form's **Subdomain** decides:
   `https://<subdomain>.<sessions domain>/users/auth/openid_connect/callback`. With the
   default subdomain on activate.parallel.works that is
   `https://gitlab-<user>.activate.pw/users/auth/openid_connect/callback`; on
   activate.hpc.mil the sessions domain is `pw.hsp.mil`.

   Turn on the *OIDC Applications* preview in your account settings, open
   Organization → Settings → Applications and add a **web** application with that
   redirect URI. You get the client ID at once and the client secret when you create
   one (shown a single time; an admin can reveal it again). The same through the API:

   ```bash
   pw api -X POST organizations/<org>/oidc/apps --input - <<'EOF'
   {"name": "GitLab", "kind": "web", "consent": "none", "subjectType": "username",
    "scopes": ["openid", "profile", "email"],
    "redirectUris": ["https://<subdomain>.<sessions domain>/users/auth/openid_connect/callback"],
    "postLogoutRedirectUris": ["https://<subdomain>.<sessions domain>/"]}
   EOF
   pw api -X POST organizations/<org>/oidc/apps/<clientId>/secrets
   ```

   Reserve the subdomain too, so nobody else takes it: `pw subdomains reserve <label>`.
2. **Launch** with the client ID and the client secret in the *Sign in with ACTIVATE*
   group. GitLab's login page gets an **ACTIVATE** button; a first sign-in creates the
   GitLab account (username = ACTIVATE username, email from the account). With **New
   users wait for approval** on, such an account stays blocked until an administrator
   approves it under Admin → Users.
3. Open GitLab **in its own tab** (`https://<subdomain>.<sessions domain>/`). Inside the
   platform's embedded session view the sign-in cannot complete.

The provider is part of GitLab's configuration: a later run without a client ID removes
the button, and the accounts it created stay.

## CI/CD runners

The workflow registers instance runners with the GitLab it started and runs them on
the service host as your user, from `<run directory>/runner/` (configuration, builds,
cache, `runner.log`). Their tokens are kept there too, so a later run on the same run
directory finds its runners again.

| Runner | Executor | Jobs | What runs where |
|---|---|---|---|
| **shell** (tag `shell`, takes untagged jobs) | GitLab's shell executor | any | the whole job on the service host, as your user |
| **SLURM** (tag `slurm`) | GitLab's custom executor with Jacamar CI | `tags: [slurm]` | `before_script` + `script` inside an `sbatch` job submitted as your user; sources, artifacts and `after_script` on the service host |

A SLURM job passes its `sbatch` options in the `SCHEDULER_PARAMETERS` variable (`-o`,
`-e`, `-J` and `--wait` are Jacamar's) and must carry the `CI_JOB_JWT` id token Jacamar
reads, which a `default:` block gives every job of the project. Set a wall time:
GitLab's job timeout keeps counting while the job waits in the queue.

```yaml
default:
  id_tokens:
    CI_JOB_JWT:
      aud: $CI_SERVER_URL

hello-slurm:
  tags: [slurm]
  variables:
    SCHEDULER_PARAMETERS: "--nodes=1 --partition=debug --time=00:10:00"
  script:
    - echo "SLURM job $SLURM_JOB_ID on $SLURM_NODELIST"
    - srun hostname
```

With **Create the hpc-ci-demo project** on, the first run creates the private project
`root/hpc-ci-demo` with a pipeline of exactly these jobs, so a fresh GitLab shows a
pipeline that ran on the cluster.

## Git from the command line

The endpoint serves GitLab's pages behind the platform's sign-in, which `git` cannot
pass, so clones and pushes do not go through `https://<subdomain>.<sessions domain>`.
They go to GitLab's ports on the service host instead:

- **From the cluster** (a terminal, JupyterLab or any session on it):
  `git clone http://localhost:<HTTP port>/<group>/<project>.git`. The HTTP port is the
  one `pw endpoints run` assigned; the run's log prints it, and so does
  `ss -ltnp | grep docker-proxy` on the host.
- **From your machine:** open a tunnel first, then clone through it:

  ```bash
  pw forward -L 2222:localhost:2222 <cluster>      # the form's SSH port
  git clone ssh://git@localhost:2222/<group>/<project>.git
  ```

  Add your public key to GitLab first (Profile → SSH Keys). The HTTP port works the same
  way with your GitLab password or a personal access token.

The runners talk to GitLab over the host's loopback as well, so pipelines need no
tunnel.

## License

| Image | What you get |
|---|---|
| `gitlab/gitlab-ee:<version>-ee.0` (default) | the Free tier without a license; Premium or Ultimate features with one |
| `gitlab/gitlab-ce:<version>-ce.0` | the MIT-licensed Community Edition; takes no license |

Paste a license key (`.gitlab-license` contents: a Premium or Ultimate subscription, or
a trial from GitLab's site) into **GitLab license**; the workflow applies it once and
remembers it in the run directory (`.license-*` markers). Later runs may leave the field
empty; a different key replaces the current one. Sign in with ACTIVATE and the runners
need no license.

## Form

| Field | Default | Notes |
|---|---|---|
| Subdomain | `gitlab-<username>` | Decides the address, the clone URLs and the OIDC redirect URI. Reserve it with `pw subdomains reserve <label>` |
| Run directory | `${HOME}/gitlab` | `config/`, `data/`, `logs/` (written as root by Docker), `runner/` (yours) and the generated secrets. One GitLab at a time |
| GitLab image | `gitlab/gitlab-ee:19.5.1-ee.0` | Change the tag one minor version at a time on an existing run directory (GitLab's upgrade path) |
| Root password | empty | Applied on the first start only; empty generates one into `<run directory>/.root_password` |
| SSH port | `2222` | Loopback port of GitLab's SSH on the service host, shown in GitLab's SSH clone URLs |
| GitLab license | empty | See above |
| Register a shell runner | on | |
| Register a SLURM runner | off | Shown on SLURM clusters |
| Create the hpc-ci-demo project | on | Created once, under root |
| Client ID / Client secret | empty | Sign in with ACTIVATE; both or neither |
| New users wait for approval | off | Shown with a client ID |

## Teardown

`pw endpoints delete gitlab-<run-slug>` stops the container and the runners (through
the start script's cleanup, which `docker rm -f`s the container and kills the runner's
session). The run directory keeps everything; its `config/`, `data/` and `logs/`
belong to root, so removing it needs `sudo rm -rf`.

## On activate.hpc.mil

Launch `yamls/hsp.yaml` on a cloud cluster whose node has Docker. The sessions domain
is `pw.hsp.mil`, so the application is registered for
`https://<subdomain>.pw.hsp.mil/users/auth/openid_connect/callback` by an organization
admin of that platform, and the subdomain reserved there.
