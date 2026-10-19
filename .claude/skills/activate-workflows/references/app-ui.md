# The UI of a workflow's own web app

A workflow that serves a page it draws itself (PROBE's dashboards, a study viewer, a
small form or report) makes that page look like the ACTIVATE platform: the same colors
in light and dark, the same type, the same buttons, badges, tables, tabs and drawers,
the same icons. A third-party app a workflow serves (JupyterLab, Grafana, code-server,
...) keeps its own UI; this file is about pages this repository draws. The worked
example is `workflows/probe/app/web/`.

## Where the platform's look is defined

The [foundation](https://github.com/parallelworks/foundation) repository holds the
shared code the platform's web UI is built from. Its `packages/ui` is published as
[`@parallelworks/ui`](https://www.npmjs.com/package/@parallelworks/ui): React components
(Tailwind v4, Base UI) built on **one theme contract**. Clone it beside this repository
(`git clone https://github.com/parallelworks/foundation ../foundation`) or read it on
GitHub; the npm tarball holds only the built `dist/`, which is what
`tools/ui/sync-theme.sh` fetches.

| Read | For |
|---|---|
| `packages/ui/README.md` | the package's contract: **Which component?** (one component per need), **Themes** (how the tokens are generated, what each line and status token is for), **Buttons and spinners**, **Icons**, **Host chrome** (the `--layer-*` stacking scale) |
| `packages/ui/src/styles/theme.css` | the default theme's tokens for both modes, between the `generated:start` and `generated:end` markers; the font stack (`--font-sans`, `--font-mono`) sits outside them in a Tailwind `@theme` block, so a page defines its own two variables (PROBE's `styles.css` does) |
| `packages/ui/src/styles/base.css` | the page defaults: body font and colors, `border-color` on every element, the stacking scale |
| `packages/ui/src/theme/model.ts` | the presets; `navy` is the platform's default (light: base `#f3f4f6`, accent `#06354f`; dark: base `#111418`, accent `#5b9ccf`) |
| `packages/ui/src/components/<Component>.tsx` | a component's classes are its recipe: `buttonClasses.ts`, `fieldBox.ts`, `tone.ts`, `StatusBadge.tsx`, `RunStatusIcon.tsx`, `Table.tsx`, `Tabs.tsx`, `Section.tsx`, `Drawer.tsx`, `DescriptionList.tsx`, `Callout.tsx`, `EmptyState.tsx`, `PageHeader.tsx`, `floating.ts` (popups, tooltips) |
| `packages/ui/src/icons.tsx` | every interface icon, one path on a 16px grid, named by meaning |
| `pnpm storybook` in `packages/ui` | every component rendered on the compiled stylesheet; the toolbar picks the theme and the mode |

**The contract.** Every color a component may use is one of a closed set of `--theme-*`
CSS variables, generated from a seed (a base color, an accent, a contrast) per mode;
components read only tokens and never branch on light or dark. `theme.css` ships the
default theme's tokens as `light-dark(<light>, <dark>)` pairs, so a page follows the
`color-scheme` its root sets. The platform's type is Geist Sans and Geist Mono. Status
colors keep fixed hues in every theme and come in four tokens each, because a red icon
must stay bright while red words must stay readable:

| Token | For |
|---|---|
| `--theme-app-bg`, `--theme-panel-bg`, `--theme-panel-hover`, `--theme-muted-panel-bg`, `--theme-hover`, `--theme-input-bg`, `--theme-input-disabled-bg` | surfaces: the page, cards and tables and drawers, a hovered row, a table's header row and a ghost button's hover, a hover, a field |
| `--theme-app`, `--theme-muted-text-color`, `--theme-placeholder`, `--theme-link` | text: body, secondary, placeholders, links and the current tab |
| `--theme-border`, `--theme-border-field`, `--theme-border-strong` | lines: decorative (cards, dividers, table lines), a text field's resting edge, a control's edge (a checkbox, a switch's off track) |
| `--theme-accent`, `--theme-accent-text`, `--theme-accent-hover`, `--theme-accent-subtle`, `--theme-focus`, `--theme-focus-ring` | the primary button and the selection, text on it, its hover, a tint, focus indicators and a checked control |
| `--theme-<tone>`, `--theme-<tone>-text`, `--theme-<tone>-solid`, `--theme-<tone>-muted` for `success`, `error`, `warning`, `info`, `favorite` | icons, dots, borders and bars (never words); words; a fill under white text (a danger button); a tint (a badge, a callout) |
| `--theme-shadow-sm`, `--theme-shadow`, `--theme-shadow-lg`, `--theme-shadow-xl` | shadows, a drawer's the largest |
| `--theme-code-*`, `--theme-ansi-*` | code blocks and terminal output |
| `--theme-category-1` to `-8`, each with `-text` | telling things apart without ranking them (an avatar, a group) |

## Two ways to adopt it

### A page with no build step (the default here)

A workflow's page is usually a few static files served by a small server from `app/`
on a login node with no Node.js: plain HTML, CSS and JavaScript. It takes the platform's
look by vendoring the contract and following the recipes.

1. **Vendor the tokens and the fonts** into the page's directory and commit them
   (about 120 KB, almost all of it the two variable fonts):

   ```bash
   bash tools/ui/sync-theme.sh workflows/<name>/app/web          # the pinned @parallelworks/ui version
   bash tools/ui/sync-theme.sh -v latest workflows/<name>/app/web
   bash tools/ui/sync-theme.sh -s ../foundation/packages/ui/src/styles workflows/<name>/app/web
   ```

   It writes `theme.css` (the generated token block only; the rest of the package's
   file is Tailwind that needs a build), `fonts.css` and the two `.woff2` files. The
   header of `theme.css` records the version, and that header is the one place the
   version lives: a plain rerun refreshes the same version, `-v` moves to another. Rerun
   it when the platform's theme changes (the package's `CHANGELOG.md`). Link them before
   the page's own sheet:

   ```html
   <link rel="stylesheet" href="fonts.css">
   <link rel="stylesheet" href="theme.css">
   <link rel="stylesheet" href="styles.css">
   ```

2. **Set the color mode the platform's way.** The tokens are `light-dark()` pairs, so
   the root's `color-scheme` decides: `light dark` follows the device, `light` or `dark`
   pins one. Offer the platform's three choices (light, dark, the device's) from one
   attribute the page's script sets before the first paint, and never swap token values:

   ```css
   :root { color-scheme: light dark; }
   :root[data-theme="light"] { color-scheme: light; }
   :root[data-theme="dark"] { color-scheme: dark; }
   ```

   `light-dark()`, `color-mix()` and subgrid are 2023 to 2024 CSS, the platform's own
   baseline; a browser without them shows the page unstyled in both modes.

