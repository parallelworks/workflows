# Signing users in with ACTIVATE (OIDC)

The platform is an OpenID Connect provider: an app served from an endpoint can let
visitors sign in with their ACTIVATE account instead of its own passwords. This file is
the recipe, the claims, what the session proxy does to the sign-in and how far it can be
tested without a browser. Worked example: `workflows/openproject` (the app's own OIDC
client, configured from env); everything here was verified building it (2026-10-20).
The endpoint mechanics it builds on (`pw endpoints run`, `--subdomain`, the tokens the
wrapped command receives) are in [activate-platform.md](activate-platform.md) §10.

- **Register the app once per URL.** An org admin with the `oidcApps` preview
  (`pw api -X POST previews/oidcApps` turns it on) runs
  `pw api -X POST organizations/<org>/oidc/apps --input body.json`: kind `web` (a
  server-side client with a secret; `spa`/`native` must use PKCE), `consent: none` for
  the org's own tool, `subjectType: username`, scopes `openid profile email` (`groups`
  only when listed), `redirectUris: ["https://<label>.<sessions domain>/<callback>"]`,
  `postLogoutRedirectUris`. `.../apps/<clientId>/secrets` prints the secret once (an admin
  can reveal it again). The redirect URI is matched exactly, so the workflow **pins its
  subdomain** (`--subdomain <label>`, reserved with `pw subdomains reserve`) with a
  stable default such as `<service>-${PW_USER}`; the app's URL is only known inside
  `pw endpoints run` (`PW_ENDPOINT_HOST`), so the launcher writes the app's host name and
  issuer settings, never the start template.
- **Endpoints and claims.** Discovery
  `https://<platform host>/api/oidc/.well-known/openid-configuration`; issuer
  `https://<host>/api/oidc` with `/authorize`, `/token`, `/userinfo`, `/end_session`, JWKS
  at `/api/platform/keys`. Claims: `sub`, `name`, `preferred_username`, `email`, `groups`;
  no given or family name, so an app that needs a last name asks the user once. Map the
  app's login to `preferred_username`.
- **The session proxy works against the sign-in; put a proxy of your own in front of the
  app** (nginx in a SIF, Apache in a Docker image) and let it fix two things:
  1. the proxy forwards `X-Forwarded-Proto: http`, under which an app in HTTPS mode
     redirects every page to itself and drops its Secure session cookie; yours sets
     `X-Forwarded-Proto: https`;
  2. the proxy rewrites every redirect to another host onto the session's own host
     (`meproxy.go` `rewriteLocationHeader`), so the app's `302` to `/api/oidc/authorize`
     never leaves the app; yours intercepts an external 3xx
     (`proxy_intercept_errors on; error_page 301 302 303 307 308 = @hop;`) and answers
     a 200 page with `<meta http-equiv="refresh" content="0;url=$upstream_http_location">`
     (re-add `$upstream_http_set_cookie`; re-issue same-host redirects unchanged).
  A third one is fixed by a flag, not a proxy: the platform's embedded session view
  (`/sessions/<user>/<name>`) is an iframe on another site, the browser withholds the
  platform cookie from it and `/authorize` answers `login_required`, so pass
  `--new-tab` to `pw endpoints run` (pw 7.136.0 and later) and the session opens in a
  browser tab of its own. Probe `pw endpoints run --help` for the flag first and warn
  on an older client, which rejects unknown flags (`workflows/gitlab/lib/start.sh`,
  verified 2026-11-09).
- **The client ID and secret are account variables, not form inputs.** The user saves
  them under Account → Variables (`pw variables -k NAME`, secret by default;
  `--public` for the ID) and the YAML reads `${{ var.NAME }}`. A **secret** variable
  renders empty unless the workflow declares it under the top-level
  `needs.userVariables` (`NAME: {hint: why}`, or a plain list), which is also what the
  platform asks the user to grant on the first launch (`pw workflows run --trust`
  grants without prompting); a public one renders without the declaration. An unset
  or ungranted variable renders empty and the run goes on, so the controller checks
  the pair itself and names the variable that is missing (`workflows/gitlab`,
  verified 2026-11-09).
- **What the proxy gives every app:** `Authorization` and the platform cookie are
  stripped; `X-Pw-User` (the visitor's username) and `X-Pw-User-Token` are added, enough
  for an app that trusts headers, without OIDC.
- **Testing without a browser.** `curl -H "Authorization: Bearer $(pw auth token
  --print)"` drives the app through the endpoint up to its redirect (or hop page) to
  `/api/oidc/authorize`: check `client_id`, `redirect_uri` and `scope` there. The
  authorize endpoint itself wants a browser session (a bearer key is "signed out"), and
  an unregistered `redirect_uri` answers 400, which is how to check a registration. The
  code exchange and the user creation need the user's click, in a top-level tab.

