# Dakota-OpenFOAM Expansion Optimization

Stage 2 of the planar-expansion design study (studies/expansion): Dakota
optimizes the lower-wall transition — its length and the two wall roundings —
against two objectives, the total-pressure loss coefficient K and the margin
above reversed wall flow, as a loop of standalone workflows:

| Piece | Workflow | Called by |
|---|---|---|
| propose designs or stop | [`workflows/dakota`](../dakota/README.md) | the `optimize` job of `iteration.yaml` |
| solve one design | [`workflows/openfoam-expansion`](../openfoam-expansion/README.md) | the `workers` matrix of `iteration.yaml`, once per design |
| serve the study live | [`workflows/design-explorer`](../design-explorer/README.md) | `preprocessing` |

Their READMEs describe the optimizer, the evaluator, the page and their inputs;
this one covers only the loop and the live page. The loop mechanics come from
[`tutorials/optimization`](../../tutorials/optimization/README.md). The
expansion workflows live on the `expansion` branch until the study merges, so
this loop's checkout and its calls of the evaluator (and of its own iteration
YAML) fetch `expansion` instead of `canary`.

## The problem

A 2D channel of height h expands to 2h through the lower-wall transition; the
design is its three parameters, with the bounds of the study's spec (stage 1, a
DOE sweep, has not run, so the loop searches the full box):

| Variable | Bounds | Meaning |
|---|---|---|
| `transition_length` | 0.5 – 10 | length of the wall transition in h |
| `top_rounding` | 0 – 0.9 | level run before the drop (corner rounding) |
| `bottom_rounding` | 0 – 0.9 | gentleness of the landing on the outlet floor |

Both objectives are minimized, exactly the two Dakota MOGA needs:

- `loss_coefficient` — K, the flux-weighted total-pressure drop between the
  fixed planes (x = -2h and x = 40h), every design charged the same channel;
- `neg_min_wall_shear` — the negated minimum streamwise wall shear: the
  attachment margin, zero when the flow reverses on the wall. Minimizing it
  maximizes the margin, so the front trades pressure loss against staying
  attached.

The operating point is fixed for every design: Reynolds number (default 300,
U_b·2h/ν), the inlet channel length and the two loss planes pass through to
every case as run settings, never design variables — a params file carrying
`reynolds` or `mesh_scale` fails the case (the evaluator enforces it), so every
design of every generation is solved on the same problem. K is defined only at
the fixed planes (~0.02 K per h of moved outlet plane, measured), which is why
they are form fields, not variables.

## How the pieces connect

```
general.yaml
 ├─ preprocessing       state/ (the study); checks that the OpenFOAM and Dakota environments deliver
 │                      their tools; checks the loss planes sit inside the channel; calls design-explorer
 │                      over state/, which serves it and waits until its endpoint is listed and /healthz
 │                      answers through the platform
 └─ optimization_loop   needs the page, then:
     ├─ Iterate         retried step; each attempt runs iteration.yaml once:
     │                    optimize ──▶ workers-1..batch_size ──▶ decide
     │                    dakota step   openfoam-expansion  exit 1 = next cycle, exit 0 = done
     └─ Report          if: always — verdict from state/status, the page URL
```

The two subworkflows only share files under `state/`:

1. `optimize` calls the Dakota step with the problem, the knobs and
   `state_dir`; the step ingests `iter_<N-1>/case_*/{results.out,exit_code}`
   and writes `iter_<N>/case_<j>/params.in` plus `proposal.env`, which the next
   step publishes as outputs.
2. `workers` is a matrix of `batch_size` slots (the form input, expanded at
   submission, at most 8 — the cases solve serially and the login node has 16
   cores); slot *j* runs when `j <= N_CASES` and calls the expansion evaluator
   with `case.params_file = ITER_DIR/case_j/params.in` and
   `case.case_dir = ITER_DIR/case_j`; the cluster, Reynolds, channel, plane,
   mesh and environment settings pass straight through. The call leaves
   `results.out` (K first, then the diagnostics, by label — the optimizer picks
   its objectives by name) or `exit_code` in that directory.
