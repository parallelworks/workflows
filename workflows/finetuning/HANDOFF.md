# Generalized LoRA/QLoRA Fine-tuning Workflow — HANDOFF

> **What this file is:** the memory of a design conversation that produced
> `workflow.yaml`. It carries decisions + verified facts that CANNOT be
> rederived by reading the repo (why one container, why OLMo, the verified
> gpt-oss version set, the MXFP4-dequantize subtlety, what's deferred).
>
> **How to use it (next Claude Code session):**
> 1. Read this file for context — do NOT start editing yet.
> 2. Enter **plan mode** and inspect the REAL repo: read the existing workflow
>    scripts under `app/` (see §1.5 for the layout — scripts live in `app/`, NOT
>    `scripts/`), the directory layout, what's actually installed. This
>    file was written WITHOUT ever seeing the real `app/` scripts — it is full of
>    `TODO(stub)` markers precisely because of that. Plan mode grounds those
>    stubs against ground truth. Use the repo's `.claude/skills/activate-workflows/`
>    skill (§1.5) — it encodes the workflow-authoring process.
> 3. Write the grounded implementation plan to **`PLAN.md`** (separate file), then
>    execute it. This HANDOFF is the input; `PLAN.md` is the output.
>
> **`PLAN.md` now exists** (written + executed during the first live-GPU session,
> 2026-09-03). Read it FIRST for current state — what is built, what is verified
> on real hardware, and what remains. This HANDOFF has been left as the design
> record; where the two disagree about *state*, `PLAN.md` is authoritative.
> §8.5 below records the failure modes that session actually hit — read it before
> touching the PEFT/quantization wiring, one of them silently trains nothing.
>
> The repo has a top-level `CLAUDE.md` that is SHARED across branches and
> contributors. It intentionally does NOT reference this work, and must not be
> edited to add a breadcrumb to `HANDOFF.md`/`PLAN.md` — a pointer that's
> irrelevant (or dangling) on other branches would be noise for everyone else.
> Discovery of this work happens by a person explicitly opening `HANDOFF.md`,
> not via anything in `CLAUDE.md`. Treat `CLAUDE.md` as read-only durable
> conventions; keep all phase-specific context in `HANDOFF.md` / `PLAN.md`.
>
> Treat everything here as design intent + verified facts, not as finished code.

## 0. What we're building

A **generalized** single-node LoRA/QLoRA fine-tuning workflow in ACTIVATE YAML
(Parallel Works), evolving the original `parallelworks/activate-medical-finetuning`
(which only handled dense 7–8B models: Llama/Mistral/Gemma).

Goal, in the user's words: point at hardware (1 node, 1+ GPUs), select a model,
point at an on-disk dataset, run, and watch training stats on a live dashboard.
It is **not** medical-specific — that was just the starting repo. It is a general
tuner. **No refusal/safety-behavior options are in scope right now** (explicitly
deferred by the user; see §7).

Design principle: the form exposes a **hardware profile** and a **model profile**;
a `resolve_strategy` job derives precision/parallelism/launcher from
(model footprint × GPUs). Each model is a *configuration*, not a code path.

## 1. Current state

> **SUPERSEDED — see `PLAN.md`.** This section described the pre-port draft. As
> of 2026-09-03 the endpoint-pattern port is written and the two dev profiles
> (`olmo2-1b-dev`, `olmoe-1b-7b-dev`) train end-to-end, verified on a real GPU.
> The text below is kept only as the record of where this started.

- `workflow.yaml` — DRAFT. Parses as valid YAML. Structure is real; several
  pieces are deliberately stubbed (marked `# TODO(stub)`). **IMPORTANT: the draft
  uses the LEGACY session pattern (`sessions:` block + `session_runner`); the repo
  has moved to the endpoint pattern — see §1.5. The design decisions carry over;
  the job scaffolding must be ported.**
- The heavy training-side logic will live in `app/` (NOT `scripts/` — see §1.5).
  The workflow directory is seeded with the LEGACY workflow's training script at
  **`app/run.sh`** as SALVAGE REFERENCE (see §1.6 for how to use it). The real,
  ported training entrypoint(s) — `app/controller.sh` + `app/start-template.sh` —
  have NOT been written. **Writing/verifying them is the main work.**
- The generated draft YAML is placed at `yamls/general.yaml` (repo convention —
  the platform expects variant YAMLs named by deployment, not `workflow.yaml`).
- Nothing has been run on a GPU yet. All memory numbers are estimates from model
  cards + arithmetic, not measured.

## 1.5 Repo conventions (from parallelworks/workflows DeveloperGuide.md, canary)

VERIFIED against the Developer Guide (Sep 2026). This corrects several assumptions
baked into the draft `workflow.yaml`:

- **Directory layout.** A workflow lives in ONE directory `workflows/<name>/`:
  - `app/` — holds EVERYTHING the run needs (scripts + support files). This is the
    ONLY subtree the workflow sparse-checkouts. Our runtime scripts go here:
    `app/controller.sh` + `app/start-template.sh` (the two entrypoints, see below),
    `app/build-container.sh`, `app/finetune.def`, etc. (The seeded legacy
    `app/run.sh` also sits here as salvage reference — §1.6 — but is not itself an
    entrypoint.)
  - `yamls/<variant>.yaml` (e.g. `yamls/general.yaml`) — the workflow YAML. Lives
    OUTSIDE `app/`. **Hard rule:** preprocessing steps glob `app/*` into every run,
    so a YAML (or any non-runtime file) inside `app/` gets swept in — keep it out.
  - `thumbnails/`, README, **and this `HANDOFF.md`** — also OUTSIDE `app/`
    (non-runtime; would be swept into every run if placed in `app/`). HANDOFF.md
    sits at `workflows/activate-finetuning/HANDOFF.md`.
- **NOT `scripts/`.** Everywhere this handoff or the draft says `scripts/run.sh` /
  `scripts/build_container.sh`, the location is `app/…`. Note: `app/run.sh` here is
  the SEEDED LEGACY reference to mine (§1.6), NOT the workflow entrypoint — the real
  entrypoints are the `app/controller.sh` + `app/start-template.sh` split below.
  The container builder is `app/build-container.sh`. Rename throughout when implementing.
- **Two entry scripts, not one monolithic run.sh:**
  - `app/controller.sh` — runs FIRST on the controller/login node, which ALWAYS has
    internet. Put internet-needing work here: HF model download, container
    pull/build. Must be idempotent (check-before-install).
  - `app/start-template.sh` — starts the service; MUST listen on `service_port`,
    write a `cancel.sh` (at the very top), and end with `sleep inf` (or run in
    foreground). Our training launch + TensorBoard-on-service_port maps here.
  - NOTE: the compute node may NOT have internet — another reason downloads/pulls
    belong in controller.sh, not start-template.sh.
- **Endpoint pattern (current) vs session pattern (legacy).** The current YAML has
  three jobs: (1) `preprocessing` — `parallelworks/checkout` (sparse:
  `workflows/<name>/app`, plus `tools/...` if used), generate `inputs.sh` from form
  values + `PW_*`, run `inputs.sh + controller.sh` inline, assemble the start script;
  (2) `session_runner` (name kept for history) — submit via
  `workflows/script_submitter/v3.6/<variant>.yaml` (`uses: github/parallelworks/workflows@canary`);
  (3) `wait_for_endpoint` — poll `pw endpoints list` until `<service.name>-${PW_RUN_SLUG}`
  is online. Our draft's `sessions:`/`session_runner` interactive_session block is the
  LEGACY form. Convert per `.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`.
- **Copy a real workflow, don't write from scratch.** For our Singularity/SIF case,
  `workflows/streamlit/` is the template: it pulls its SIF via `oras`, keeps a `.def`
  + `build-container.sh` alongside — near-exact match for our container story (§3.5).
  `workflows/webshell/` is the smallest complete example.
- **Use the shipped Claude Code skill.** The repo has `.claude/skills/activate-workflows/`
  encoding this whole process + platform reference. The next session should invoke it:
  *"Using the activate-workflows skill, create a new interactive session workflow…"*.
  (This is a REASON to start Claude Code at the repo top level, where `.claude/` is
  discoverable — see §6.)
- **Container pull gotcha:** ghcr rate-limits anonymous pulls; use
  `tools/oras/libs.sh:oras_pull_file` (it retries) and keep packages public. This
  affects our "registry" container mode (§ workflow container modes).
- **Testing:** the YAML pulls the repo from GitHub at RUN time — local edits are
  invisible until pushed to the referenced branch. Point checkout `branch:` at a dev
  branch while iterating; restore to `canary` before PR (canary only accepts PRs).
  Use an ABSOLUTE YAML path with `pw workflows run` (relative = parsed as git host).

## 1.6 Two sources, two purposes — do NOT confuse them

Building this workflow draws on two different existing artifacts for two DIFFERENT
things. Keeping them straight avoids both failure modes (blindly copying the old
workflow, or throwing away genuinely reusable code):

- **SCAFFOLDING → copy from `workflows/streamlit/` (current endpoint pattern).**
  The job structure, the checkout/preprocessing, the `controller.sh` /
  `start-template.sh` split, the SIF-via-`oras` pull, the `.def` + `build-container.sh`
  layout — take all of this from `streamlit`, which is a current, working
  Singularity-service workflow. Do NOT reconstruct scaffolding from the legacy
  workflow; its `sessions:`/`session_runner` structure is exactly what we're leaving.
  (First verify `streamlit` is still the closest SIF template — repos drift; the
  guide named it but confirm against the actual repo.)

- **TRAINING LOGIC → mine from the legacy `app/run.sh` (seeded into this dir).**
  The legacy workflow already fine-tunes the dense 7–8B case (Llama/Mistral/Gemma)
  — which overlaps directly with our dense path (Gemma, and the OLMo dev model that
  gets tested FIRST). Read `app/run.sh` to HARVEST reusable specifics that are
  tedious to rederive: the exact LoRA config + merge invocation, dataset loading /
  prompt formatting, trainer argument names, any environment quirks. Reuse the
  domain code; discard the scaffolding it's wrapped in.
  - CAVEAT: it's unverified how substantial or extractable that logic is. If it
    turns out thin or too entangled with the legacy launch to separate cleanly,
    full bypass is fine — build the training script fresh from §3 (gpt-oss cookbook
    config) + the dense specifics. Plan mode decides this against the real code.
  - The gpt-oss MoE path (target_parameters, MXFP4, harmony) and the FSDP/120b path
    are NEW — the legacy workflow has nothing for them; those come from §3 / §3.5.


All verified against model cards / official docs (Aug–Sep 2026).

| Profile key | HF ID | Arch | Total / active | Frozen base footprint | Fits QLoRA 1×94GB? |
|---|---|---|---|---|---|
| `olmo2-1b-dev` | `allenai/OLMo-2-0425-1B` | dense | 1B | ~2 GB | trivially — DENSE dev/smoke test |
| `olmoe-1b-7b-dev` | `allenai/OLMoE-1B-7B-0924-Instruct` | **MoE** | 7B / 1B | ~4 GB (bf16) | trivially — MoE dev/smoke test |
| `gemma-1.1-7b` | `google/gemma-1.1-7b-it` | dense | 7B | ~4–5 GB | easily |
| `gemma-4-31b` | `google/gemma-4-31B-it` | dense, **multimodal** | 30.7B | ~15–18 GB (4-bit) | yes |
| `gpt-oss-20b` | `openai/gpt-oss-20b` | **MoE**, MXFP4 | 20.9B / 3.6B | ~13 GB (native) | comfortably |
| `gpt-oss-120b` | `openai/gpt-oss-120b` | **MoE**, MXFP4 | 116.8B / 5.1B | ~61–63 GB (native) | borderline; needs FSDP across ≥2 |

Notes that matter for code:
- **gemma-4-31b is multimodal** (text+image). For text-only training you still
  load it through the multimodal processor path; the processor expects to handle
  image tokens even when none are present. Chat template is `gemma4` (distinct
  from gemma-1.1's template). Uses hybrid local/global attention. The
  `coder3101/gemma-4-31B-it-heretic` checkpoint the user mentioned shares this
  profile EXACTLY — it's an abliterated derivative, same architecture; slots in
  via "custom". (We are NOT adding refusal tooling; it's just a drop-in ID.)
- **gpt-oss models ship in MXFP4** natively (~90% of params, the expert weights).
  See §3 for the critical load detail.
- **Dev models (two, one per architecture family)** — both from Ai2 (Allen
  Institute for AI, Seattle; US-origin), both Apache-2.0 and fully open
  (weights + data + training code), both ungated (no HF token):
  - `allenai/OLMo-2-0425-1B` — dense, standard Transformer. The PRIMARY dev
    model: exercises the full dense load→LoRA→train→merge→reload path in minutes
    on CPU/small GPU. Mirrors the gemma-1.1 dense code path.
  - `allenai/OLMoE-1B-7B-0924-Instruct` — MoE, 7B total / 1B active, 16 layers,
    8-of-64 experts per layer. The MoE dev model: cheaply exercises the
    expert-targeting LoRA branch (PEFT `target_parameters`) so it isn't only ever
    tested by a full 20B/120B run. Mirrors the gpt-oss MoE code path *structurally*.
  - **IMPORTANT caveat on the MoE dev model:** OLMoE and gpt-oss are DIFFERENT MoE
    implementations (different layer counts, routing — OLMoE 8-of-64 vs gpt-oss
    120b's 4-of-128, and different module/param names). A green OLMoE run proves
    the framework's MoE *branch* works end-to-end (expert-targeting LoRA runs,
    resolver treats it as MoE, merge/reload works) — it does NOT mean the exact
    `target_parameters` strings carry over to gpt-oss. Each MoE model needs its
    own expert-layer targeting derived from ITS architecture. Don't over-generalize
    from OLMoE to gpt-oss beyond "the branch is wired correctly."
  - (No Qwen — excluded intentionally on model-provenance grounds. Do not
    reintroduce Qwen or other non-US-origin models as the dev default.)

## 3. VERIFIED gpt-oss fine-tuning tooling (from OpenAI cookbook, Aug 2025)

Source: https://cookbook.openai.com/articles/gpt-oss/fine-tune-transfomers
Cross-checked against DataCamp, Firecrawl, Medium tutorials — all consistent.

### Library version floor (pin at least these in the container)
```
torch         # cu128 build
trl           >= 0.20.0
peft          >= 0.17.0     # target_parameters support lands here
transformers  >= 4.55.0     # gpt-oss + Mxfp4Config support
trackio                     # optional logging; we use TensorBoard instead
# openai-harmony            # harmony format helpers (some tutorials use it)
```
`target_parameters` in `LoraConfig` is the NEW peft feature that makes MoE expert
targeting work — this is why the version floor matters. Older peft silently lacks it.

### Load pattern (the subtlety we must get right)
```python
from transformers import AutoModelForCausalLM, Mxfp4Config
quantization_config = Mxfp4Config(dequantize=True)   # <-- dequantize MXFP4 -> bf16 for training
model_kwargs = dict(
    attn_implementation="eager",
    torch_dtype=torch.bfloat16,
    quantization_config=quantization_config,
    use_cache=False,          # gradient checkpointing is on
    device_map="auto",
)
model = AutoModelForCausalLM.from_pretrained("openai/gpt-oss-20b", **model_kwargs)
```
**Key fact:** you do NOT train in MXFP4. You dequantize to bf16 for the forward/
backward and train LoRA adapters on top. "MXFP4 fine-tuning" is not supported;
BF16/FP16 and QLoRA-4bit are. This means the *training* footprint of gpt-oss is
higher than the 13/63 GB on-disk numbers imply — budget for the dequantized bf16
working set. VALIDATE THIS ON GPU (see §6) — it affects whether 120b needs FSDP
even on 2×94GB.

### LoRA config for gpt-oss (MoE) — canonical form
```python
from peft import LoraConfig
peft_config = LoraConfig(
    r=8, lora_alpha=16,
    target_modules="all-linear",           # attention + linear layers
    target_parameters=[                     # PLUS expert projections, per-layer
        "7.mlp.experts.gate_up_proj",  "7.mlp.experts.down_proj",
        "15.mlp.experts.gate_up_proj", "15.mlp.experts.down_proj",
        "23.mlp.experts.gate_up_proj", "23.mlp.experts.down_proj",
    ],
)
```
- Layer indices (7/15/23) are a **sampled subset**, not fixed — a tunable knob.
  Expose as an override; don't hardcode as a requirement. 20b has 24 layers,
  120b has 36 — scale the sampled indices accordingly.
- Result on 20b: ~15M trainable params ≈ 0.07% of the model, ~16 MB adapter.
- Alternative stack: **Unsloth** uses a *linearized* gpt-oss checkpoint and reverts
  to the familiar dense list `["q_proj","k_proj","v_proj","o_proj","gate_proj",
  "up_proj","down_proj"]` for QLoRA. Different path, same outcome. Pick ONE and
  keep the container consistent with it.

### Data format
gpt-oss uses the **Harmony** response format (channels: `analysis` for CoT,
`final` for user-facing; roles `developer`/`user`/`assistant`). TRL's `SFTTrainer`
applies the chat template automatically if the tokenizer has it. The medical/other
dataset must be rendered to harmony for gpt-oss, and to `gemma`/`gemma4` for the
Gemma models. **Wrong template = quiet quality loss, not an error.** Per-profile
template selection is a first-class concern in `run.sh`.

### Trainer (TRL) — reference hyperparameters from the cookbook
```python
from trl import SFTConfig, SFTTrainer
SFTConfig(learning_rate=2e-4, gradient_checkpointing=True, num_train_epochs=1,
          per_device_train_batch_size=4, gradient_accumulation_steps=4,
          max_length=2048, warmup_ratio=0.03,
          lr_scheduler_type="cosine_with_min_lr",
          lr_scheduler_kwargs={"min_lr_rate": 0.1})
```
Cookbook run: 20b on ONE H100-80GB ≈ 18 min for 1k examples. Confirms 20b is a
single-GPU job; 120b is the one that needs sharding.

## 3.5 Containerization — ONE Singularity container for all 6 models

**Decision: build a SINGLE Singularity (.sif) container for all six models.**
Verified feasible (Sep 2026). Reasoning + evidence:

- All 6 models share one stack (transformers/peft/trl/accelerate/torch + SFTTrainer
  + LoRA). They are configurations of one framework, not six frameworks.
- The ONLY real dependency tension is the gpt-oss **MXFP4 Triton-kernel** path.
  Every conflict report online traces to that one subsystem — getting a matched
  set of torch/triton/triton_kernels/transformers — NOT to any model-vs-model
  clash. Gemma and OLMo are conventional and run fine on the newer stack.
- Critical: if the MXFP4 Triton kernels are missing/mismatched, gpt-oss does NOT
  error — transformers prints "MXFP4 requires triton>=3.4.0 and kernels installed,
  we will default to dequantizing the model to bf16" and proceeds in bf16. Since
  our TRAINING path already dequantizes to bf16 (§3), this is a
  performance/inference concern, not a training blocker. So "build to gpt-oss's
  Triton requirements and the other 5 ride along" is safe.
- Existence proof: gpt-oss fine-tuned on HPC inside Singularity/Apptainer on
  H200/A100 nodes, PyTorch 2.8.0 / CUDA 12.9 devel image
  (github.com/hwang2006/finetuning-gpt-oss-on-hpc).

**A concrete working version set people report (anchor, then verify current):**
```
torch 2.8 / CUDA 12.9    transformers==4.56.2   trl==0.23.0
triton==3.4.0            triton-kernels==0.1.0  accelerate==1.10.1
peft>=0.17.0             tokenizers==0.22.1
```

**Why Singularity (not Docker):** HPC-standard, rootless, native NVIDIA GPU
support via the `--nv` flag; it's what PW clusters run. No reason to avoid it.
Note: on most clusters `singularity` is now a symlink to **Apptainer** (renamed
project) — same tool. `.sif` is the image format.
- Singularity gotcha to record: `--nv` binds the HOST CUDA driver/libraries into
  the container, so the container's CUDA/torch must be compatible with the host
  driver. MXFP4 kernels additionally need **compute capability ≥ 9.0 (Hopper: H100/
  H200/B100)** to run in true MXFP4 — on older cards it dequantizes to bf16. Our
  target hardware (H100 NVL) is Hopper, so fine. Record this in the build script.

**FALLBACK (only if the single container is empirically proven impossible):**
split exactly at the gpt-oss boundary → one container for gpt-oss, one for
{Gemma + OLMo}. Do NOT split per-model or six ways; Gemma and OLMo have no
conflicts with each other. The `container_path` workflow input (§ workflow) makes
either topology work without YAML restructuring — a split just means selecting a
different image per run.

### Build must be a STANDALONE script (run independently of the workflow)

Create `app/build-container.sh` (with `app/finetune.def` alongside — the same
layout `workflows/streamlit/` uses; see §1.5) that builds the .sif with NO
dependency on the ACTIVATE workflow, so it can be run manually on a build host and
the resulting image distributed. Requirements:
- Self-contained: `singularity build finetune.sif app/finetune.def` (or a
  `--remote`/`--fakeroot` variant for unprivileged build hosts).
- Pin the §3.5 version set in the `%post` section; install the triton_kernels
  explicitly (they're the fragile piece).
- Emit the built `.sif` to a known path; print the path at the end.
- Idempotent / re-runnable; take an optional output-path arg and an optional
  registry tag arg (for pushing to ghcr.io — see workflow container modes).
- Document in a header comment: required host (Hopper GPU for MXFP4, CUDA 12.x
  driver), and that `singularity`↔`apptainer` are interchangeable.
- The workflow's on-the-fly build mode (below) should CALL this same script —
  never duplicate the build logic in the YAML. One source of truth for the build.

## 4. The resolver logic (workflow.yaml → resolve_strategy job)

Inputs: `num_gpus`, `vram_gb_per_gpu`, model profile (→ footprint), optional
`parallelism_override`. Output: STRATEGY ∈ {single, ddp, fsdp}, LAUNCHER, PRECISION.

Rules (current draft — thresholds are first-guess, TUNE against real `nvidia-smi`):
- override set → use it.
- 1 GPU → `single` (LAUNCHER=`python`).
- model+overhead fits on one card AND >1 GPU → `ddp` (replicate for speed).
- doesn't fit training on one card → `fsdp` (LAUNCHER=`accelerate launch`,
  + an FSDP/ZeRO-3 config file — **stub, must be written**).
- Overhead heuristic in draft: `NEED_PER_GPU = footprint*1.6 + 8`. Placeholder.
  §3 warns gpt-oss's dequantized bf16 working set may blow past this — MEASURE.
- `custom` profile: footprint is a placeholder; should read `config.json` param
  count and estimate. **stub.**

## 5. Evaluation design (both blocks are in the YAML)

Two DISTINCT things, kept separate on purpose:
1. **Held-out loss** (always on). Classical train/val split via
   `eval_split_fraction`; same loss objective on unseen rows; cadence via
   `eval_steps`; plotted live next to training loss in TensorBoard. Cheap,
   model-agnostic. This is TRL/HF `eval_dataset` + `eval_steps`.
2. **Quality eval** (optional, PLUGGABLE). Because generation has no single
   correct string, low loss ≠ good answers. Selector `quality_eval_type` ∈
   {none, overlap(ROUGE/BLEU), task(exact-match/accuracy), judge(LLM-as-judge)}
   with an open command/endpoint hook. Left as an interface so any evaluator
   drops in without schema changes — including a future refusal check (§7).

Keep (1) as the default-on dashboard signal; (2) is opt-in per task.

## 6. What to do on the live GPU (Claude Code, next session)

> **Status as of 2026-09-03 (see `PLAN.md` for detail): steps 1-4 DONE and
> verified on a T4. Step 5 partially done (measured: OLMoE 7B does NOT fit
> unquantized in 15 GB; 4-bit + attention-only LoRA does, at 0.24% trainable).
> Steps 6-7 (gpt-oss 20b/120b, FSDP) NOT started — they need Hopper-class,
> multi-GPU hardware.** The `NEED_PER_GPU = footprint*1.6 + 8` heuristic in
> `resolve_strategy` is still unvalidated against a real large-model run.

Priority order (step 1 is the plan-mode reconnaissance from the header):
1. **Read the REAL repo in plan mode** — two sources, two purposes (§1.6):
   SCAFFOLDING from a current template (`workflows/streamlit/` for the SIF case,
   `workflows/webshell/` for the minimal case); TRAINING LOGIC mined from the seeded
   legacy `app/run.sh` (dense LoRA/merge/dataset specifics reusable for Gemma + the
   OLMo dev path). Use the `.claude/skills/activate-workflows/` skill. Plan the port
   of our draft YAML from the LEGACY session pattern to the current ENDPOINT pattern
   (§1.5), and decide whether the legacy training logic is worth extracting or should
   be rebuilt fresh from §3. The draft's `start_finetune.sh` heredoc shows the
   env-var contract the training script must consume; that maps onto
   `app/start-template.sh` (listen on `service_port`, write `cancel.sh`, `sleep inf`).
   Everything below assumes this recon is done.
2. **Build the container via the standalone `app/build-container.sh`** (§3.5).
   ONE Singularity .sif for all 6 models, built to the gpt-oss Triton version set.
   Verify it runs with `--nv` and that gpt-oss loads (MXFP4 on Hopper, else bf16
   fallback is acceptable for training). This is the real ceiling — the original
   `finetune:v1.0` predates the gpt-oss stack. Build must be runnable independently
   of the workflow so the image can be distributed. (Model download + container
   pull/build belong in `app/controller.sh` — the controller node has internet, the
   compute node may not; §1.5.)
3. **Dense smoke test end-to-end on `allenai/OLMo-2-0425-1B`** — load→LoRA→train
   (a few steps)→held-out loss→merge→reload. Proves the dense plumbing before
   touching big models. Minutes on CPU/small GPU.
4. **MoE smoke test on `allenai/OLMoE-1B-7B-0924-Instruct`** — same end-to-end
   loop but through the MoE branch: confirms expert-targeting LoRA
   (`target_parameters`) runs, the resolver treats it as MoE, and merge/reload
   works. NOTE the §2 caveat: this validates the branch, NOT the exact gpt-oss
   target strings. Derive OLMoE's own expert-layer targets from its config
   (16 layers, 8-of-64) — don't paste gpt-oss's 7/15/23 indices.
5. **Validate the resolver's footprint math** with real `nvidia-smi` during a run.
   Especially: gpt-oss dequantized-bf16 working set (§3) vs the fit thresholds (§4).
   Adjust `NEED_PER_GPU` heuristic to match reality.
6. **gpt-oss-20b run** with the verified LoraConfig (§3) on one GPU. Confirm
   harmony template handling + `target_parameters` (derive 20b's own expert-layer
   indices — 24 layers — rather than assuming the cookbook's 7/15/23 subset).
   THIS is the run that proves the single container works for the whole matrix
   (dense + MoE + MXFP4). If it passes, the one-container decision is validated.
7. **gpt-oss-120b** only after the FSDP/ZeRO-3 config is written and 20b works.
   This is where multi-GPU sharding is actually exercised.

## 7. Explicitly deferred (do NOT build yet)

- **Refusal / safety-behavior tooling.** User was clear: not in scope now, but
  wants the door left open. It fits later as (a) just another SFT dataset through
  the same pipeline, or (b) a preference trainer (DPO — TRL provides it) as an
  additive trainer type, or (c) a refusal evaluator in the §5 pluggable slot.
  Activation-level abliteration/steering is out of scope (different tool entirely).
  The design already keeps this open via a data-agnostic dataset abstraction +
  pluggable eval. Don't hardcode assumptions that would close it.

## 8. Open risks / caveats (carried from the design chat)

- **ACTIVATE expression syntax**: the draft chains ternaries in `base_model_id`
  and `quantization` defaults more than PW docs demonstrate. The parser fails
  SILENTLY on malformed expressions (returns garbage, no error). FIRST validate
  these in the Build tab's live form preview.
- **Memory numbers are estimates**, not measured. §6 step 3 is how we fix that.
- **`target_parameters` layer indices** are tunable, not fixed — scale to model depth.
- **Merge step for 120b**: prefer keeping adapters separate and serving base+adapter
  (vLLM) rather than a single-process merge that may OOM. Merge is fine for ≤20b.
- **Two LoRA stacks exist for gpt-oss** (HF `target_parameters` vs Unsloth
  linearized). Don't mix them in one container.

## 8.5 VERIFIED failure modes and their fixes (first live-GPU session, 2026-09-03)

Hit and root-caused on a single Tesla T4 (compute capability 7.5, 15 GB) with
`transformers==4.56.2`, `trl==0.23.0`, `peft==0.20.0`, `torch 2.8.0+cu128`.
All three were real defects in *our* code, not upstream bugs to wait on.

### (a) THE LANDMINE — double-preparing a quantized model trains NOTHING

**Symptom:** training runs to completion, writes adapters/merged weights/a
plausible-looking report, and logs a training loss that varies per step — but
`grad_norm` is exactly `0.0` on every step and `eval_loss` is *bit-identical*
across every eval checkpoint. The "fine-tuned" model is byte-identical to the
base model. Larger/more diverse data does not help (verified: 6x more data,
still bit-identical eval loss).

**Root cause:** `trl/models/utils.py:prepare_peft_model()`. `SFTTrainer.__init__`
calls it whenever the model **is already a `PeftModel`**, even with
`peft_config=None`. For a quantized model it then re-runs
`prepare_model_for_kbit_training()` **on the already-wrapped model**, which sets
`requires_grad=False` on *every* parameter — LoRA adapters included — and then
skips `get_peft_model()` because `peft_config is None`, so nothing re-enables
them. Result: **zero trainable parameters**, an optimizer with an empty param
list, and a silent no-op run.

**Fix:** never hand SFTTrainer a pre-wrapped quantized PEFT model. Load the raw
model, compute the `LoraConfig`, and pass `model=` + `peft_config=` to
SFTTrainer; let TRL do the kbit prep and `get_peft_model()` itself, in that
order. `app/train.py` does this and asserts `trainable != 0` before training so
this can never be silent again. **Do not "helpfully" re-add
`prepare_model_for_kbit_training()`/`get_peft_model()` to `build_base_model()`.**

**Misdiagnosis trail (do not repeat):** the same root cause also produces
(i) `RuntimeError: element 0 of tensors does not require grad and does not have
a grad_fn` when gradient checkpointing is off, and (ii)
`AssertionError: No inf checks were recorded for this optimizer` under fp16
(the GradScaler finds no grads because there are no trainable params). Both look
like gradient-checkpointing / fp16-vs-bf16 incompatibilities and are **not**.
Forcing gradient checkpointing on, switching to bf16, and setting
`use_reentrant=False` all appear to "help" (they change which symptom you see)
and all fix nothing. Note TRL resets `args.gradient_checkpointing` itself
(`prepare_peft_model` line ~545), so forcing it is doubly pointless. 4-bit under
fp16 works fine once the real bug is fixed.

**Cheap way to tell these apart in future:** a manual
forward/`loss.backward()` outside the Trainer. If LoRA grads are non-zero there
(they were: `lora_B` grads ~1e-1, `lora_A` exactly 0 which is *correct* at init
since `lora_B` starts at zero) but `grad_norm` is 0 through the Trainer, the
model/PEFT/bnb stack is fine and the wiring is at fault. Then check
`sum(p.numel() for p in trainer.model.parameters() if p.requires_grad)`.

### (b) Do not use the `paged_*` bitsandbytes optimizers

The legacy script hardcoded `optim="paged_adamw_32bit"`. Its unified-memory
state buffers fail with `CUDA error: an illegal memory access was encountered`
inside `bitsandbytes/optim/optimizer.py:get_state_buffer` → `F.fill`. Now a
configurable `--optim` (workflow input `advanced.optim`), default
`adamw_torch`; `adamw_bnb_8bit` is the low-memory option (~4x smaller optimizer
state) and works.

### (c) MoE name-based LoRA targeting over-adapts every expert

PEFT `target_modules` matches by module *name*, so the dense default list
(`...up_proj,down_proj,gate_proj`) matches the MLP projections **inside every
expert of every layer**. On OLMoE (64 experts x 16 layers) that is 3072 expert
Linear modules → **620M trainable params (8.2%)**, ~13x the dense model's count.
It defeats the point of LoRA and OOMs a 15 GB card. `app/train.py` now detects
per-expert-Linear MoE (regex `\.experts\.\d+\.` over `named_modules()`) and
targets attention projections only → **16.8M (0.24%)**, consistent with §3's
"~15M / 0.07%" target for gpt-oss. Override with `--lora-target-modules`.

This is the *per-expert-nn.Linear* MoE case (OLMoE, Mixtral-style) and is
**distinct from gpt-oss**, which exposes fused expert *Parameter* tensors and
needs PEFT `target_parameters` instead (§3). `resolve_lora_config()` probes the
loaded model and picks the right mechanism — it does not trust the profile key,
which is deliberate: OLMoE and gpt-oss are different MoE implementations (§2).

## 9. Key sources (re-fetch for latest before pinning)

- OpenAI cookbook, gpt-oss + Transformers fine-tune:
  https://cookbook.openai.com/articles/gpt-oss/fine-tune-transfomers
- PW YAML fields: https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields
- PW inputs/expressions: https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions
- gemma-4-31B card (multimodal, gemma4 template, 30.7B dense)
- Original repo: github.com/parallelworks/activate-medical-finetuning
