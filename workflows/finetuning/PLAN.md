# PLAN — generalized LoRA/QLoRA fine-tuning workflow

> **What this file is:** the execution state of this workflow — what is built,
> what is *verified on real hardware*, and what remains. `HANDOFF.md` is the
> design record (why one container, why OLMo, the verified gpt-oss version set,
> the MXFP4 subtlety, what is deferred); this file is the running status.
> Where the two disagree about *state*, this file wins.
>
> **New session, different machine? Read in this order:**
> 1. This file's "Status" and "Picking it up on new hardware" sections.
> 2. `HANDOFF.md` **§8.5** — the three failure modes already root-caused here.
>    One of them silently trains zero parameters while looking successful.
>    Read it before touching the PEFT/quantization wiring.
> 3. `HANDOFF.md` §2/§3/§3.5 for the model matrix, gpt-oss specifics, and the
>    one-container decision, then §6 for the remaining priority order.
> 4. **`README.md` → "Dataset format requirements"** before generating,
>    swapping or pointing at any training data. Loss is computed on the
>    response only, which makes the row format load-bearing: the wrong
>    delimiter is a hard error, a partly-matching dataset drops rows with only
>    a warning, and multi-turn data is not handled correctly. That section is
>    the canonical statement of those rules; this file only records the
>    measurements behind them.

Written and executed 2026-09-03 on a single **Tesla T4** (compute capability
7.5, 15 GB VRAM, Apptainer 1.4.5, driver 595.45.04). Branch: `add-finetuning`.

Extended 2026-09-04 on a **4x Tesla T4** node (4x 15360MiB, compute capability
7.5, PCIe/PHB-connected — **no NVLink**, driver 595.45.04, Apptainer 1.4.5,
24 CPU / 186GB RAM). See "Session 2026-09-04" below; it supersedes the
2026-09-03 status where they differ.

---

## Session 2026-09-04 — multi-GPU (4x T4)

Ran directly via `singularity exec --nv` on the 4x T4 node, no `pw` involved
(`pw auth` was expired; the platform/endpoint test remains outstanding and
needs a human to re-authenticate).

### Built this session

- **DDP + FSDP launch support — the parallelism gap is now wired.** Previously
  `resolve_strategy` emitted `strategy`/`launcher` that nothing consumed and
  `train-entrypoint.sh` always ran single-process `python3`.
  - `app/train-entrypoint.sh` branches its launch prefix on a new `STRATEGY`
    env var: `single` -> `python3`; `ddp` -> `accelerate launch --multi_gpu
    --num_processes $NUM_GPUS`; `fsdp` -> `accelerate launch --num_processes
    $NUM_GPUS --config_file $FSDP_CONFIG`.
  - `app/train.py` gained `--strategy` and `resolve_device_map()`.
    `device_map="auto"` is **wrong for both** distributed strategies: under ddp
    every process would spread the same model across all visible GPUs (and HF
    Trainer would treat it as already-parallelized and skip DDP-wrapping it);
    under fsdp any pre-placement fights FSDP for ownership. Now: ddp ->
    `{"": LOCAL_RANK}`, fsdp -> no device_map + `low_cpu_mem_usage`.
  - 4-bit + fsdp additionally sets `bnb_4bit_quant_storage=torch.bfloat16`
    (FSDP's flatten-parameter sharding needs a float-viewable storage tensor,
    not bnb's default uint8 packing).
  - **Collective-safety fix:** saving now goes through
    `trainer.save_model()` on *all* ranks rather than
    `peft_model.save_pretrained()` — under FSDP a full-state-dict gather is a
    collective, so a main-process-only call would deadlock. Our own
    non-collective side effects (tokenizer, report, push_to_hub, merge) are
    guarded by `is_world_process_zero()`.
  - `merge_adapters_standalone()` added for the fsdp path: `trainer.model`'s
    params are FSDP shards at the Python-object level regardless of
    `fsdp_state_dict_type`, so `merge_and_unload()` on the live wrapped module
    would merge one rank's shard. It instead reloads the base model fresh and
    single-process from the already-gathered adapter checkpoint.
- `app/fsdp_config.yaml` (new) — model-agnostic accelerate FSDP config
  (`FULL_SHARD`, `SIZE_BASED_WRAP` so no per-architecture decoder-layer class
  name, `use_orig_params`, `cpu_ram_efficient_loading`, `sync_module_states`,
  `FULL_STATE_DICT`). `mixed_precision: 'no'` deliberately — this hardware is
  for validating sharding correctness, not throughput; precision stays under
  `train.py`'s `--bf16`/fp16 as the single source of truth.
- `yamls/general.yaml` — threads `num_gpus` into `inputs.sh`;
  `start-template.sh` exports `STRATEGY`/`NUM_GPUS`/`FSDP_CONFIG`.
- **Forward-compatible kwarg cleanup (landed on the 4.x pin).**
  `use_auth_token=` -> `token=` (3 sites) and `torch_dtype=` -> `dtype=`
  (2 sites) in `app/train.py`. These were pure deprecation debt — 4.56.2
  itself warned on every run ("will be removed in v5 of Transformers") — and
  both new spellings are already the supported names on the current pin, so
  this is not a 5.x commitment. Verified on pinned 4.56.2: olmo2-1b-dev
  4-bit end-to-end, exit 0, eval_loss 3.03 -> 0.55, merge + report OK, and
  **zero** deprecation warnings remaining. `token=` was separately confirmed
  to genuinely carry auth (loads the *gated* gemma-1.1-7b tokenizer; refused
  with `token=False` as a negative control), not merely be accepted.
  Side benefit: it reduces the eventual transformers-5.x migration to a
  single remaining concern, the `logging_dir`/TensorBoard path (below).
  NOTE the 2 occurrences inside `merge_adapters_standalone()` are on the
  fsdp-only path and therefore still unexecuted.
- **Resolver threshold bug fixed.** `NEED_PER_GPU = footprint*1.6+8` gave
  gemma-1.1-7b (FOOTPRINT=5) a 16GB/GPU requirement, which never fits a real
  ~15GB T4 — so it resolved to `fsdp` when the whole point of that profile is
  the `ddp` path. Constant lowered to +6, now measured-and-annotated in
  `general.yaml`.

### Verified on 4x T4

Pass criterion throughout is HANDOFF sec8.5a's: **falling `eval_loss` AND
non-zero `grad_norm`**, plus merge/reload actually working.

> **NOTE — the eval_loss numbers in this table are the pre-completion-only
> baseline** (loss over the whole sequence, prompt included). All four
> configurations were re-run after completion-only masking landed; see
> "Completion-only loss" below for the current numbers. The strategy,
> trainable-param and VRAM figures here are unaffected.

| step | config | strategy | trainable | eval_loss | peak VRAM | result |
|---|---|---|---|---|---|---|
| 1 | `olmo2-1b-dev`, no quant, fp16 | single (1 GPU) | 12.1M (0.81%) | 2.86 -> 0.19 | not sampled | **PASS**, merge+reload generated the trained answer |
| 2 | `olmoe-1b-7b-dev` (MoE), 4-bit, fp16 | single (1 GPU) | 4.19M (0.06%) | 2.31 -> 0.62 | ~10.2GB (manual reads) | **PASS**, MoE branch detected 3072 expert Linears -> attention-only targeting |
| 3 | `gemma-1.1-7b`, 4-bit, fp16 | **ddp** (4 GPUs) | 50.0M (0.58%) | 27.5 -> 19.5 | 10929/10945/10969 MiB on GPU1-3, 13105 MiB GPU0 | **DDP plumbing PASS** (see caveat) |

- Step 3's DDP replication is confirmed by sampled evidence, not inference: 18
  consecutive 3s samples with **all four** GPUs simultaneously >1GB. GPU0's
  higher peak is the rank-0-only merge, exactly as the
  `is_world_process_zero()` guard implies. Merged model reloaded and answered
  correctly.
- The resolver, with the fixed constant, auto-selects `ddp` for gemma-1.1-7b on
  4x15GB (verified by evaluating the same arithmetic).

### RESOLVED: the Gemma "implausible loss" was one token, not a numerics bug

**Root cause: the training loss includes predicting the first content token
from `<bos>` alone, and for Gemma that single token costs ~647 nats.**
Diagnosed by forward-pass only (no training), per-token loss breakdown:

```
loss= 647.0   ctx='<bos>' -> target='###' (id=6176)      <-- one per sequence
```

gemma-1.1-7b-it assigns essentially zero probability to a document opening
with `###`. Over ~28 valid tokens that one position contributes ~23 of the
~31 total loss — it *is* the entire anomaly. Everything else is healthy:
**median per-token loss 0.19-0.69.**

Why Gemma and not OLMo: Gemma's logit scale is far larger (abs max 880,
std 179) than OLMo-2's (48.5 / 6.17), so the same structurally-improbable
prediction produces a 647-nat spike where OLMo's worst token is only 12.
Gemma 1.1 has no `final_logit_softcapping` to tame it.

