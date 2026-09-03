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

---

## Status

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
- DDP / FSDP: `resolve_strategy` emits `strategy`/`launcher` as job outputs but
  `train-entrypoint.sh` **ignores them** — single-GPU `python` launch only. The
  FSDP/ZeRO-3 config file is still a `TODO(stub)`.
- `advanced.chat_template_override` is plumbed but **not consumed** by
  `train.py`; the tested path is the flat `prompt_field` → `text` one. Real
  chat-template application (harmony / gemma4) is unbuilt.
- `evaluation.quality_eval_type` / `quality_eval_command` are form-only
  (HANDOFF §5's pluggable slot) — no implementation.
- `thumbnails/` — not created; needed for a marketplace registration.
- The `NEED_PER_GPU = footprint*1.6 + 8` heuristic is still a guess. One real
  measurement so far: OLMoE-1B-7B (7B total) does **not** fit unquantized in
  15 GB; at 4-bit with attention-only LoRA it fits comfortably. HANDOFF §2's
  "~4 GB (bf16)" frozen footprint for OLMoE looks wrong — 7B params in bf16 is
  ~14 GB; that table appears to count *active* rather than *resident* params.

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
