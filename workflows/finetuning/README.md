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
fallback. `gemma-4-31b` is multimodal even for text-only training; see below.

### gemma-4-31b (text-only)

Validated on 4x 15GB GPUs — no Hopper and no large-VRAM card needed. Two
things differ from the other profiles:

- **Use the transformers 5.x container image.** The `gemma4` architecture
  exists in no 4.x release, and `app/requirements.txt` stays on 4.x because
  5.x regresses the MoE and FSDP paths (PLAN.md). Select the 5.x image with
  `container_mode: sif_path` + `container_sif_path`.
- **Set `advanced.parallelism_override: single`.** The resolver would pick
  `fsdp` from the model's footprint, but FSDP cannot load this model under
  5.x. With `single` and several GPUs visible the model is spread across
  them (`device_map="auto"`), which is what works.

LoRA is applied to the 410 text-tower modules only; the vision tower is
excluded because PEFT cannot adapt its `Gemma4ClippableLinear` layers, and
because a text-only dataset gives the vision path no training signal. **The
vision tower is still loaded and frozen, so the model keeps its pretrained
vision capability** — only further training of it is excluded. Note that
heavy text-only fine-tuning can still degrade multimodal performance
indirectly, since the language model is what consumes the vision tokens.

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

One Singularity definition (`app/finetune.def`) and **two pin sets**:

| pin set | transformers | use for |
|---|---|---|
| `app/requirements.txt` | 4.56.2 | **default** — every profile except `gemma-4-31b` |
| `app/requirements-tf5.txt` | 5.16.1 | **`gemma-4-31b` only** (no 4.x release knows its `gemma4` architecture) |

Each has a companion `.lock` (`app/requirements.lock`,
`app/requirements-tf5.lock`) holding the full `pip freeze` of the image that
was actually validated. Those are reference artifacts for diffing a future
rebuild against a known-good stack — `finetune.def` installs the `.txt`, not
the `.lock`. Load-bearing packages (`peft`, `bitsandbytes`, `datasets`,
`huggingface_hub`, torch/transformers/trl/triton/accelerate/tokenizers) are
pinned exactly in the `.txt`; peripheral ones stay loose there and are pinned
in the `.lock`.

The 5.x set is not a general upgrade: it regresses FSDP sharded loading and
roughly doubles MoE memory. Its file header and PLAN.md have the
measurements. Both sets are tracked files, so either image is reproducible.

Three ways to obtain an image (`container_mode` input): pull from a registry
(`oras`), point at an existing `.sif` (`container_sif_path`), or build
on-the-fly. In build mode the `container.requirements_file` input selects the
pin set, and the built image is **cached per pin set**, so switching rebuilds
rather than silently reusing the other one.

Standalone: `bash app/build-container.sh [output_path] [registry_tag] [requirements_file]`.
The chosen file is staged into a temp build dir as `requirements.txt`, so one
unmodified `finetune.def` serves both and the repo's own `requirements.txt` is
never edited.

**Selection is manual and deliberate** — the workflow does not route
containers by model profile. Picking the wrong one now fails with an
actionable message (`train.py` turns the raw `KeyError: 'gemma4'` into a
message naming the file to build from), and `strategy=fsdp` on a 5.x image
logs a warning pointing at `parallelism_override=single`.

## Local development

`app/train.py` (+ `app/train-entrypoint.sh`) can be exercised directly via
`singularity exec --nv` without going through the ACTIVATE platform -- see
`legacy/` for the prior iteration's scripts this workflow was ported from.