Ruled out by measurement — **do not re-test these**:
- **Not precision.** bf16 single-GPU reproduces fp16 almost exactly.
- **Not quantization.** Unquantized bf16 is the same (loss 30.5, logit max
  844, std 179) as 4-bit (31.5 / 880 / 180).
- **Not ddp/fsdp.** Reproduces single-process, single-GPU.
- **Not the chat template.** Applying Gemma's real
  `<start_of_turn>` template made it slightly *worse* (36.6), because the
  `<bos>`->first-token problem is unchanged by reformatting.
- **Not our pad masking.** `labels[attention_mask==0] = -100` is correct,
  and OLMo is healthy through the identical pipeline. (Note Gemma's
  tokenizer defaults to `padding_side='left'`, which *would* add a second
  bogus target — predicting `<bos>` from pure `<pad>` context, 137 nats —
  but `build_base_model()` already forces `padding_side="right"`.)

**Consequences.** The four validated runs were genuinely learning: falling
eval_loss, non-zero grad_norm, and correct post-merge generation all stand.
This is a *training-objective* gap, not a correctness bug. But it does mean
(a) absolute loss values are not comparable across models, and (b) a slice
of gradient signal is spent on an impossible prediction — a large slice for
short sequences.

**Fix: completion-only loss masking — IMPLEMENTED AND REVALIDATED.**
See "Completion-only loss" below. It removes the `<bos>`->prompt-start
prediction from the objective entirely, and the measured effect on Gemma is
decisive: initial train loss **25.9 -> 1.25**, eval **27.5->19.5 becomes
0.68->0.0025**.

## gemma-4-31b text-only fine-tuning — WORKING (2026-09-05)

**Validated on 4x Tesla T4. No Hopper, and no >15GB GPU, is required.** The
"needs Hopper" framing recorded earlier was wrong on two counts: the cc>=9.0
requirement belongs to gpt-oss MXFP4, not gemma-4, and VRAM was never the
blocker either.

| metric | result |
|---|---|
| load | `device_map="auto"` model-parallel across 4x T4 (aggregate 60GB) |
| targeting | 410 non-vision modules; vision tower excluded |
| trainable | 122,429,440 / 31,395,515,952 (**0.39%**) |
| eval_loss | **2.083 -> 0.00028** over 18 evals |
| grad_norm | non-zero throughout | 
| adapter | 489,840,816 bytes, reloads and generates the trained answer |
| exit | 0, zero tracebacks/OOM; report + plots written |

### What actually blocked it (not hardware)

1. **PEFT could not adapt the vision tower.** gemma-4 wraps its *vision*
   projections in `Gemma4ClippableLinear`, which PEFT rejects outright:
   *"Target module ... is not supported."* Meanwhile **all 410 text-tower
   layers are plain `nn.Linear`**. Our suffix-based target matching
   (`q_proj`, ...) reached into the vision tower and hit the wrapper.
2. **FSDP is unusable for this model on 5.x** (see the migration section
   below), so the sharded path is not the route. Model-parallel is.

### The fix

