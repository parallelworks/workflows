# OpenProject

[OpenProject](https://www.openproject.org/) project management (work packages, boards,
Gantt, wiki, meetings, time tracking) served through a `pw` endpoint named
`openproject-<run-slug>` on a **pinned subdomain**, with **Sign in with ACTIVATE**
through the platform's OpenID Connect provider. Two runtimes, chosen with **Run
container using**: **Singularity** (default) runs everything as your user from one
prebuilt SIF; **Docker** runs the official all-in-one image as root. The run completes
once OpenProject's login page answers; the service runs until
`pw endpoints delete openproject-<run-slug>`.

## How it works

Both runtimes pin the endpoint's subdomain (default `openproject-<your username>`, so
the URL is the same on every run) and probe `/login` before the run completes. The
platform proxy forwards `X-Forwarded-Proto: http`, under which OpenProject's HTTPS mode
redirects every page to itself and drops its Secure session cookie, so each runtime puts
a proxy in front of the app that sets `X-Forwarded-Proto: https`.

- **Singularity** (`openproject-singularity/`): `controller.sh` pulls
  `ghcr.io/parallelworks/openproject:17.0` (the official `openproject/openproject:17-slim`
  image plus PostgreSQL 17 and nginx from Debian, built from `openproject.def` with
  `build-container.sh`) into `<install dir>/containers/`. `start-template.sh` runs, as
  your user and from that one image, PostgreSQL on a loopback port (data in the run
  directory, a generated password), the seeder (schema, migrations, seed data, the OIDC
  provider), puma, the `good_job` worker and nginx on the endpoint port; PID files and
  `cancel.sh` stop them. No root, no Docker daemon; the image's writable paths are bound
  from the run directory. A node that cannot mount SIF images gets a sandbox unpacked once.
- **Docker** (`openproject-docker/`): `start-template.sh` pulls the image and starts
  `openproject/openproject:17` (web, worker, PostgreSQL, memcached in one container, as
  root) with an Apache vhost (and `mod_headers`) mounted in that sets the header.
  `cancel.sh` removes the container. Needs Docker, directly or through `sudo`.
- With a **Client ID** and **Client secret**, the app gets ACTIVATE as an OpenID
  Connect provider through OpenProject's `OPENPROJECT_OPENID__CONNECT_ACTIVATE_*`
  environment variables (issuer `https://<platform host>/api/oidc`, endpoints from the
  platform's discovery document, scopes `openid profile email`, login mapped from
  `preferred_username`, email from `email`). The image seeds them into the database on
  every boot, so a changed secret takes effect on the next run.

## Sign in with ACTIVATE

1. **Register the application** (an organization administrator, once; the
   **Applications** page is behind the *OIDC Applications* preview):
   Organization → Settings → Applications, or through the API:

   ```bash
   pw api -X POST organizations/<org>/oidc/apps --input - <<'EOF'
   {"name": "OpenProject", "kind": "web", "consent": "none", "subjectType": "username",
    "scopes": ["openid", "profile", "email"],
    "redirectUris": ["https://<subdomain>.<sessions domain>/auth/activate/callback"],
    "postLogoutRedirectUris": ["https://<subdomain>.<sessions domain>/"]}
   EOF
   pw api -X POST organizations/<org>/oidc/apps/<clientId>/secrets   # shown once
   ```

   The redirect URI is matched exactly, so it carries the subdomain the workflow pins:
   `openproject-<username>` by default (`openproject-alvaro.activate.pw` on
   activate.parallel.works), or the form's **Subdomain**. Reserve the label with
   `pw subdomains reserve <label>` so no other user can claim it.
2. **Launch** with the client ID and secret in the *Sign in with ACTIVATE* group.
3. **OpenProject shows SSO buttons only with an active Enterprise edition token**
   (its `sso_auth_providers` feature; Community edition filters every OpenID Connect
   and SAML provider out at login, logging `OmniAuth SSO strategy activate is only
   available for Enterprise Editions`). The provider is configured either way. To
   see the button: start a free trial under Administration → Enterprise edition
   (the token is stored in the database, which the run directory keeps), or paste a
   token into the form's **Enterprise token**, which the launcher imports once.
