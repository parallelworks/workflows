# Design parameters: the params.in / results.out contract

How a **driver**, the workflow that chooses designs, and a **runner**, the
workflow that solves one design, exchange data. In this repo:

| Role | Workflow | Writes | Reads |
|---|---|---|---|
| driver | `workflows/doe` (sampler), `workflows/dakota` (optimizer step) | `params.in` | `results.out` (Dakota only) |
| runner | `workflows/openfoam-naca` | `results.out` or `exit_code`, `images/*.png` | `params.in` |
| viewer | `workflows/design-explorer` | nothing | all of them |

A composed workflow wires a driver to a runner: `doe-openfoam` (doe, then a
matrix of openfoam-naca) and `dakota-openfoam` (a loop of dakota, then a matrix of
openfoam-naca). The two never call each other. They meet in a case directory.

## The case directory

One directory per design, `case_<j>/` or `iter_<N>/case_<j>/`:

```
params.in     written by the driver: one "<value> <name>" line per design parameter
results.out   written by the runner: one "<value> <label>" line per output, atomically
exit_code     written by the runner always; without results.out it means "ran and failed"
images/*.png  optional, written by the runner
```

The driver passes the runner two paths: `case.params_file` (the `params.in`) and
`case.case_dir` (where to solve and leave the results). Paths built from
`matrix.job_id` are the only way to hand per-slot data to a `uses:` step
(pitfalls: "A matrix instance cannot read its own earlier step's outputs").

## Names are the contract

A runner's **design parameters** are fields of its form, and the same names are
the lines of `params.in`. openfoam-naca has four, under `inputs.case`:
`max_camber`, `camber_position`, `thickness`, `angle_of_attack`. The other `case`
fields (`mesh_scale`, `case_dir`, `params_file`) are run settings; the solver gets
`mesh_scale` as the environment variable `MESH_SCALE`, never from `params.in`.

openfoam-naca's **Create the Case** step builds the case's `params.in` from the
file, then the four form values, keeping the first line of each name
(`awk 'NF >= 2 && !seen[$2]++'`):

- a name in the file overrides the form field of that name;
- a name the file leaves out keeps the form's value (the form default, unless the
  caller passes that field, as dakota-openfoam does with `angle_of_attack`).

So a driver only has to know the runner's names. The user types them in the
driver's **Design variables** (`<name> <lower> <upper>`), the driver writes them
into `params.in` unchanged, and the runner matches them.

## Publishing and checking the names

**The runner publishes its design parameters** in `app/design-parameters.txt`,
one name per line (the first word; the rest of the line is a note, `#` starts a
comment). openfoam-naca's:

```
max_camber         first NACA digit / 100, chord fraction
camber_position    second NACA digit / 10, chord fraction
thickness          last two NACA digits / 100, chord fraction
angle_of_attack    degrees
```

**The runner checks the params file against it**, in the step that builds the
case and before anything is submitted:

```bash
if [ -n "${params_file}" ]; then
  bash tools/utils/check-params.sh workflows/<runner>/app/design-parameters.txt "${params_file}"
fi
```

`tools/utils/check-params.sh` fails, with one `::error::` line per problem, when a
line names a parameter the list does not have, when a value is not a number, or
when a line is not `<value> <name>`. The unknown-name message lists the names the
runner does read. It checks the caller's file, not the merged `params.in`: the
merge drops lines without a name, and the form's own values are always valid.

**Callers do not check.** The list lives with the runner, so the runner is the
one place that enforces it, for every caller, a hand-run with a params file
included. The cost is where the error shows: in each worker's Create the Case
log, not in the caller's preprocessing.

## Outputs

openfoam-naca writes `drag_coefficient` and `neg_lift_coefficient` (lift negated,
so both are minimized). Dakota's step reads `results.out` by label when every
objective name is a label there, else the first values in order, so
dakota-openfoam's **Objectives** are those two labels. Design Explorer shows every
value as an output and turns that pair into Cd, Cl and Cl/Cd.

## Building a new runner or driver

- **Runner:** put each design parameter in the form; list the same names in
  `app/design-parameters.txt`; take `params_file` and `case_dir`; check the params
  file with `tools/utils/check-params.sh`, then merge as above; write
  `results.out` atomically with labels and always write `exit_code`; show the
  names in the README (openfoam-naca's "Design names" table is the model).
- **Driver:** write `params.in` with the runner's names, as the user typed them,
  one case directory per design, in one of Design Explorer's two layouts; read
  `results.out` by label. Do not check the names: the runner does.