`resolve_lora_config()` gained a branch for `MULTIMODAL_PROFILES`: it targets
via a **regex** (PEFT treats a str `target_modules` as a regex; a list is
suffix-matched, which is why a list cannot express the exclusion)
`(?!.*vision).*\.(q_proj|k_proj|...)`. Verified against the module tree
before use: 410 supported `nn.Linear` matched, **0 unsupported, 0 in the
vision tower**. The branch is gated on the profile, so dense/MoE targeting
is structurally untouched.

**Vision capability is retained, not removed.** LoRA freezes the base model;
excluding the tower from *targeting* only means no adapter deltas on that
path. Confirmed empirically after training: **299,731,248 vision-tower
parameters still present** in the reloaded model. What is given up is the
ability to further *train* the vision pathway — which this workflow could
not do anyway, since its dataset path is text-only and would supply no
image gradient.

### Pins and lock files (2026-09-05)

The first cut of `requirements-tf5.txt` was written from the pins that had
been *edited in* before the build, not from the image that actually ran —
so it was never checked against reality. It is now, and the check found a
real weakness: the exact pins held, but **8 packages were loose `>=` and
their validated versions were unrecorded**, so a rebuild could silently
resolve differently.

- **Load-bearing pins are now exact in both requirements files**: `peft`,
  `bitsandbytes`, `datasets`, `huggingface_hub` (plus the already-exact
  torch/transformers/trl/triton/accelerate/tokenizers). `peft==0.20.0` is
  the critical one: the gemma-4 fix depends on *both* its supported-module
  list (which rejects `Gemma4ClippableLinear`) and its treatment of a str
  `target_modules` as a regex. HANDOFF sec8.5a/8.5c were also diagnosed
  against it.
- **`app/requirements.lock` and `app/requirements-tf5.lock`** record the
  full `pip freeze` of each validated image (85 and 93 packages). Reference
  artifacts, not build inputs — `finetune.def` still installs the `.txt`.
  They also capture `triton-kernels==0.1.0`, which is installed by
  `finetune.def`'s `%post` and appears in neither `.txt`.
- Verified: every exact pin in each file matches its image (10 per file,
  0 mismatches), and both sets resolve cleanly (`pip install --dry-run`,
  exit 0). `torch==2.8.0` legitimately installs as `2.8.0+cu128` from the
  cu128 extra index — not a mismatch.
- Still intentionally loose: tensorboard, matplotlib, scipy, sentencepiece
  (reporting/tokenizer peripherals). The locks pin them exactly if needed.
- The load-bearing versions are **identical across both images** except the
  three that had to move: transformers (4.56.2/5.16.1), tokenizers
  (0.22.1/0.23.1), huggingface_hub (0.36.2/1.30.0).

### End-to-end reproducibility, verified from scratch (2026-09-05)

Both images were **rebuilt from the committed requirements files** and the
whole matrix re-run against the rebuilds. This is the check that turns "the
pins match what is installed" into "the pins reproduce the image".

| built from | packages | vs committed lock |
|---|---|---|
| `app/requirements.txt` | 85 | **byte-identical** |
| `app/requirements-tf5.txt` | 93 | **byte-identical** |

Identical including every unpinned transitive, so the locks will not drift
under a rebuild and the loose peripheral pins are not a reproducibility risk
in practice.

All five configurations re-run on the rebuilt images, all exit 0, zero errors:

| test | rebuilt | previously recorded |
|---|---|---|
| olmo2-1b-dev, single (4.x) | 1.0452 -> 0.00112 | 1.0424 -> 0.00117 |
| olmoe-1b-7b-dev MoE, single (4.x) | 0.8806 -> 0.00424 | 0.8819 -> 0.01816 |
| gemma-1.1-7b, ddp x4 (4.x) | 0.6833 -> 0.00246 | 0.6787 -> 0.00252 |
| OLMo-2-32B, fsdp x4 (4.x) | 0.2754 -> 0.00017 | 0.2777 -> 0.00021 |
| gemma-4-31b, text-only (5.x) | 2.083 -> 0.00127 | 2.083 -> 0.00028 |

**Every structural invariant reproduced exactly** — trainable counts
(12,058,624 / 4,194,304 / 50,003,968 / 134,217,728 / 122,429,440), 3072 MoE
expert Linears detected, 410 non-vision modules matched for gemma-4, and the
FSDP adapter at 536,991,984 bytes. Only loss values differ, in the last
digits: ordinary nondeterminism from GPU kernel scheduling and dataset
shuffling, not drift. Treat the loss figures throughout this file as
reproducible to ~2 significant figures, not exactly.

No repository file changed as a result of the rebuild or the re-runs.

**Operational note for whoever repeats this:** run the multi-GPU
configurations *serially*. The first gemma-4 attempt OOM'd purely because it
was launched (model-parallel across all 4 GPUs) while the 32B fsdp run still
held them; re-run on free GPUs it passed. That OOM was a scheduling mistake,
not a reproducibility failure.

### Container story (implemented 2026-09-05)

The 5.x image was previously an untracked binary whose recipe existed only as
prose in this file — if it were deleted, rebuilding meant a human re-doing a
hand-edit of `requirements.txt`. Now both pin sets are tracked build inputs:

- `app/requirements-tf5.txt` — the 5.x set, with its regressions in the header.
- `app/build-container.sh` takes a 3rd arg (or `REQUIREMENTS_FILE` env) and
  **stages** the chosen file into a temp build dir as `requirements.txt`, so
  one unmodified `finetune.def` serves both and the repo file is never edited.
- `container.requirements_file` input drives build mode. **The built image is
  cached per pin set** (`finetune-<req_slug>.sif`); `controller.sh` and
  `start-template.sh` derive that path identically, so build mode cannot
  silently hand back the wrong stack.
- Deliberately **no profile-based container routing in the YAML** — that
  couples a library-version workaround to the workflow definition and has been
  fragile here before. Selection stays manual, with the guards below.

### Guards against picking the wrong image

- Wrong stack: `build_base_model()` converts the bare `KeyError('gemma4')` /
  "does not recognize this architecture" into a message naming the installed
  transformers version and `app/requirements-tf5.txt`. Verified: running
  gemma-4 on the 4.x image now says exactly that.
