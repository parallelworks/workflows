# OpenProject (Docker all-in-one image, or the slim image under Singularity) with ACTIVATE as its OpenID Connect provider

> From `workflows/openproject` (2026-10-20): `openproject-docker/start-template.sh` runs
> `openproject/openproject:17` (all-in-one, root); `openproject-singularity/` runs one SIF
> built from `openproject.def` (`openproject/openproject:17-slim` + PostgreSQL 17 + nginx,
> pushed as `ghcr.io/parallelworks/openproject:17.0`) as the user. Verified on gcptest
> (Rocky 9.7, Docker through `sudo`, apptainer 1.4.5).

## Singularity: the slim image runs as any uid

- **The all-in-one image needs root** (supervisord, `su postgres`, `chown`), so it cannot
  run under Apptainer; `openproject/openproject:17-slim` can: Debian 13, `USER app`, an
  entrypoint that only `exec`s, puma via `./docker/prod/web` (`PORT`, `BIND`), the
  worker via `./docker/prod/worker` (`good_job`), `./docker/prod/seeder` (schema load or
  migrate, then `db:seed`), `RAILS_SERVE_STATIC_FILES=1`, cache store `file_store`
  (no memcached needed), and the PostgreSQL 17 client (`psql`, used by `docker/prod/migrate`).
  SIF of the plain image: 381 MB; with `postgresql-17` and `nginx` from apt: 462 MB.
- **Def file** (`openproject-singularity/openproject.def`, `singularity build --fakeroot`,
  about four minutes on gcptest): install `postgresql-common` first and append
  `create_main_cluster = false` to `/etc/postgresql-common/createcluster.conf`, or the
  `postgresql-17` postinst initializes a cluster in the image. `nginx` from apt is 1.26.
