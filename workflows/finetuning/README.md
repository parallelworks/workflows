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

## Dataset format requirements

The dataset is a local file (`dataset_config.local_dataset_path`, formats
json/jsonl/csv/parquet/arrow, or a saved HF dataset directory). Each row must
carry the text to train on in a single field, named by
`dataset_config.prompt_field` (default `prompt`).

**Loss is computed on the response only, and that requires a delimiter.**
`advanced.response_template` (default `### Response:\n`) marks where the
prompt ends and the response begins. Everything up to and including the
delimiter is the prompt and is masked out of the loss; everything after it is
the response and is what the model is trained on. So the expected shape of
each row is:

```
### Instruction:
What is the capital of France?

### Response:
The capital of France is Paris.
```

Rules that follow from this — worth checking before a long run:

- **The delimiter must appear literally in every row.** If your data uses a
  different convention (`### Answer:`, `<|assistant|>`, ChatML,
  `<start_of_turn>model`), set `advanced.response_template` to that string
  instead. It is matched literally, not as a regex.
- **A dataset where no row matches is a hard error**, not a silent fallback:
  `ValueError: No dataset rows contain the response template ...`. This is
  deliberate — falling back to whole-sequence loss silently would train the
  wrong objective (see below).
- **Rows that lack the delimiter are dropped with a warning, not an error.**
  Inconsistently formatted data therefore loses rows quietly. Check the
  `Completion-only loss enabled; split on ... -> N rows` log line against the
  row count you expected.
- **Single-turn only.** The split takes the *first* occurrence of the
  delimiter, so in a multi-turn conversation the response would swallow every
  later turn — including the user's — and the model would be trained to
  predict user turns too. Multi-turn data needs TRL's `assistant_only_loss`
  with a real chat template, which is not built yet
  (`advanced.chat_template_override` is present but unconsumed).
- **Setting `advanced.response_template` blank** computes loss over the whole
  sequence instead. That is the older behavior and is not recommended: it also
  trains on the prompt, including predicting the first content token from
  `<bos>` alone, which is near-impossible and can dominate the objective. On
  `gemma-1.1-7b` that single token cost 647 nats and inflated reported loss
  from ~1.2 to ~26 while the median token was healthy. `PLAN.md` has the
  measurements.

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