- `strategy=fsdp` on transformers >= 5 logs a loud warning pointing at
  `parallelism_override=single`. A warning, not an error, because FSDP is fine
  where the model fits per-rank and a future release may restore the path.

### How to run it

- **Requires the transformers 5.x image** (`~/pw/singularity/finetune-tf5.sif`)
  — `gemma4` exists in no 4.x release. `requirements.txt` stays on 4.x for
  every other profile, so this is the two-image split that
  `container_mode`/`container_sif_path` already supports (HANDOFF sec3.5).
- **Set `advanced.parallelism_override=single`.** The resolver picks `fsdp`
  from the footprint, but FSDP cannot load this model on 5.x. With `single`
  and several GPUs visible, `resolve_device_map()` returns `"auto"` and
  spreads the model across them. This is a library-bug workaround, so it is
  documented rather than special-cased in the resolver.
- Caveat: heavy text-only adaptation can still drift the LM away from
  interpreting vision tokens well (ordinary catastrophic forgetting). The
  tower is intact; multimodal *performance* is not guaranteed preserved.

## transformers 5.x migration — ATTEMPTED AND REVERTED (2026-09-04)

**Verdict: do not migrate on this hardware. `requirements.txt` is back on the
4.x pins.** 5.x supplies the `gemma4` architecture but simultaneously breaks
the sharded loading needed to fit such a model on 4x15GB, so the bump has no
payoff here — it is strictly a capability loss.

| test | 4.x (validated) | 5.16.1 |
|---|---|---|
| OLMo-2-1B dense, single, unquantized | PASS | **PASS** (eval 1.042 -> 0.00094) |
| dense 7B peak memory, 4-bit fwd+bwd | 10.43 GiB | **10.43 GiB** (identical) |
| OLMoE-1B-7B **MoE**, 4-bit, single | PASS (6.35 GiB) | **OOM** (>14.3 GiB) |
| OLMo-2-32B, **fsdp**, 4-bit | PASS | **OOM at load** |
| gemma-4-31B, fsdp, 4-bit | arch unsupported | **OOM at load** |

### Two independent regressions, both measured

1. **FSDP sharded loading is broken.** 5.x moved weight materialization into
   a new `transformers/core_model_loading.py`, which contains **zero**
   references to `is_fsdp_enabled` (`modeling_utils.py` still has 3, but is
   no longer the path taken). So `fsdp_cpu_ram_efficient_loading` is not
   honored and **every rank materializes the whole model**. Our early
   `PartialState()` fix still reports `is_fsdp_enabled()=True` — the gate
   opens, the new loader just does not consult it. Both the 32B case that
   passes on 4.x and gemma-4-31B die identically at
   `core_model_loading.py::convert_and_load_state_dict_in_model`, never
   reaching training.
   *Caveat:* this only bites when a model does not fit per-rank. On
   80GB-class GPUs each rank could materialize the full model, so 5.x +
   gemma-4 may well work on Hopper. It is unusable on 15GB cards.
2. **MoE forward uses >2x the memory.** OLMoE-1B-7B 4-bit: 6.35 GiB on 4.x
   vs >14.3 GiB on 5.x for an identical workload (same batch/seq/LoRA),
   OOMing inside the loss. Localized to the MoE path by control: a *dense*
   7B at the same settings peaks at exactly 10.43 GiB on **both** versions.
   This matters beyond OLMoE itself, since OLMoE is the stand-in for the
   gpt-oss MoE path (HANDOFF sec2).

### Kept from the attempt: two portable fixes (they work on 4.x, and landed)

Both are improvements independent of the version question, and were
re-verified on the 4.x image after reverting:

1. **`logging_dir` removed from `SFTConfig`.** 5.x deleted the field with no
   replacement; with it unset, *both* versions write events to
   `<SFTConfig.output_dir>/runs/<timestamp>/`. `app/start-template.sh` now
   serves `${output_dir}` and lets TensorBoard find events by recursive
   scan. This also removes the trap where the old code created an empty
   `tensorboard/` directory that made a blank dashboard look like "nothing
   logged yet".