- **Writable paths** bound from the run directory: `/app/tmp` (pids, file cache),
  `/app/log`, `/app/files`, `/var/openproject/assets` (attachments); plus
  `--writable-tmpfs` for the rest (nginx's compiled-in `/var/log/nginx`). Run with
  `--cleanenv`, the app's variables exported as `APPTAINERENV_*`/`SINGULARITYENV_*` with
  `$`, backticks and backslashes escaped (pitfalls, "Passing secrets and values with
  spaces into Apptainer"; an `--env-file` broke on the OIDC scope's spaces): host module
  environments (`LD_LIBRARY_PATH`, `GEM_*`) must not reach Ruby, and `pw endpoints run`
  exports `PORT`, which the web process must get as its own value (`--env PORT=<puma port>`).
- **PostgreSQL as the user:** `initdb -D <rundir>/pgdata -U openproject --auth-host=scram-sha-256
  --auth-local=trust --pwfile=<file>` then `postgres -D ... -p <port> -c listen_addresses=127.0.0.1
  -c unix_socket_directories=/tmp`; `pg_isready`/`psql -h 127.0.0.1`. The loopback is
  shared with every user of the login node, hence the password, carried in
  `DATABASE_URL=postgres://openproject:<pw>@127.0.0.1:<port>/openproject`. Keep the URL
  free of `?options`: `docker/prod/migrate` cuts it at `?` before handing it to `psql`.
  Measured: seeder 54 s on a fresh database, puma answering 42 s later.
- **nginx unprivileged** (it also sets `X-Forwarded-Proto` and serves the hop page for the
  OIDC redirect, [oidc-sign-in.md](oidc-sign-in.md)): a full `nginx.conf` passed with `-p <dir> -c <conf>` and every
  path inside the run directory (`pid`, `error_log`, `access_log`, `client_body_temp_path`,
  `proxy_temp_path`, `fastcgi_temp_path`, `uwsgi_temp_path`, `scgi_temp_path`), `listen
  127.0.0.1:$PORT`, `proxy_set_header X-Forwarded-Proto https`, `-g 'daemon off;'` as the
  launcher's foreground process (its exit ends the endpoint). Every service is started
  with `setsid nohup singularity exec … &` so its PID file holds a process group, and
  `cancel.sh` signals the groups (TERM for nginx/worker/puma, INT for PostgreSQL, KILL
  after 30 s): a TERM to the bare starter PID left `good_job` running (pitfalls). Keep
  nginx's own `pid` directive away from that group file: pointed at the same path, nginx
  overwrote the PGID with its master PID, the health loop took nginx for dead and
  `cancel.sh` could no longer reach it.

- **One container, as root.** The all-in-one image runs PostgreSQL, memcached, Apache
  (port 80), puma, the worker and cron under supervisord; its entrypoint needs uid 0.
  Bind `pgdata/` to `/var/openproject/pgdata` and `assets/` to `/var/openproject/assets`;
  both end up owned by root and the container's `postgres` user, so a run directory is
  removed with `sudo rm -rf`. First boot of a run directory (initdb, migrate, seed) took
  ~90 s on a 16-core login node; later boots under a minute. 3.3 GB of image on disk.
- **Every boot runs `rake db:seed`** (`docker/prod/supervisord` → `seeder --skip-migrate`),
  so `OPENPROJECT_SEED_*` and `OPENPROJECT_OPENID__CONNECT_*` env vars are applied on
  each start: a changed OIDC secret takes effect on the next run. `SECRET_KEY_BASE` must
  be strong (`openssl rand -hex 64`) and the same on every start; generate it once into
  the run directory. `OPENPROJECT_HOST__NAME` is the public host the browser sees and
  `OPENPROJECT_HTTPS=true` (default) needs `X-Forwarded-Proto: https`, which the endpoint
  proxy does not send ([oidc-sign-in.md](oidc-sign-in.md)). The Docker
  runtime mounts `/etc/apache2/mods-enabled/headers.load`
  (`LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so`, shipped but
  not enabled) and its own `/etc/apache2/sites-enabled/openproject.conf` (the image's
  `proxy.conf.erb` plus `RequestHeader set X-Forwarded-Proto "https"`; `docker/prod/proxy`
  keeps an existing file) read-write, because the entrypoint `chown`s the vhost.
  `GET /health_checks/default` answers 200 once puma serves (no auth, no SSL redirect);
  `/login` is the probe that proves the header fix; `/` is 302 to `/login`.
- **OIDC provider from env** (`modules/openid_connect/app/services/openid_connect/configuration_mapper.rb`):
  `OPENPROJECT_OPENID__CONNECT_<SLUG>_{DISPLAY__NAME,IDENTIFIER,SECRET,ISSUER,
  AUTHORIZATION__ENDPOINT,TOKEN__ENDPOINT,USERINFO__ENDPOINT,END__SESSION__ENDPOINT,
  JWKS__URI,SCOPE,POST__LOGOUT__REDIRECT__URI,LIMIT__SELF__REGISTRATION,SYNC__GROUPS,
  GROUPS__CLAIM,ATTRIBUTE__MAP_{LOGIN,EMAIL,FIRST__NAME,LAST__NAME,ADMIN}}`. The slug is
  the segment after `OPENID__CONNECT_`, lowercased; the callback is
  `https://<host>/auth/<slug>/callback` and it must be registered exactly on the
  ACTIVATE application. No discovery URL from env: pass the endpoints (ACTIVATE's are
  `https://<platform host>/api/oidc/{authorize,token,userinfo,end_session}`, JWKS
  `/api/platform/keys`). Check the seeded row with
  `docker exec -u app -w /app <c> bundle exec rails runner 'p OpenIDConnect::Provider.all.map(&:to_h)'`.
  ACTIVATE releases `name` but no `given_name`/`family_name`, so a new user is asked for
  the last name once (`firstname: info[:first_name] || info[:name]`).
- **SSO is Enterprise-gated at login, not only in the admin UI:**
  `auth_plugin.rb#filtered_strategy?` keeps a provider only when
  `EnterpriseToken.allows_to?(:sso_auth_providers)` (the `developer` strategy excepted);
  without a token `/auth/<slug>` is 404, `/login` shows no button, and the log says
  `OmniAuth SSO strategy <slug> is only available for Enterprise Editions`. The provider
  row is still created and `available`. A trial token requested in Administration →
  Enterprise edition is stored in the database; `script/import_enterprise_token <file>`
  (run as `app` in `/app`) imports a token file (prints subscriber, domain, plan, validity;
  the domain must equal `Setting.host_name`). Verified 2026-10-20 with a trial token:
  the running puma honoured it within about 15 s, no restart needed (`supervisorctl`
  in the all-in-one image has no control section anyway). Probe the result with
  `EnterpriseToken.allows_to?(:sso_auth_providers)` (`EnterpriseToken.current` no
  longer exists in 17). The login page's button links to `/login/omniauth/<slug>`;
  OmniAuth 2 answers a plain `GET /auth/<slug>` with 404 whether or not SSO is
  enabled, so that route proves nothing. Do not work around the gate: it is a
  license restriction.
- **Admin seed:** `OPENPROJECT_SEED_ADMIN_USER_PASSWORD` (+ `_PASSWORD_RESET=false`,
  `_NAME`, `_MAIL`) apply only when the database is first seeded; the default is
  `admin`/`admin` with a forced change (password policy: 10+ characters).
