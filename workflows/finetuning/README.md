# finetuning

Generalized single-node LoRA/QLoRA fine-tuning workflow. Point at a cluster,
pick a model profile (or paste a custom HuggingFace ID), point at an on-disk
dataset, and run -- a live TensorBoard dashboard is served on the endpoint's
port while training runs, and a persistent offline report (loss/eval-loss
plots, `metrics.json`, `report.html`) is written to `output_dir/report` once
training completes.

See `HANDOFF.md` for the full design (model matrix, container strategy,
resolver logic, evaluation design) and its priority-ordered next steps.

## Model profiles

Six pre-filled profiles (see `yamls/general.yaml`'s `model_profile` dropdown)
plus "custom". `olmo2-1b-dev` (dense) and `olmoe-1b-7b-dev` (MoE) are the
verified dev/smoke-test profiles -- both ungated, Apache-2.0, run comfortably
on a single consumer/datacenter GPU. `gpt-oss-20b`/`gpt-oss-120b` need
Hopper-class hardware (compute capability >= 9.0) for true MXFP4; on older
GPUs training still works via transformers' automatic bf16 dequantize
fallback. `gemma-4-31b` is multimodal even for text-only training.

## Container

One Singularity image (`app/finetune.def`) serves all six profiles. Three
ways to obtain it (`container_mode` input): pull from a registry (`oras`),
point at an existing `.sif` on disk, or build on-the-fly
(`app/build-container.sh`, also runnable standalone: `bash
app/build-container.sh [output_path] [registry_tag]`).

## Local development

`app/train.py` (+ `app/train-entrypoint.sh`) can be exercised directly via
`singularity exec --nv` without going through the ACTIVATE platform -- see
`legacy/` for the prior iteration's scripts this workflow was ported from.