2. **`device_map="auto"` no longer used for single-GPU runs.** Pinning
   `{"": 0}` when exactly one GPU is visible; `"auto"` retained when several
   are, where the model-parallel spread is the point. Motivated by 5.x
   (whose `_get_device_map` refuses a quantized model with *"Some modules
   are dispatched on the CPU or the disk"* even when it fits), but correct
   on 4.x too.

### If this is revisited

- The 5.x image is kept at `~/pw/singularity/finetune-tf5.sif` and the
  validated 4.x one at `~/pw/singularity/finetune-tf4.56.2.sif`, so neither
  needs a rebuild.
- Re-applying is: `transformers==5.16.1`, `tokenizers==0.23.1`,
  `huggingface_hub>=1.5.0,<2.0`. Note the hub **major** bump — `peft`/`trl`/
  `accelerate`/`datasets` only permit it via open-ended lower bounds and
  none were tested against it upstream.
- Retest both regressions above first; they are the blockers, not the
  three API edits.
- `container_mode`/`container_sif_path` already allow shipping two images
  (HANDOFF sec3.5 contemplates splitting at a dependency boundary), so a
  5.x image could serve gemma-4 on Hopper while 4.x serves the matrix.

## Superseded: transformers 5.x migration notes (kept for the reasoning trail)

Motivation: `gemma-4-31b` declares `model_type: gemma4`, which **no 4.x
release recognizes**. `transformers==5.16.1` does.

### CORRECTION to the earlier cost estimate

An earlier note in this file put the migration at "three edits" based on a
`pip install --target` probe. **That probe was wrong** — `--target` bypasses
dependency resolution, so it ran transformers 5.16.1 against
`tokenizers 0.22.1` and `huggingface_hub 0.x`, a combination 5.x forbids. It
happened to work for the one path exercised. A real install is
`ResolutionImpossible`. The actual cascade:

| package | was | 5.x requires |
|---|---|---|
| transformers | 4.56.2 | 5.16.1 |
| tokenizers | 0.22.1 | `>=0.23.1,<0.24` |
| huggingface_hub | 0.x (`>=0.22.0`) | **`>=1.5,<2` — major bump** |

`peft`/`trl`/`accelerate`/`datasets` permit hub 1.x only because they use
open-ended lower bounds; none were tested against it upstream. Resolved
stack now in the image: transformers 5.16.1, tokenizers 0.23.1, hub 1.30.0,
with trl 0.23.0 / peft 0.20.0 / accelerate 1.10.1 unchanged.

**Rollback:** the validated 4.x image is preserved at
`~/pw/singularity/finetune-tf4.56.2.sif`; the 5.x one is
`~/pw/singularity/finetune-tf5.sif`. Reverting is `requirements.txt` +
either image, no rebuild needed.

### Code changes (both version-agnostic — they work on 4.x too)

1. **`logging_dir` removed from `SFTConfig`.** 5.x deleted the field with no
   replacement. With it unset, *both* 4.x and 5.x write events to
   `<SFTConfig.output_dir>/runs/<timestamp>/` (i.e. under `adapters/`), so
   the default is now the portable choice. `app/start-template.sh` serves
   `${output_dir}` itself and lets TensorBoard find events by recursive
   scan. **Verified on 5.x:** events landed at
   `<output_dir>/adapters/runs/<ts>/events.out.tfevents...` (22KB) — inside
   the served tree. This closes the silent-blank-dashboard trap recorded
   earlier.
2. **`device_map="auto"` is no longer used for single-GPU runs.** 5.x's
   `_get_device_map` decides to offload part of a *quantized* model to CPU
   even when it fits comfortably, then refuses: *"Some modules are
   dispatched on the CPU or the disk."* Measured on 4-bit OLMoE-1B-7B
   (~4GB) on an otherwise-free 15GB T4 — `'auto'` raises, `{"": 0}` loads
   fine. `resolve_device_map()` now pins `{"": 0}` when exactly one GPU is
   visible and keeps `"auto"` for the multi-GPU-visible case, where the
   model-parallel spreading is the point. Unquantized models are
   unaffected, which is why the dense smoke test passed before this fix.

## Completion-only loss (2026-09-04, after the diagnosis above)

`app/train.py` gained `--response-template` (env `RESPONSE_TEMPLATE`, form
input `advanced.response_template`, default `"### Response:\n"`). When set,
`split_prompt_completion()` converts the single-text dataset into TRL's
prompt-completion format (prompt = everything up to and including the
template; completion = the rest) and `SFTConfig(completion_only_loss=True)`
scores the completion only. Blank preserves the old whole-sequence
behavior. Rows missing the template are dropped with a warning; if none
match, it raises rather than silently training on nothing.

**The dataset-format rules this imposes live in `README.md` → "Dataset format
requirements"** (delimiter must appear literally in every row; no-match is a
hard error; partial matches drop rows with only a warning; single-turn only).
That is the canonical, user-facing statement — do not restate the rules here,
or the two will drift. What follows is only the implementation and the
evidence.

Implementation notes worth keeping:
- The split has to happen in our data prep because trl 0.23 supports
  `completion_only_loss` **only for prompt-completion datasets**, and it
  **removed `DataCollatorForCompletionOnlyLM`** (the older response-template
  collator), so there is no in-collator option.
- `dataset_text_field` is now passed only in the whole-sequence case: a
  prompt-completion dataset has no `text` column.

### Second bug this work exposed: concurrent `login()` corrupts the HF token store

The first ddp revalidation attempt died with
`ValueError: Token <name> not found in ~/.cache/huggingface/stored_tokens`.
Cause: `maybe_login()` ran on **all four ranks at once**, and the
interleaved writes left `stored_tokens` holding an INI-style fragment
(`[<token-name>]`) instead of JSON, which then broke every subsequent run.
`maybe_login()` is now main-process-only. Nothing is lost by that: the token
is passed explicitly to every `from_pretrained` call, so `login()` only
populates the credential store. (The corrupted file was moved aside; the
next `login()` rewrote it cleanly.)

### Revalidated results — all four configurations, completion-only loss

Same pass criterion as before (falling `eval_loss`, non-zero `grad_norm`),
all exit 0 with zero tracebacks/OOM:

| step | config | strategy | trainable | eval_loss (completion-only) | eval_loss (previous, prompt-included) |
|---|---|---|---|---|---|
| 1 | `olmo2-1b-dev`, no quant, fp16 | single | 12.06M (0.81%) | **1.04 -> 0.0011** | 2.86 -> 0.19 |
| 2 | `olmoe-1b-7b-dev` MoE, 4-bit, fp16 | single | 4.19M (0.06%) | **0.87 -> 0.0039** | 2.31 -> 0.62 |
| 3 | `gemma-1.1-7b`, 4-bit, fp16 | ddp (4 GPUs) | 50.0M (0.58%) | **0.68 -> 0.0025** | 27.5 -> 19.5 |
| 4 | OLMo-2-32B, 4-bit, bf16 | fsdp (4 GPUs) | 134.2M (0.41%) | **0.28 -> 0.00021** | 1.12 -> 0.13 |

- **Gemma is now in line with every other model** — the ~26-loss anomaly is
  gone, confirming the single-token diagnosis end to end.
- Merge + reload re-verified after the change: step 1 and step 3 merged
  models both reload and generate the trained answer; step 4's gathered
  adapter is still 536,991,984 bytes (= the full 134,217,728 params, not a
  rank shard), so the FSDP collective save is unaffected.
- Absolute losses are now much lower across the board because the objective
  is the short response only. **These numbers are not comparable to the
  prompt-included column** — they measure a different objective, not a
  better model.
- Memory behavior is unchanged by loss masking, so the `NEED_PER_GPU`
  calibration recorded in `general.yaml` still stands.

Still not built (unchanged): `advanced.chat_template_override` remains
plumbed-but-unconsumed. Completion-only masking is the natural place to wire
it in later, but it is deliberately not part of this change.

### Superseded notes on the same issue (kept for the reasoning trail)

Step 3 ran at loss ~26 and eval_loss 27.5 -> 19.5 — falling and with rising
token accuracy (0.57 -> 0.86), so it *is* learning and the DDP mechanics are
validated, but a cross-entropy of ~25 is worse than uniform over Gemma's
256k vocab (~12.4 nats) while `entropy` is only ~0.6. That combination means
the model is *confidently* assigning near-zero probability to target tokens at
some positions. **Differential already run — do not repeat it:**

