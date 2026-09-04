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

### Open issue: Gemma-1.1-7B trains at an implausible loss scale

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
