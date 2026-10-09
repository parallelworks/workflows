# DOE: Design of Experiments

Spreads designs over the bounds of the design variables, or takes them from a
table you paste, and writes one case directory per design. Each holds a
Dakota-style `params.in`, one `<value> <name>` line per variable. The workflow
knows nothing about the evaluator, so any workflow can call it as a subworkflow
and run its own evaluator on the cases. For example,
[`workflows/doe-openfoam`](../doe-openfoam/README.md) solves every case with
[`workflows/openfoam-naca`](../openfoam-naca/README.md), which reads that file.

![Five panels of 16 designs over max camber and thickness: Latin hypercube with its 16 by 16 strata grid, each row and column used once; Sobol, evenly spread; random, with clusters and gaps; full factorial, a 4 by 4 grid; one at a time, a cross through the center with 13 cases](thumbnails/sampling-methods.svg)

## Sampling methods

**Sampling method** spreads **Number of cases** designs over the bounds in
**Design variables**, one `<name> <lower> <upper>` per line. Equal bounds hold a
variable fixed.

**The names are the contract with the evaluator.** Each name becomes a line of
every `params.in`, written exactly as you typed it, and a pasted table's header
uses the same names. So use the names your evaluator reads. For example, the
form's default box uses the four names
[`openfoam-naca`](../openfoam-naca/README.md#design-names) reads.

| Method | How it spreads the designs | Cases |
|---|---|---|
| Latin hypercube (default) | each variable split into `n` intervals, each used once | `n` |
| Sobol sequence | quasi-random, even coverage in every dimension | `n` |
| Random | independent uniform samples (Monte Carlo) | `n` |
| Full factorial | a grid of `L` levels per variable, the largest `L` with `L^d <= n` | `L^d` |
| One at a time | the center, then each variable alone across its range | `1 + d*k` |
| Your own cases (CSV) | the rows of a table you paste in **Cases (CSV)** | one per row |

`d` counts the variables that are not fixed. The two grid designs decide their
own size. **Random seed** makes the first three repeatable.

### Your own cases

Paste one row per case under a header naming the variables:

```
max_camber,camber_position,thickness,angle_of_attack
0.00,0.40,0.12,4
0.02,0.40,0.12,4
0.04,0.40,0.12,4
```

- Commas, tabs (a paste from a spreadsheet), semicolons or spaces separate the
  values.
- A variable without a column is held at the middle of its bounds in **Design
  variables**. A value outside the bounds is kept, with a warning.
- Case and status columns and Design Explorer's `out:` and `img:` columns are
  skipped, so a previous run's `doe.csv` or Design Explorer's `data.csv` pastes
  as it is; so does doe-openfoam's `results.csv`. Any other unknown column stops
  the run, so a typo cannot fix a variable by accident.

## What a run writes

The cases go to **Cases directory**, or to `cases/` in the run's job directory
when it is left empty. A directory that already holds cases is refused, so two
studies never mix.

```
cases/
├── case_1/params.in ... case_n/params.in   one design each
├── doe.csv                                 the designs as a table
└── doe.env                                 N_CASES, CASES_DIR and METHOD
```

The same three values are the run's outputs. `case_<j>/` is one of the two
layouts [`design-explorer`](../design-explorer/README.md) reads, so the cases
can be served there as they are evaluated.

## As a subworkflow

A parent workflow passes the form's groups through `with:`, reads the count
back from `doe.env`, and sizes its evaluation matrix with it. For example, this
is how [`workflows/doe-openfoam`](../doe-openfoam/README.md) calls it:

```yaml
- name: DOE (Sample the Designs)
  uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/doe/yamls/general.yaml
    cluster:
      resource: ${{ inputs.cluster.resource }}
    doe:
      method: ${{ inputs.doe.method }}
      n_cases: ${{ inputs.doe.n_cases }}
      variables: ${{ inputs.doe.variables }}
      cases_dir: ${{ needs.preprocessing.outputs.CASES_DIR }}
- name: Publish the Designs
  run: tee -a $OUTPUTS < "${{ needs.preprocessing.outputs.CASES_DIR }}/doe.env"
```

The sampler is `app/doe.py`, standard library only.
