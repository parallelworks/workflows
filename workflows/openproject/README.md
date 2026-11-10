# OpenProject

Runs [OpenProject](https://www.openproject.org/) (work packages, boards, Gantt, wiki,
meetings, time tracking) on a cluster and serves it as a `pw` endpoint on a fixed
subdomain. Users can sign in with their ACTIVATE account.

```
form ──► preprocessing ──► start script ──► OpenProject ──► https://<subdomain>.<sessions domain>/
         (checkout,         (PostgreSQL,     answers /login    the run completes; the service
          checks)            app, proxy)                       runs until you delete the endpoint
```

The first login is `admin` / `admin`; OpenProject asks you to change it right away.

## Two ways to run it

| Run container using | What runs | Needs |
|---|---|---|
| **Singularity** (default) | PostgreSQL 17, OpenProject and nginx from one image, `ghcr.io/parallelworks/openproject:17.0`, all as your user | `singularity`/`apptainer`, about 0.5 GB for the image |
| **Docker** | The official all-in-one image `openproject/openproject:17`, as root | Docker (directly or through `sudo`), 3.3 GB for the image |

Both keep the database and attachments in the **Run directory** (`${HOME}/openproject`),
so a later run on the same directory finds its projects and users again. A run
directory belongs to one runtime: Docker writes it as root, Singularity as you.

On a cluster that loses its home directory when it is restarted or re-provisioned, put
the run directory on the persistent mount instead: projects, users and attachments then survive the restart.
After the restart, delete the stale endpoint the dead service left behind and launch again with the same
run directory.

The first start of a run directory takes about two minutes (database setup); later
starts under one.

## Sign in with ACTIVATE

Single sign-on (OIDC) is an **Enterprise edition** feature: OpenProject hides every
sign-on provider unless it holds an Enterprise token. A 14-day free trial is
available at <https://www.openproject.org/enterprise-edition/> under **Get a free
on-premises trial license**. The workflow reads the application's client ID and secret
from two **variables of your ACTIVATE account**; the form has no field for them.

1. **An organization admin registers the OpenProject address as an application**, once
   per address, and shares the client ID and the client secret with you. The
   application is registered for one exact redirect URI, built from the address the
   form's **Subdomain** decides: `https://<subdomain>.<sessions domain>/auth/activate/callback`
   (`https://openproject-<user>.activate.pw/auth/activate/callback` with the default
   subdomain on activate.parallel.works). Launching with another subdomain later means
   registering (or updating) the application for the new address, or the sign-in stops
   at a redirect URI error. In Organization → Settings → Applications (behind the
   *OIDC Applications* preview of the account settings): a **web** application, consent
   none, scopes `openid profile email`, that redirect URI, and
   `https://<subdomain>.<sessions domain>/` as the post-logout redirect URI. The client
   secret is shown once when it is created; an admin can reveal it again. The same
   through the API:

   ```bash
   pw api -X POST organizations/<org>/oidc/apps --input - <<'EOF'
   {"name": "OpenProject", "kind": "web", "consent": "none", "subjectType": "username",
    "scopes": ["openid", "profile", "email"],
    "redirectUris": ["https://<subdomain>.<sessions domain>/auth/activate/callback"],
    "postLogoutRedirectUris": ["https://<subdomain>.<sessions domain>/"]}
   EOF
   pw api -X POST organizations/<org>/oidc/apps/<clientId>/secrets
   ```

2. **Save the two values under Account → Variables**: `OPENPROJECT_CLIENT_ID` with the
   client ID and `OPENPROJECT_CLIENT_SECRET` with the client secret, the **Secret**
   toggle on for the latter. From a terminal: `pw variables --public -k
   OPENPROJECT_CLIENT_ID --value pwapp_...` and `pw variables -k OPENPROJECT_CLIENT_SECRET`
   (it prompts for the value and stores it as a secret). The workflow declares the
   variables it reads, so the platform asks you to grant it the secret on your first
   launch (`--trust` from the CLI).
3. **Launch** with the Enterprise token in the *Sign in with ACTIVATE* group. The token
   is imported once per run directory. Without one OpenProject still starts, with a
   warning in the run's log, and hides the button until a token is active.
4. **Sign in** with the ACTIVATE button on the login page. A first sign-in creates the
   OpenProject account (login = ACTIVATE username) and asks for the last name once.

Two things to know:

- The session opens in a browser tab of its own, where the sign-in completes; inside
  the platform's embedded session view it cannot.
- Use the Singularity runtime for it. The platform proxy rewrites the redirect to the
  sign-in page; the Singularity runtime's nginx works around that, the Docker runtime
  cannot yet.

The provider is written into OpenProject's database on every start and stays there: a
later run by a user without the two variables keeps the stored one (remove it under
Administration → Authentication → OpenID providers).

## Form

| Field | Default | Notes |
|---|---|---|
| Run container using | Singularity | See above |
| Subdomain | `openproject-<username>` | Decides the address, and with it the redirect URI the application must be registered for. Reserve it with `pw subdomains reserve <label>` |
| Run directory | `${HOME}/openproject` | Database, attachments, logs. One run at a time |
| OpenProject image | `openproject/openproject:17` | Docker only. Keep the major version of an existing run directory |
| OpenProject Enterprise token | empty | Imported once per run directory; without an active token OpenProject hides Sign in with ACTIVATE. Bound to the subdomain, has an expiry date |

## Building the Singularity image

```bash
cd workflows/openproject/openproject-singularity
./build-container.sh        # the official slim image plus PostgreSQL 17 and nginx
tools/oras/oras push ghcr.io/parallelworks/openproject:17.0 openproject.sif
```

New OpenProject major, new tag. Keep the package public.
