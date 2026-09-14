# `if:` conditions — which steps and jobs run

A step or a job runs only when its `if:` is true. Besides ordinary expressions
(`${{ inputs.debug == true }}`), `if:` understands a few **status keywords** that
look at what happened before it:

| keyword | on a **step**: looks at its own job so far | on a **job**: looks at the jobs in `needs` |
|---|---|---|
| `always` | runs | runs |
| `never` | skipped | skipped |
| `completed` | no earlier step failed, job not canceled | every needed job completed |
| `error` | an earlier step failed | a needed job failed |
| `canceled` | this job was canceled | a needed job was canceled |
| `!completed` | a step failed **or** the job was canceled | a needed job failed **or** was canceled |
| `!error` | no earlier step failed | no needed job failed |
| `!canceled` | this job was not canceled | no needed job was canceled |

Leaving `if:` out behaves like `if: ${{ completed }}`.

The keywords are plain booleans, so they combine with inputs, outputs and the
usual operators:

```yaml
if: ${{ error && inputs.fallback }}            # on error, but only when the box is ticked
if: "${{ inputs.fallback ? error : never }}"   # same thing, written as a ternary
```

Quote a ternary: YAML would otherwise read its ` : ` as a key/value separator.

## The example: [`if-conditions.yaml`](if-conditions.yaml)

One `work` job ends the way you choose in the form (**succeed**, **fail** or
**cancel**). The steps after it show the keywords **on steps**; the six jobs that
`need` it show the keywords **on jobs**.

```
work ──┬── on-completed      if: ${{ completed }}
       ├── on-error          if: ${{ error }}
       ├── on-canceled       if: ${{ canceled }}
       ├── on-not-completed  if: ${{ !completed }}
       ├── fallback          if: "${{ inputs.fallback ? error : never }}"
       └── report            if: ${{ always }}
```

Run it three times, once per outcome, and compare:

| Outcome | steps of `work` that run | jobs that run |
|---|---|---|
| succeed | Do the work · `if: completed` · `if: always` | on-completed · report |
| fail | Do the work (exits 1) · `if: error` · `if: !completed` · `if: always` | on-error · on-not-completed · fallback · report |
| cancel | Do the work · Cancel this job · `if: canceled` · `if: !completed` · `if: always` | on-canceled · on-not-completed · report |

`if: never` never runs, and `fallback` stays skipped if you untick its box.

### Running it

From the Activate UI, add the file as a workflow and pick an outcome in the form.
From the `pw` CLI (use the absolute path):

```bash
pw workflows run -i '{"outcome": "fail", "fallback": true}' "$PWD/tutorials/if-conditions/if-conditions.yaml"
pw workflows runs view <slug>        # ✓ ran, ○ skipped, ✗ failed, ⊘ canceled
pw workflows runs logs --job work <slug>
```

`permissions: ['*']` is only there for the `parallelworks/cancel-jobs` action,
which the `work` job uses to cancel itself.

### Known issue (platform, seen 2026-09-14)

When a **job-level** keyword condition is false (`error`, `canceled`, `!completed`,
even `never`), the executor records the job as `skipped-failed` instead of
`skipped`, and the **run** ends as `error` even when no job failed (the run's
error summary still says "0 job(s) failed"). A plain `if: ${{ false }}` job is a
clean `skipped`. So the **succeed** outcome above shows the right jobs and steps
but a red run status. Step-level keywords are not affected.