- **Not precision.** A single-GPU **bf16** run of the same config reproduces it
  almost exactly (loss ~25.3, eval 26.6 -> 22.7). The initial "Gemma is
  unstable in fp16" reading was wrong.
- **Not the new DDP code.** It reproduces single-GPU, single-process.
- **Not 4-bit quantization generally.** olmo2-1b-dev at 4-bit is well-behaved
  (2.9 -> 0.35).

Remaining suspects: label/pad masking for this tokenizer (Gemma has a real
`<pad>`, so `train.py`'s `pad_token is None` fallback never fires), or
quantization of Gemma's tied embeddings / 256k head. Worth resolving before
any Gemma profile is treated as production-ready.

### FSDP VALIDATED on 4x T4 — `allenai/OLMo-2-0325-32B-Instruct`

Substituted for the blocked `gemma-4-31b` (below) because it is dense,
text-only, **ungated**, and its `olmo2` architecture is supported by the
*current* pin. 32B at 4-bit is ~17GB, which **cannot** fit any single 15GB
T4, so this genuinely forces sharding. `model_profile=custom` was used, so
the resolver reached `fsdp` through its generic `FOOTPRINT=20` fallback
(-> `NEED_PER_GPU=38` vs 15GB/GPU) — i.e. driven by the fit calculation, not
a hardcode, as HANDOFF requires.

| metric | result |
|---|---|
| strategy | `fsdp` (accelerate launch + `app/fsdp_config.yaml`), 4 ranks |
| params | 32,368,497,664 total / **134,217,728 trainable (0.41%)** |
| precision | bf16 (aligned with `bnb_4bit_quant_storage`), 4-bit NF4 base |
| per-GPU VRAM | ~9381MiB during training (GPU0 4309MiB); **13075MiB balanced peak** during the state-dict gather |
| eval_loss | 1.12 -> 0.39 -> 0.12 -> 0.15 -> 0.14 -> 0.13 |
| grad_norm | non-zero throughout (3.01 -> 0.42) |
| exit | 0, zero tracebacks/OOM; report + plots written |

**Sharding is proven, not inferred:** ~17GB of 4-bit weights cannot fit one
15GB card, yet no GPU exceeded 13.1GB and all four were balanced.
**The collective save is proven too:** the saved
`adapter_model.safetensors` is 536,991,984 bytes = 134,247,996 fp32 values,
matching the *full* 134,217,728 trainable params — a rank-local shard would
have been ~1/4 that size. The adapter then reloaded onto the 4-bit base and
generated the trained answer correctly.

#### Two real bugs this run found (both invisible without a live multi-GPU run)

1. **Every rank allocated on cuda:0.** `accelerate launch` sets `LOCAL_RANK`
   but does not set the process's CUDA device; an Accelerator normally does,
   and under SFTTrainer one only exists *after* `build_base_model()`. So all
   four ranks loaded onto GPU 0 and `caching_allocator_warmup` OOM'd it.
   Measured: **GPU0=14707MiB, GPU1-3=3MiB** (three GPUs completely idle).
   The ddp path was spared only by its explicit `device_map`.
2. **`is_fsdp_enabled()` was False at load time**, so transformers skipped
   its rank0-only/meta-device efficient load and **every rank materialized
   the entire model**: measured **14833MiB on all four T4s** before OOM. The
   config was fine (`ACCELERATE_USE_FSDP=true`,
   `FSDP_CPU_RAM_EFFICIENT_LOADING=true` all confirmed set) — that check
   additionally requires `torch.distributed` to be *initialized*, which it
   is not until an Accelerator exists.

Both are fixed by `init_distributed_for_loading()` in `app/train.py`, called
from `main()` before the model loads: it pins `cuda:LOCAL_RANK` and, for
fsdp, constructs `PartialState()` to initialize the process group early
(it is a singleton, so the Trainer's later Accelerator reuses it).

**Note for future capacity planning:** with FSDP+QLoRA the binding
constraint is the *load* peak, not the training steady state, and it is only
survivable because of `fsdp_cpu_ram_efficient_loading`. The resolver's
`NEED_PER_GPU` models the training footprint, so it does not describe this.

#### Not done for the 32B case

`merge_adapters_standalone()` is **still unexecuted.** A full merge needs the
base in bf16 (~64GB) plus a ~64GB write, and HANDOFF §8 explicitly prefers
serving base+adapter over a single-process merge at this scale. Merge/reload
*is* validated at <=7B (steps 1-3). Adapter reload+generate is validated at
32B, which is the property that actually matters for serving.

### Blocked: original step 4 (`gemma-4-31b`)

Cause is not our code: `google/gemma-4-31B-it` declares `model_type: gemma4` /
`Gemma4ForConditionalGeneration`, and **no released transformers recognizes
it** — 4.56.2 (pinned) and 4.57.6 (latest 4.x) both raise
`KeyError: 'gemma4'`. `coder3101/gemma-4-31B-it-heretic` shares the identical
`model_type`, so it is not a workaround. HF access/gating is *not* the blocker
(a token with access was verified).

`transformers==5.16.1` **does** have `gemma4` (plus `gemma4_text`,
`gemma4_vision`, `gemma4_unified`, ...). Migration cost was measured in a
scratch copy: **three edits** — `use_auth_token`->`token`,
`torch_dtype`->`dtype`, drop `logging_dir` (removed from `SFTConfig`, which
lost 20 fields overall: 149 -> 129) — after which olmo2-1b-dev at 4-bit trains
correctly on 5.16.1 with **unchanged** `trl==0.23.0`/`peft==0.20.0`
(eval_loss 1.49 -> 0.55, healthy grad_norm, merge OK, report/plots fine —
`log_history` still stores floats; only console formatting changed).
The first two edits have since **landed on the 4.x pin** (see "Built this
session"), so only the `logging_dir` item remains.
Note `trl 0.23.0` declares `transformers>=4.56.1` with no upper cap *only
because 5.x did not exist yet* — that combination is untested upstream.

**TRAP — 5.x silently blanks the live TensorBoard dashboard.** 5.x removes
`logging_dir` (and `overwrite_output_dir`) with **no replacement field**, so
the log directory is no longer configurable and is derived from `output_dir`.
Measured on 5.16.1: events were written to
`<output_dir>/adapters/runs/<timestamp>_<host>/events.out.tfevents...`
(because `SFTConfig(output_dir=...)` is set to `adapter_dir`), while
`app/start-template.sh` serves `<output_dir>/tensorboard/` — **which stayed
empty**. Training exits 0 and the offline report is still correct, so the only
symptom is a permanently blank dashboard at the endpoint; and since
`train.py` still `mkdir`s that empty directory, TensorBoard starts happily and
shows "No dashboards are active", which reads as *"nothing logged yet"* rather
than a fault. On the 4.x pin, events correctly land in
`<output_dir>/tensorboard/` (verified, 16.5KB). **Any 5.x migration must
re-point `start-template.sh`'s `--logdir` (or set the log dir another way) in
the same change**, or the workflow's headline feature dies quietly.

**Decision deferred to the team.** The bump is cheap to apply but carries
re-validation debt across all six profiles (MoE branch, ddp, fsdp, multimodal,
gpt-oss/MXFP4 were all validated — or written — against 4.x), and it does not
unblock the gpt-oss critical path, which still needs Hopper.

**If the FSDP path is wanted before that decision**, substitute a large dense
model that the *current* pin already supports. Verified candidates:
`allenai/OLMo-2-0325-32B-Instruct` (`Olmo2ForCausalLM`, text-only, 64 layers,
**ungated**, `olmo2` supported by 4.56.2) — recommended, since 32B at 4-bit
will not fit one 15GB T4 and therefore genuinely forces sharding.
**Avoid `google/gemma-3-27b-it` for this purpose**: it is
`Gemma3ForConditionalGeneration` with a vision config, so it would drag the
never-verified multimodal loader path into the FSDP test and confound two
unknowns at once.

---

## Status (2026-09-03, single T4)

### Done and verified on GPU

**All six local checks pass, and both dev profiles genuinely learn** (verified
by falling eval loss and non-zero `grad_norm`, not merely by "the run
completed" — see the correction note at the bottom).

| configuration | trainable params | eval_loss trajectory |
|---|---|---|
| `olmo2-1b-dev`, no quant, fp16 | 48.2M (3.1%) | 1.55 → 0.36 |
| `olmo2-1b-dev`, 4-bit, fp16 | 48.2M (3.1%) | 1.44 → 0.35 |
| `olmo2-1b-dev`, 4-bit, bf16 | 48.2M (3.1%) | 2.79 → 0.31 |
| `olmoe-1b-7b-dev` (MoE), 4-bit, bf16 | 16.8M (0.24%) | 2.24 → 0.29 |

- Container builds from `app/build-container.sh` (8.3 GB SIF); `%test` passes;
  `--nv` exposes the GPU inside the container; compute capability correctly
  read as non-Hopper so the MXFP4 path logs its bf16 fallback rather than
  failing silently.
- Dense (`olmo2-1b-dev`) and MoE (`olmoe-1b-7b-dev`) end-to-end:
  load → LoRA → train → held-out eval loss → save adapters → merge → reload,
  plus the offline report (`report/metrics.json`, PNG plots, `report.html`).
- TensorBoard + `app/tb_proxy.py`: `<base href>` injection verified by `curl`.
- `cancel.sh` kills the training and TensorBoard/proxy processes with no
  orphans left behind.
- Static checks: `bash -n` on all shell scripts, `py_compile`, YAML parse.
- `app/start-template.sh`'s generated `launch-service.sh` / `cancel.sh` were
  dry-run rendered and syntax-checked (fake inputs, no `pw` involved).

### Built (files)

- `app/train.py` — training entrypoint (rewrite of the legacy
  `pw_finetune.py`). Model-profile-aware; LoRA targeting is **auto-detected
  from the loaded model**, not hardcoded per profile: fused expert *Parameter*
  tensors (gpt-oss) → PEFT `target_parameters`; per-expert `nn.Linear` MoE
  (OLMoE/Mixtral-style) → attention-only `target_modules`; dense → the full
  dense list. Always-on held-out eval loss. Writes the post-training offline
  report. Asserts `trainable != 0` before training (guards HANDOFF §8.5a).
- `app/train-entrypoint.sh` — env-var → CLI translation, runs inside the
  container. Owns no TensorBoard lifecycle (that moved to start-template.sh).
- `app/tb_proxy.py` — unchanged from the legacy workflow; reused as-is.
- `app/controller.sh` — login-node setup; resolves the container by
  `container_mode` (`registry` via `oras_pull_file` / `sif_path` / `build`).
- `app/start-template.sh` — the service. TensorBoard (behind `tb_proxy.py`) is
  bound to the endpoint's `{port}` **only while training runs**; training runs
  in the foreground of a generated `launch-service.sh`; on exit TensorBoard and
  the proxy are torn down and the run completes, so the endpoint retires itself.
  Writes `cancel.sh` before backgrounding anything.
- `app/build-container.sh` + `app/finetune.def` + `app/requirements.txt` —
  standalone container build, deliberately **inside `app/`** (not at the
  workflow root as `streamlit` does) so `controller.sh`'s on-the-fly `build`
  mode can invoke the same single source of truth. Falls back to a `sudo` build
  when `--fakeroot` is unavailable (`newuidmap` not setuid on this box).
- `yamls/general.yaml` — ported from the draft's legacy `sessions:` pattern to
  the endpoint pattern (`preprocessing` → `resolve_strategy` →
  `session_runner` via `script_submitter/v3.6` → `wait_for_endpoint`), keeping
  the draft's model matrix / resolver / container-mode / evaluation design.
- `legacy/` — the six pre-port salvage scripts, moved out of `app/` (which may
  only hold runtime files, since it is the sparse-checkout root).
- `README.md`.

### Not done / not verified

- **Nothing has been run through the `pw` CLI.** No `pw workflows
  create/update/run`, no live endpoint, no `wait_for_endpoint`, no real
  `script_submitter` submission, no scheduler path. The YAML is
  static-checked only. This is the single largest untested area.
- `yamls/general.yaml` checkout `branch:` points at **`add-finetuning`** for
  iteration. **Flip to `canary` before merging.**
- The draft's ACTIVATE ternary expressions (`base_model_id`,
  `lora.quantization` defaults) are **unvalidated** — the parser fails
  *silently* on malformed expressions (HANDOFF §8). Check them in the Build
  tab's live form preview first.
- `gpt-oss-20b` / `gpt-oss-120b`: code paths written per HANDOFF §3
  (`Mxfp4Config(dequantize=True)`, fused-expert `target_parameters`) but
  **never executed** — needs Hopper (cc ≥ 9.0) for true MXFP4.
- `gemma-4-31b`: multimodal loader branch written, **never executed** (30B
  will not fit a T4).
- ~~DDP / FSDP: `resolve_strategy` emits `strategy`/`launcher` as job outputs but
  `train-entrypoint.sh` **ignores them** — single-GPU `python` launch only. The
  FSDP/ZeRO-3 config file is still a `TODO(stub)`.~~ **Superseded 2026-09-04:**
  both are wired and `app/fsdp_config.yaml` exists. **DDP is verified on 4x T4
  (gemma-1.1-7b) and FSDP is verified on 4x T4 (OLMo-2-32B, 4-bit, sharded —
  a model that cannot fit on one card)** — see "Session 2026-09-04".
- `advanced.chat_template_override` is plumbed but **not consumed** by
  `train.py`; the tested path is the flat `prompt_field` → `text` one. Real
  chat-template application (harmony / gemma4) is unbuilt.
- `evaluation.quality_eval_type` / `quality_eval_command` are form-only
  (HANDOFF §5's pluggable slot) — no implementation.
- `thumbnails/` — not created; needed for a marketplace registration.
- ~~The `NEED_PER_GPU = footprint*1.6 + 8` heuristic is still a guess.~~
  **Updated 2026-09-04:** the constant is now +6 (the +8 form mis-selected
  `fsdp` for gemma-1.1-7b on 15GB cards) and `general.yaml` carries the
  measured-vs-predicted numbers for the two 7B-class 4-bit profiles. Still
  unvalidated above ~7B, and the binding constraint turned out to be the
  rank-0 `merge_and_unload()` spike rather than the training loop.
  HANDOFF §2's "~4 GB (bf16)" frozen footprint for OLMoE still looks wrong —
  7B params in bf16 is ~14 GB; that table appears to count *active* rather
  than *resident* params. (The `FOOTPRINT` table in `general.yaml` is on a
  4-bit basis, which is why FOOTPRINT=4 there measures out about right.)

---

## Picking it up on new hardware

1. **Build the container** (~10 min, no GPU needed):
   `bash workflows/finetuning/app/build-container.sh /path/to/finetune.sif`
   It tries `--fakeroot`, then falls back to `sudo`. Confirm the GPU is visible:
   `singularity exec --nv finetune.sif python3 -c "import torch; print(torch.cuda.get_device_capability(0))"`
2. **Re-run the dev-model smoke checks** before anything ambitious, to confirm
   the new box behaves. Invoke `app/train-entrypoint.sh` directly under
   `singularity exec --nv` with the env-var contract (no `pw` needed) —
   `MODEL_PROFILE`, `BASE_MODEL_ID`, `DATASET_SOURCE=local`,
   `LOCAL_DATASET_PATH`, `OUTPUT_DIR`, plus hyperparameters; see
   `app/start-template.sh`'s export block for the full list. A tiny synthetic
   JSONL with a `prompt` field is enough (the one used here was scratch-only
   and is not in the repo).
   **Pass criterion: falling `eval_loss` AND non-zero `grad_norm`.** A run that
   merely completes and writes files proves nothing (HANDOFF §8.5a).
3. **Then the real remaining work**, in HANDOFF §6's order: gpt-oss-20b on one
   Hopper GPU (validates the single-container decision for the whole matrix),
   then the FSDP/ZeRO-3 config, then gpt-oss-120b.
4. **Independently, whenever a PW-authenticated session is available:** the
   end-to-end platform test (`pw workflows create/update` with an **absolute**
   YAML path, `pw workflows run`, `pw endpoints list`, open the endpoint,
   confirm TensorBoard renders through the real session proxy, let training
   finish and confirm the endpoint retires itself, and separately cancel
   mid-run and confirm `cancel.sh` cleaned up). Exercise `container_mode=build`
   first (it needs no published image), then `registry` once one is pushed.

### Machine-specific notes from this session (likely differ elsewhere)

- `--fakeroot` container builds fail here (`newuidmap` not setuid root);
  passwordless `sudo` was available and is used as the fallback.
- The base image pin in `app/finetune.def` is
  `nvidia/cuda:12.4.1-devel-ubuntu22.04`, chosen for public pullability rather
  than to match HANDOFF §3.5's CUDA 12.9 anchor. The pip pins in
  `app/requirements.txt` (torch cu128 wheels) are what actually determine the
  runtime CUDA, so the base tag is not load-bearing — but revisit it on Hopper
  hardware before trusting the MXFP4 path.
- Defaults chosen for robustness, revisit for large models: `--optim
  adamw_torch` (never `paged_*`, HANDOFF §8.5b — use `adamw_bnb_8bit` when
  optimizer state is the constraint), `gradient_checkpointing` off,
  `bf16` off. All three are exposed as `advanced.*` workflow inputs.

---

## Correction to the record

An earlier report in this session claimed both dev models were validated. That
was **wrong for the quantized/MoE path**: those runs completed and wrote
plausible adapters, merged weights and reports while training **zero
parameters** (HANDOFF §8.5a). Only the unquantized dense run was genuinely
learning at that point. The bug was found by noticing `eval_loss` was
*bit-identical* across checkpoints, then confirmed by `grad_norm == 0.0` and
`trainable == 0`. The table at the top of this file is from runs re-verified
after the fix. Treat "the pipeline completed" as no evidence at all.