3. **Write the page's stylesheet against the tokens alone**: no hex color, no other
   font, and the package's component recipes translated to CSS. Name the component each
   block mirrors, so a change in the package has one place to land. The recipes, from
   the component sources (Tailwind's scale is 0.25rem a unit):

   | Component | Recipe |
   |---|---|
   | Page (`base.css`) | `font-family: "Geist Sans", system-ui, sans-serif`; mono `"Geist Mono", ui-monospace, Menlo, Consolas, monospace`; body `background: var(--theme-app-bg); color: var(--theme-app)`; `*, ::before, ::after { border-color: var(--theme-border) }`; antialiased. Content padding `1rem`. |
   | Page header bar (`PageHeader`) | `3rem` tall, `padding: 0 1rem`, `border-bottom`, the page background; the page pins it (`position: sticky; top: 0; z-index: var(--layer-header)`, which the package leaves to the host); the trail at `0.8125rem`, the page's name its one `h1` at weight 500; the page's commands at the end, `gap: 0.25rem`. |
   | Panel, section card (`panel`, `Section variant="card"`) | `border: 1px solid var(--theme-border); border-radius: 0.75rem; background: var(--theme-panel-bg)`; header `padding: 1rem` (`0.75rem 1rem` dense), title `1rem` weight 600, description `0.875rem` muted. |
   | Button (`buttonClasses`) | `inline-flex; gap: 0.375rem; border-radius: 0.375rem; font-weight: 500; white-space: nowrap`; sizes md `height 2rem; padding 0 0.75rem; font-size 0.875rem` (icon `1rem`), sm `1.75rem / 0 0.625rem / 0.75rem` (icon `0.875rem`), xs `1.5rem / 0 0.5rem / 0.75rem`; icon-only is a square of the height. Variants: **primary** `background accent; color accent-text; hover accent-hover`; **secondary** `border border; background panel-bg; color app; hover background hover`; **outline** `border border; color muted; hover background muted-panel-bg and color app`; **ghost** no border, otherwise outline; **danger** `background error-solid; color white; hover at 90%`. Focus `outline: 2px solid var(--theme-focus); outline-offset: 1px`; disabled `opacity: 0.5; cursor: not-allowed`. A destructive action that confirms on a second press takes the danger look while armed. |
   | Field (`fieldBox`, `Field`) | md `height 2rem; padding 0 0.75rem; font-size 0.875rem`, sm `1.75rem / 0 0.5rem / 0.75rem` for toolbars and table cells; `border: 1px solid var(--theme-border-field); border-radius: 0.375rem; background: var(--theme-input-bg)`; placeholder `--theme-placeholder`; hover `border-color: var(--theme-border-strong)`; focus `border-color: var(--theme-focus); box-shadow: 0 0 0 1px var(--theme-focus)`; invalid `--theme-error`; disabled `background input-disabled-bg; color placeholder`. The label over it, weight 500. A search box carries the search icon at its left. |
   | Switch, checkbox | off track `--theme-border-strong`, on `--theme-focus`, a white knob. |
   | Status badge (`StatusBadge`, `tone.ts`) | `inline-flex; gap 0.375rem; border-radius: 999px; border: 1px solid; font-weight 500`; sm `padding 0.125rem 0.5rem; font-size 0.625rem`, md `0.25rem 0.625rem; 0.75rem`. Tone surface: `background <tone>-muted; color <tone>-text; border-color` the vivid `<tone>` at 25% (`color-mix(in srgb, var(--theme-<tone>) 25%, transparent)`); default `background muted-panel-bg; color app`; muted the same at half opacity with muted text. A dot or icon inside takes the vivid `--theme-<tone>`. |
   | A run's status (`RunStatusIcon`) | running, started: warning tone, `RunningIcon` turning; completed: success, `SuccessIcon`; failed, error: error, `FailIcon`; skipped: muted, `SkipIcon`; canceled: info, `CancelIcon`; not run: muted, `NotRunningIcon`. |
   | Table (`Table`) | header row `background: var(--theme-muted-panel-bg)`, `th { font-size 0.75rem; font-weight 500; text-transform: uppercase; letter-spacing 0.05em; padding 0.5rem 0.75rem }` (sentence case for titles that are identifiers); cells `padding 1rem 0.75rem` comfortable or `0.375rem 0.75rem; font-size 0.875rem` compact, `white-space: nowrap`; rows ruled by `1px var(--theme-border)`; a hovered row `--theme-panel-hover`; alone on the page, in a panel border with a `0.75rem` radius. |
   | Tabs (`Tabs`, line variant) | the row `border-bottom: 1px solid var(--theme-border)`; a tab `padding 0.5rem; font-size 0.875rem; font-weight 600; color muted`, hover app; the current one `color: var(--theme-link)` with a 2px underline in `--theme-link`. |
   | Drawer (`Drawer`) | from the right over a `rgba(0, 0, 0, 0.4)` backdrop at `z-index: var(--layer-drawer)`, `480px` wide by default and never wider than `calc(100% - 2.5rem)`, `background panel-bg; border-left 1px; box-shadow var(--theme-shadow-xl)`, sliding in over 300ms; header `padding 0.75rem 1rem; border-bottom`, title `0.875rem` weight 600, description `0.75rem` muted, a ghost icon button with `CloseIcon` closes; body `padding 1rem; overflow-y: auto`; footer `border-top; padding 0.75rem 1rem; justify-content: flex-end; gap 0.5rem`. Escape and a press outside close it; focus returns. |
   | Description list (`DescriptionList variant="divided"`) | `grid-template-columns: fit-content(40%) minmax(0, 1fr); column-gap 1.5rem`, one column when narrow; rows `padding 0.5rem 0`, ruled; labels muted, values in the body color, `mono` values in the mono face at `0.8125rem`. |
   | Callout (`Callout`) | `display: flex; gap 0.75rem; padding 0.75rem 1rem; border-radius 0.75rem; font-size 0.875rem; line-height 1.25rem` on the tone surface; a `1.25rem` icon in the vivid tone: `InfoIcon`, `SuccessIcon`, `WarningIcon`, `ErrorIcon`. |
   | Empty state (`EmptyState`) | centered; in a panel `padding 3rem 1.5rem`, title `0.875rem` weight 500, description `0.75rem` muted; bare `padding 1.5rem 0.75rem`, muted. |
   | Tooltip (`floating.ts`) | inverted: `background: var(--theme-app); color: var(--theme-app-bg); border-radius 0.375rem; padding 0.25rem 0.5rem; font-size 0.75rem`. |
   | Code (`--theme-code-*`) | `background code-bg; color code-text; font-family mono; font-size 0.75rem; border-radius 0.5rem`; terminal colors from `--theme-ansi-*`. |
   | Loader | `RunningIcon` turning in `--theme-accent` (`animation: spin 1s linear infinite`), none under `prefers-reduced-motion`. |
   | Stacking | `--layer-sticky: 10`, `--layer-header: 20`, `--layer-overlay: 1000`, `--layer-drawer: 1100`, `--layer-modal: 1200`, `--layer-toast: 1300`, `--layer-popover: 1400`, on the root. |

4. **Use the platform's icons, drawn inline.** Copy the path of the icon whose *name*
   means what you show from `packages/ui/src/icons.tsx` (the README's "Icons" section
   says which name means what: `RefreshIcon` reloads data, `RetryIcon` tries again,
   `RunningIcon` is a run in progress, `TrashIcon` deletes a record, ...) into
   `<svg viewBox="0 0 16 16" width="1em" height="1em" fill="none" stroke="currentColor"
   stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="..."/></svg>`:
   `1em` square in the text's color, so a font size or a class sizes it. No other icon
   set, no Unicode glyphs or emoji for status. Draw them inline rather than through
   `<use href="#id">`: a page served under an endpoint prefix sets a `<base>`, and a
   fragment reference resolves against it rather than the page.

5. **Serve the page under the endpoint's prefix** (`shapes/endpoint.md`, "Base paths"):
   a `<base>` built from the page's own location, relative URLs everywhere, and the
   server naming the MIME types it serves (`font/woff2`, `text/css`, `text/javascript`)
   so every Python version the login nodes run sends them.

### A React app on the components themselves

A larger app (forms, a job graph, a log viewer, a chat) is better built on the package
than redrawn: `npm install @parallelworks/ui` (peers: React 19, `react-hook-form`), a
Vite build, `import '@parallelworks/ui/fonts.css'` and `import '@parallelworks/ui/styles.css'`
(the prebuilt sheet, in its own cascade layer) or `theme.css` + `base.css` in a Tailwind
v4 build with the `@source` lines the README gives, the app under `UIProvider`, the
components from the README's "Which component?" table, and the mode applied with
`useApplyTheme(theme, mode)` (it sets `color-scheme` too), or outside React with
`applyTheme(root, generateTheme(schemeFor(DEFAULT_THEME, mode)))` plus
`root.style.colorScheme = mode`. Build with Vite's `base: './'` so the bundle runs under
any endpoint prefix.

The built `dist/` does not go in this repository (no build system here; large binaries
stay out, AGENTS.md): publish it as a **public** ORAS artifact on ghcr, as the SIF
containers are, and pull it in `controller.sh` with `tools/oras/libs.sh:oras_pull_file`
(the call and its retries: `software/singularity-sif-containers.md`), unpacked under
`service_parent_install_dir` and served by the app's server. Pin the package version
and the artifact tag together, and record how the artifact was built in the workflow's
README.

## What "looks like the platform" means

- Both modes work and are chosen the platform's way: light, dark, or the device's,
  through `color-scheme`; nothing is hard-coded for one mode.
- Every color is a `--theme-*` token read for its role: words in `-text` shades,
  graphics in the vivid shade, fills in `-muted`, a fill under white in `-solid`. The
  only literal colors are the recipes' own: white on a `-solid` fill (a danger button,
  a status cell with a white glyph) and on a switch's knob, and the drawer backdrop's
  `rgba(0, 0, 0, 0.4)`; a fill under white text or a white glyph never takes the vivid
  shade, which only reaches the 3:1 of graphics.
