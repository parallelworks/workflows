# OpenProject

[OpenProject](https://www.openproject.org/) project management (work packages, boards,
Gantt, wiki, meetings, time tracking) from the official all-in-one Docker image, served
through a `pw` endpoint named `openproject-<run-slug>` on a **pinned subdomain**, with
**Sign in with ACTIVATE** through the platform's OpenID Connect provider. The run
completes once OpenProject answers; the container runs until
`pw endpoints delete openproject-<run-slug>`.

## How it works

- `app/controller.sh` checks the form's values on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job: pulls the image,
  pins the endpoint's subdomain (default `openproject-<your username>`, so the URL is the
  same on every run), and starts `openproject/openproject:17` (web, worker, PostgreSQL,
  memcached in one container, as root) behind `pw endpoints run`. The launcher waits for
  `/health_checks/default` before handing the container to the endpoint, so a boot
  that fails ends the run with the container's log. `cancel.sh` removes the container.
  The platform proxy forwards `X-Forwarded-Proto: http`, under which OpenProject's HTTPS
  mode redirects every page to itself and drops its Secure session cookie, so the
  launcher mounts an Apache vhost (and `mod_headers`) into the container that sets
  `X-Forwarded-Proto: https` for the app. The run completes once `/login` answers 200.
- With a **Client ID** and **Client secret**, the container gets ACTIVATE as an OpenID
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
4. Users sign in with the **ACTIVATE** button on `/login`; a first sign-in creates
   their OpenProject account from the ID token (login = ACTIVATE username). ACTIVATE
   releases `name` but no family name, so OpenProject asks a new user to complete the
   last name once. Sign-out ends the ACTIVATE session too (RP-initiated logout) and
   returns to the OpenProject URL.

## Form options

- **Subdomain** (empty = `openproject-<username>`): the label of the OpenProject URL,
  kept the same on every run. Two OpenProjects of one user (two clusters) need two
  labels, each registered as its own redirect URI.
- **Run directory** (default `${HOME}/openproject`): `pgdata/`, `assets/`, the generated
  `SECRET_KEY_BASE`. The container writes them as root and its `postgres` user, so
  removing a run directory needs `sudo rm -rf`. One run per run directory at a time
  (a lock file); a second run on the same directory fails.
- **Admin password** (optional): seeds the `admin` user when the run directory is first
  initialized (at least 10 characters). Empty keeps OpenProject's default `admin` /
  `admin`, which must be changed at the first login.
- **OpenProject image** (default `openproject/openproject:17`): keep the major version of
  an existing run directory; a new major may need the PostgreSQL data upgraded first.
- **Enterprise token** (optional): imported once per token into the run directory's
  database.
- **Client ID**, **Client secret**: the registered application; both empty = no
  ACTIVATE sign-in, OpenProject's own accounts only.

## Requirements

Docker on the service node (directly or through `sudo`), internet access there on the
first launch (the image is 3.3 GB on disk), about 4 GB of memory. The first boot of a
run directory initializes PostgreSQL and seeds the database (two to three minutes on
gcptest); later boots take under a minute. OpenProject serves at the root of its
address, so the endpoint is a subdomain one; on a platform without session subdomains
(`--no-subdomain`) the launcher passes the endpoint path as
`OPENPROJECT_RAILS__RELATIVE__URL__ROOT` (untested).

## Testing

```bash
python3 tools/tests/run-workflow-test.py workflows/openproject/tests/general/gcptest-controller.json
OPENPROJECT_TEST_OIDC_CLIENT_SECRET=... python3 tools/tests/run-workflow-test.py workflows/openproject/tests/general/gcptest-oidc.json
```

The second test launches with the application registered for
`openproject-alvaro.activate.pw`; it is skipped when the variable is unset.