3. `decide` turns `state/status` into the exit code the parent's retry loops on.

Every case is therefore exactly a standalone `openfoam-expansion` run: its own
checkout and environment check (lock-serialized install), its own submitter job,
and a `case/case.foam` that opens in ParaView, for every design of every
generation.

## The live page

`design-explorer-<run slug>` (in `pw endpoints list` and on the run page) is
[`workflows/design-explorer`](../design-explorer/README.md) serving the study
directory, called from preprocessing, so the page is live from the first
generation and a server that cannot start fails the run before any case is
spent. It reads the case directories and the optimizer's `problem.json` and
`state.json` on every request, and polls every 10 s until Dakota's status is
final.

- **Pareto**, the first view: `loss_coefficient` (↓) against
  `neg_min_wall_shear` (↓), every solved design colored by generation, the
  front ringed with its attainment staircase. The scrubber replays the study
  generation by generation (▶), and the convergence cards show the
  hypervolume, the best of both objectives so far and the front's size per
  generation. Hover a design for its values, click it to open it in the case
  panel.
- One axis per design variable and objective, plus **generation** and
  **pareto_front** (1 for the designs no other design beats on both
  objectives); the scrubber is a brush on generation, so every view follows it.
- A case appears as soon as it solved. Failed designs (a diverged solver) have
  no outputs and are counted, not plotted. This study's evaluator renders no
  images, so the page shows values only.

**The endpoint outlives the run**: after the optimization finishes, or after a
cancel, it keeps showing the final study until `pw endpoints delete
design-explorer-<run slug>` removes it (that kills `pw endpoints run` and the
server under it). The design-explorer workflow removes its own server when its
endpoint never answered. A cancel mid-generation kills the running cases and
scheduler jobs and leaves only the endpoint.

## Running it

Pick the resource, set `max_iterations`, `batch_size` (at most 8), 
`stall_generations` and `mesh_scale`, and choose login node or scheduled cases
(each case is one serial job, `--ntasks=1`). The **Design Problem** group holds
the Reynolds number, the channel and plane settings, the variable bounds and
the Dakota seed.

**The names connect the pieces.** Dakota writes each name of **Design
variables** into every proposed `params.in`, and the expansion case reads them
by name ([its design names](../openfoam-expansion/README.md#design-names)). So
keep the three names `transition_length`, `top_rounding` and `bottom_rounding`.
The objectives (`loss_coefficient neg_min_wall_shear`) are fixed: the
evaluator's `results.out` labels both, and the Dakota step picks them by label.
A misspelled variable name fails every case of the first generation with an
error that lists the evaluator's three names, and the loop ends FAILED.

The form's defaults are the demo: login node, `mesh_scale` 1, 4 × 10
generations, a few minutes per generation on the 16-core login node (each case
~1–2 min on one core). **Load saved inputs → `mesh3_study`** is the
converged-mesh study: `mesh_scale` 3 (~83k cells, >10 min per case), 6 × 10,
the scale the validation table in the openfoam-expansion README shows is
converged.

The run succeeds only when the optimizer wrote `CONVERGED`. The front is
`state/pareto.csv` and `state/pareto.svg` in the run's job directory, every
case under `state/iter_<N>/case_<j>/`, the history on the page and in
`state/evaluations.csv`. The retried `Iterate` step shows only its last
attempt; each worker's log is three jobs deep (`workers-<k>` → `preprocessing`,
`run_case`, `results`). `iteration_timeout` (default 2d) caps one generation
because the platform's default retry timeout is 30 s per attempt.

## Tests

`tests/general/gcpsmall.json` — the demo at study scale: login node,
`batch_size` 4, `max_iterations` 2, `mesh_scale` 1, Reynolds 300; two evaluated
generations plus the converging call, about 10 minutes on gcpsmall
(`tests/general/gcpsmall.csv`).
