# `if:` conditions — which steps and jobs run

A step or a job runs only when its `if:` is true. Besides ordinary expressions
(`${{ inputs.debug == true }}`), `if:` can call **status functions** that look at
what happened before it:

| condition | on a **step**: looks at its own job so far | on a **job**: looks at the jobs in `needs` |
|---|---|---|
| `always()` | runs | runs |
| `false` | skipped | skipped |
| `success()` | no earlier step failed, job not canceled | no needed job failed or was canceled |
| `failure()` | an earlier step failed | a needed job failed |
| `cancelled()` | this job was canceled | a needed job was canceled |
| `!success()` | a step failed **or** the job was canceled | a needed job failed **or** was canceled |
| `!failure()` | no earlier step failed | no needed job failed |
| `!cancelled()` | this job was not canceled | no needed job was canceled |

`canceled()` is another spelling of `cancelled()`. The bare word `always`
(`if: ${{ always }}`) is the older spelling of `always()`, still accepted as the
whole condition but text inside a larger one: write `always()`.

Leaving `if:` out behaves like `if: ${{ success() }}`, and so does an `if:` that
calls no status function: `if: ${{ inputs.debug == true }}` runs only when
`inputs.debug` is true **and** nothing failed. An `if:` that calls a status
function replaces that check, so a step or job that must run after a failure or a
cancel says so with `failure()`, `cancelled()`, `!success()` or `always()`.

The functions are booleans, so they combine with inputs, outputs and the usual
operators:

```yaml
if: ${{ inputs.fallback && failure() }}            # on failure, but only when the box is ticked
if: "${{ inputs.fallback ? failure() : false }}"   # same thing, written as a ternary
if: ${{ always() && inputs.debug == true }}        # whatever happened, in debug runs only
```

Quote a ternary: YAML would otherwise read its ` : ` as a key/value separator.

### The keywords that are gone

ACTIVATE v7.69 added the keywords `completed`, `error`, `canceled`, `never`, their
`!` forms and the aliases `success`, `failure`, `cancelled`, written without
parentheses. ACTIVATE v7.112 removed them in favor of the functions above. A bare
word other than `always` is now just text, and text that isn't empty is true, so an
old condition still loads but means something else: `${{ error }}` keeps the
implicit `success()` check and runs only when nothing failed, and `${{ !completed }}`
is always false. Rewrite them as:

| was | now |
|---|---|
| `completed` | `success()` |
| `error` | `failure()` |
| `canceled` | `cancelled()` |
| `!completed` | `!success()` |
| `!error` | `!failure()` |
| `!canceled` | `!cancelled()` |
| `never` | `false` |
| `success`, `failure`, `cancelled` (no parentheses) | `success()`, `failure()`, `cancelled()` |
| `always` | `always()` |

A word compared with `==` (`inputs.level == error`) is a string comparison, not a
status check: leave it as it is.

## The example: [`if-conditions.yaml`](if-conditions.yaml)

One `work` job ends the way you choose in the form (**succeed**, **fail** or
**cancel**). The steps after it show the functions **on steps**; the six jobs that
`need` it show the functions **on jobs**.

```
work ──┬── on-success       if: ${{ success() }}
       ├── on-failure       if: ${{ failure() }}
       ├── on-cancelled     if: ${{ cancelled() }}
       ├── on-not-success   if: ${{ !success() }}
       ├── fallback         if: ${{ inputs.fallback && failure() }}
       └── report           if: ${{ always() }}
```

Run it three times, once per outcome, and compare:

| Outcome | steps of `work` that run | jobs that run |
|---|---|---|
| succeed | Do the work · `if: success()` · `if: always()` | on-success · report |
| fail | Do the work (exits 1) · `if: failure()` · `if: !success()` · `if: always()` | on-failure · on-not-success · fallback · report |
| cancel | Do the work · Cancel this job · `if: cancelled()` · `if: !success()` · `if: always()` | on-cancelled · on-not-success · report |

`if: false` never runs, and `fallback` stays skipped if you untick its box.

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
