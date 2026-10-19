# tools/ui

Development-time tooling for a page a workflow draws itself, so it looks like the
ACTIVATE platform. The how, the component recipes and the worked example
(`workflows/probe/app/web`) are in
[`.claude/skills/activate-workflows/references/app-ui.md`](../../.claude/skills/activate-workflows/references/app-ui.md).

## `sync-theme.sh`

Vendors the platform's theme contract into a workflow app's web directory: the
`--theme-*` tokens that [`@parallelworks/ui`](https://www.npmjs.com/package/@parallelworks/ui)
(the [foundation](https://github.com/parallelworks/foundation) repo, `packages/ui`)
generates for the default theme in light and dark, and the Geist fonts the platform
renders with.

```bash
bash tools/ui/sync-theme.sh workflows/<name>/app/web                 # the pinned version
bash tools/ui/sync-theme.sh -v latest workflows/<name>/app/web       # or any version
bash tools/ui/sync-theme.sh -s ../foundation/packages/ui/src/styles workflows/<name>/app/web
                                                                     # a local checkout
```

It writes four files, all to commit (about 120 KB, almost all of it the two variable
fonts): `theme.css` (the token block alone; the package's file also holds Tailwind
utilities that need a build), `fonts.css`, `Geist-Variable.woff2` and
`GeistMono-Variable.woff2`. The header of `theme.css` records the version it came from.
It is idempotent: rerun it when the platform's theme changes (the package's
`CHANGELOG.md`) and commit the diff. Needs `curl` and `tar`, or a local checkout.