4. The platform's session proxy rewrites any redirect to another host onto the
   OpenProject host, which would send the browser to `<OpenProject>/api/oidc/authorize`
   instead of the platform. The Singularity runtime's nginx therefore answers such a
   redirect with a small page that navigates to the platform itself; the Docker runtime
   (Apache inside the image) cannot, so Sign in with ACTIVATE needs the Singularity
   runtime until the proxy is fixed.
5. Users sign in with the **ACTIVATE** button on `/login`; a first sign-in creates
   their OpenProject account from the ID token (login = ACTIVATE username). ACTIVATE
   releases `name` but no family name, so OpenProject asks a new user to complete the
   last name once. Sign-out ends the ACTIVATE session too (RP-initiated logout) and
   returns to the OpenProject URL.

## Form options

- **Run container using**: Singularity (default) or Docker, see above. A run directory
  belongs to one runtime: Docker's is written as root and the container's postgres user,
  and the Singularity runtime refuses it.
- **Subdomain** (empty = `openproject-<username>`): the label of the OpenProject URL,
  kept the same on every run. Two OpenProjects of one user (two clusters) need two
  labels, each registered as its own redirect URI.
- **Run directory** (default `${HOME}/openproject`): `pgdata/`, `assets/`, the generated
  secrets; under Singularity also `tmp/`, `log/` (PostgreSQL, puma, worker, nginx and
  seeder logs), `files/`, `run/` (PID files) and `nginx/`. Singularity writes it as your
  user; Docker as root and its `postgres` user, so removing a Docker run directory needs
  `sudo rm -rf`. One run per run directory at a time (a lock file); a second run on the
  same directory fails.
- **Admin password** (optional): seeds the `admin` user when the run directory is first
  initialized (at least 10 characters). Empty keeps OpenProject's default `admin` /
  `admin`, which must be changed at the first login.
- **OpenProject image** (Docker only, default `openproject/openproject:17`): keep the
  major version of an existing run directory; a new major may need the PostgreSQL data
  upgraded first. The Singularity image is pinned in `openproject-singularity/controller.sh`.
- **Enterprise token** (optional): imported once per token into the run directory's
  database.
- **Client ID**, **Client secret**: the registered application; both empty = no
  ACTIVATE sign-in, OpenProject's own accounts only.

## Requirements

Singularity: `singularity`/`apptainer` on the service node (loaded through `module` when
not in the PATH), `python3`, and internet access on the login node for the first pull of
the SIF (about 0.5 GB). Docker: Docker on the service node (directly or through `sudo`)
and internet access there on the first launch (the image is 3.3 GB on disk). Either way
about 4 GB of memory. The first boot of a run directory initializes PostgreSQL and seeds
the database (about two minutes on gcptest); later boots take under a minute.
OpenProject serves at the root of its address, so the endpoint is a subdomain one; on a
platform without session subdomains (`--no-subdomain`) the launchers pass the endpoint
path as `OPENPROJECT_RAILS__RELATIVE__URL__ROOT` (untested).

## Building the Singularity image

```bash
cd workflows/openproject/openproject-singularity
./build-container.sh                       # singularity build --fakeroot from openproject.def
tools/oras/oras push ghcr.io/parallelworks/openproject:17.0 openproject.sif
```

A new tag for a new OpenProject major; keep the package public (anonymous pulls).

## Testing

```bash
python3 tools/tests/run-workflow-test.py workflows/openproject/tests/general/gcptest-singularity.json \
                                         workflows/openproject/tests/general/gcptest-singularity-compute.json \
                                         workflows/openproject/tests/general/gcptest-controller.json
OPENPROJECT_TEST_OIDC_CLIENT_SECRET=... python3 tools/tests/run-workflow-test.py workflows/openproject/tests/general/gcptest-oidc.json
```

The Singularity tests use their own subdomain and run directories (`openproject-alvaro-sif`,
`${HOME}/openproject-sif*`) so they never collide with a running Docker instance; the
second runs the service in a SLURM job on a compute node. The Docker tests use the
defaults; `gcptest-oidc` launches with the application registered for
`openproject-alvaro.activate.pw` and is skipped when the variable is unset;
`gcptest-missing-secret` is the failure path.
