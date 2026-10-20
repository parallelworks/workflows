# OpenProject (official all-in-one image) with ACTIVATE as its OpenID Connect provider

> From `workflows/openproject` (2026-10-20), image `openproject/openproject:17`; its
> `app/start-template.sh` is the working copy. Verified on gcptest (Rocky 9.7, Docker
> through `sudo`).

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
  proxy does **not** send (it forwards `http`): without it every page 301s to itself and
  the `Secure` session cookie is never written (login fails with "The OpenProject
  cookie is missing"). The workflow mounts `/etc/apache2/mods-enabled/headers.load`
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
  (run as `app` in `/app`) imports a token file. Do not work around the gate: it is a
  license restriction.
- **Admin seed:** `OPENPROJECT_SEED_ADMIN_USER_PASSWORD` (+ `_PASSWORD_RESET=false`,
  `_NAME`, `_MAIL`) apply only when the database is first seeded; the default is
  `admin`/`admin` with a forced change (password policy: 10+ characters).