- The type is Geist Sans and Geist Mono at the package's sizes (`0.875rem` body copy
  in tables and controls, `0.75rem` labels and badges, `1rem` section titles).
- Controls, badges, tables, tabs and drawers follow the recipes above, in the
  package's sizes and radii (`0.375rem` controls, `0.75rem` panels, pill badges).
- Status is never color alone: an icon or a label beside it, the platform's glyph
  for the state.
- Icons are the platform's, picked by meaning.
- Keyboard focus shows in `--theme-focus`; motion stops under `prefers-reduced-motion`.

## Verify

1. **Locally, in both modes.** A browser check drives every control and saves full-page
   screenshots of the page in light and dark and of its drawer; look at them. PROBE's:
   `UI_SHOTS=/tmp/shots bash workflows/probe/selftest/ui_check.sh` (needs Chrome and
   Node 22+); its unit tests: `PYTHONPATH=app python3 -m unittest discover -s selftest -t .`
   from `workflows/probe`.
2. **Through the platform.** Run the workflow's recorded test with `--keep`, take the
   endpoint URL from `pw endpoints list`, and fetch the page's assets through the proxy
   with the API key, the way `wait_for_endpoint` probes a URL:

   ```bash
   curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' -H "Authorization: Bearer ${PW_API_KEY}" "${URL}theme.css"
   curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' -H "Authorization: Bearer ${PW_API_KEY}" "${URL}Geist-Variable.woff2"
   ```

   A headless browser with the same header on every request renders the deployed page
   for a screenshot. Then `pw endpoints delete` what the test kept, check for leftovers,
   and run the test once more without `--keep` so the recorded row reads `pass` and `ok`.

PROBE's files to copy from: `workflows/probe/app/web/styles.css` (every block names the
component it mirrors), `index.html` (the header bar, the toolbar, the inline icons, the
`<base>`), `app.js` (`icon()`, the `STATUS` looks, `applyTheme()`),
`selftest/ui_check.js` (`UI_SHOTS`), `app/probe/server.py` (the MIME types).
