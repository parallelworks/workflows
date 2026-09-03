#!/usr/bin/env python3
"""
LoRA/QLoRA fine-tuning entrypoint for the generalized `finetuning` ACTIVATE
workflow. Runs non-interactively inside a Singularity container, driven
entirely by CLI flags (translated from env vars by app/train-entrypoint.sh).

Model-profile-aware: a `--model-profile` selects a chat template default, a
quantization default, and (for genuinely fused-expert MoE architectures like
gpt-oss) a PEFT `target_parameters` LoRA strategy. LoRA targeting for
"ordinary" architectures -- dense, or MoE implementations that expose each
expert as its own nn.Linear submodule (e.g. OLMoE) -- is auto-detected from
the loaded model rather than hardcoded per profile: PEFT's name-based
`target_modules` matching already reaches every expert's projections in that
case, so no special-casing is needed there. Only gpt-oss's fused
`experts.gate_up_proj`/`experts.down_proj` *Parameter* tensors (not separate
Linear submodules) require the newer `target_parameters` mechanism -- see
HANDOFF.md sec3.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import time
from pathlib import Path
from typing import List, Optional

import torch
from datasets import Dataset, load_dataset
from huggingface_hub import login
from peft import LoraConfig
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
)
from trl import SFTConfig, SFTTrainer

LOG = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Model-profile metadata (HANDOFF.md sec2). "custom"/unknown profiles fall
# back to the dense defaults that were already the legacy behavior.
# ---------------------------------------------------------------------------

DENSE_DEFAULT_TARGETS = "q_proj,k_proj,v_proj,o_proj,up_proj,down_proj,gate_proj"
ATTENTION_ONLY_TARGETS = "q_proj,k_proj,v_proj,o_proj"

PROFILE_CHAT_TEMPLATE = {
    "olmo2-1b-dev": "olmo",
    "olmoe-1b-7b-dev": "olmo",
    "gemma-1.1-7b": "gemma",
    "gemma-4-31b": "gemma4",
    "gpt-oss-20b": "harmony",
    "gpt-oss-120b": "harmony",
}

PROFILE_QUANTIZATION_DEFAULT = {
    "gpt-oss-20b": "native",
    "gpt-oss-120b": "native",
    "gemma-4-31b": "4bit",
}

MULTIMODAL_PROFILES = {"gemma-4-31b"}

# Sampled expert-layer indices for gpt-oss's fused target_parameters LoRA
# strategy (HANDOFF sec3: "a sampled subset, not fixed -- a tunable knob").
# Not used for OLMoE or any other architecture that doesn't expose fused
# expert Parameter tensors -- those are auto-detected instead (see
# resolve_lora_config below), never guessed from this table.
PROFILE_TARGET_PARAMETER_LAYERS = {
    "gpt-oss-20b": (7, 15, 23),     # verified cookbook default, 24 layers total
    "gpt-oss-120b": (11, 23, 35),   # TODO(stub): scaled guess over 36 layers, tune on real hardware
}

MIN_HOPPER_COMPUTE_CAPABILITY = (9, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fine-tune a causal LM with LoRA/QLoRA (generalized, model-profile-aware)."
    )
    parser.add_argument("--model-profile", default="custom",
                         help="Profile key from yamls/general.yaml's model_profile dropdown, or 'custom'.")
    parser.add_argument("--base-model-id", required=True,
                         help="Base Hugging Face model identifier or local path.")
    parser.add_argument("--dataset-source", choices=["huggingface", "local", "bucket"], default="huggingface")
    parser.add_argument("--dataset-name", default=None)
    parser.add_argument("--dataset-config", default=None)
    parser.add_argument("--dataset-split", default="train")
    parser.add_argument("--prompt-field", default="prompt")
    parser.add_argument("--local-dataset-path", default=None)
    parser.add_argument("--dataset-format", choices=["json", "csv", "parquet", "arrow", "dataset"], default="json")
    parser.add_argument("--dataset-dir", default=None)
    parser.add_argument("--max-samples", type=int, default=None)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output-dir", default="outputs")
    parser.add_argument("--num-epochs", type=float, default=3.0)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--weight-decay", type=float, default=0.0)
    parser.add_argument("--warmup-steps", type=int, default=50)
    parser.add_argument("--micro-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation", type=int, default=16)
    parser.add_argument("--max-seq-length", type=int, default=2048)
    parser.add_argument("--logging-steps", type=int, default=10)
    parser.add_argument("--save-steps", type=int, default=200)
    parser.add_argument("--save-total-limit", type=int, default=3)
    parser.add_argument("--lora-r", type=int, default=64)
    parser.add_argument("--lora-alpha", type=int, default=16)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--lora-target-modules", default="",
                         help="Comma separated override. Blank = auto-detect (profile-aware).")
    parser.add_argument("--target-parameters-layers", default="",
                         help="Comma separated layer indices for gpt-oss-style fused-expert "
                              "target_parameters LoRA. Blank = profile default / auto-sample.")
    parser.add_argument("--quantization", choices=["4bit", "8bit", "none", "native"], default="",
                         help="Blank = profile default (see PROFILE_QUANTIZATION_DEFAULT). "
                              "'native' loads via Mxfp4Config(dequantize=True) -- gpt-oss profiles only.")
    parser.add_argument("--hf-token", default=None)
    parser.add_argument("--push-to-hub", action="store_true")
    parser.add_argument("--hub-model-id", default=None)
    parser.add_argument("--merge-full-weights", action="store_true")
    parser.add_argument("--merged-save-format", choices=["safetensors", "bin"], default="safetensors")
    parser.add_argument("--trust-remote-code", action="store_true")
    parser.add_argument("--gradient-checkpointing", action="store_true")
    parser.add_argument("--bf16", action="store_true")
    parser.add_argument("--packing", action="store_true")
    parser.add_argument("--tensorboard", action="store_true")
    parser.add_argument("--optim", default="adamw_torch",
                         help="HF Trainer optimizer name. adamw_bnb_8bit cuts optimizer-state "
                              "memory ~4x (useful when many adapters are trained, e.g. MoE "
                              "experts). Avoid the paged_* variants: their unified-memory "
                              "state buffers fail with an illegal memory access on some GPUs.")
    parser.add_argument("--eval-split-fraction", type=float, default=0.0,
                         help="Held-out fraction for always-on eval loss. 0 disables.")
    parser.add_argument("--eval-steps", type=int, default=50)
    return parser.parse_args()


def maybe_login(token: Optional[str]) -> None:
    if token:
        login(token=token, add_to_git_credential=True)
        LOG.info("Logged in to Hugging Face Hub.")


def load_training_dataset(args: argparse.Namespace) -> Dataset:
    dataset_source = getattr(args, "dataset_source", "huggingface")
    LOG.info("Loading dataset from source: %s", dataset_source)

    if dataset_source == "huggingface":
        dataset_kwargs = {"path": args.dataset_name, "split": args.dataset_split}
        if args.dataset_config:
            dataset_kwargs["name"] = args.dataset_config
        if args.hf_token:
            dataset_kwargs["token"] = args.hf_token
        dataset = load_dataset(**dataset_kwargs)
        LOG.info("Loaded dataset %s (split=%s) from HuggingFace Hub", args.dataset_name, args.dataset_split)

    elif dataset_source == "local":
        local_path = getattr(args, "local_dataset_path", None)
        if not local_path:
            raise ValueError("local_dataset_path is required for local dataset source")
        dataset_format = getattr(args, "dataset_format", "json")
        if dataset_format == "dataset":
            dataset = load_dataset(local_path, split=args.dataset_split or "train")
        else:
            dataset = load_dataset(dataset_format, data_files=local_path, split="train")
        LOG.info("Loaded dataset from local path: %s (format: %s)", local_path, dataset_format)

    elif dataset_source == "bucket":
        dataset_dir = getattr(args, "dataset_dir", None)
        if not dataset_dir:
            raise ValueError("dataset_dir is required for bucket dataset source")
        try:
            dataset = load_dataset(dataset_dir, split=args.dataset_split or "train")
            LOG.info("Loaded dataset from bucket directory: %s", dataset_dir)
        except Exception as e:
            LOG.warning("Could not load as dataset directory: %s. Trying file formats...", e)
            import glob
            files: List[str] = []
            for ext in ["*.jsonl", "*.json", "*.parquet", "*.csv"]:
                files.extend(glob.glob(os.path.join(dataset_dir, ext)))
            if not files:
                raise ValueError(f"No supported dataset files found in {dataset_dir}")
            data_file = files[0]
            if data_file.endswith((".json", ".jsonl")):
                dataset = load_dataset("json", data_files=data_file, split="train")
            elif data_file.endswith(".parquet"):
                dataset = load_dataset("parquet", data_files=data_file, split="train")
            elif data_file.endswith(".csv"):
                dataset = load_dataset("csv", data_files=data_file, split="train")
            else:
                raise ValueError(f"Unsupported file format: {data_file}")
            LOG.info("Loaded dataset from bucket file: %s", data_file)
    else:
        raise ValueError(f"Unsupported dataset source: {dataset_source}")

    if args.max_samples:
        dataset = dataset.select(range(min(args.max_samples, len(dataset))))

    if args.prompt_field not in dataset.column_names:
        raise ValueError(
            f"Dataset does not contain '{args.prompt_field}' column. "
            f"Available columns: {dataset.column_names}"
        )

    dataset = dataset.shuffle(seed=args.seed)
    LOG.info("Final dataset size: %d samples", len(dataset))
    return dataset


def resolve_quantization(args: argparse.Namespace) -> str:
    if args.quantization:
        return args.quantization
    return PROFILE_QUANTIZATION_DEFAULT.get(args.model_profile, "none")


def gpu_supports_hopper_mxfp4() -> bool:
    if not torch.cuda.is_available():
        return False
    return torch.cuda.get_device_capability(0) >= MIN_HOPPER_COMPUTE_CAPABILITY


def resolve_lora_config(args: argparse.Namespace, model) -> LoraConfig:
    """Profile-agnostic LoRA target resolution.

    An explicit --lora-target-modules override always wins. Otherwise, probe
    the loaded model for gpt-oss-style FUSED expert Parameter tensors
    (`*.mlp.experts.gate_up_proj` / `*.mlp.experts.down_proj` as raw
    nn.Parameter, not nn.Linear submodules) -- only that architecture needs
    PEFT's newer `target_parameters` mechanism (HANDOFF sec3). MoE models
    that expose each expert as its own nn.Linear (OLMoE, Mixtral-style) are
    reached by ordinary name-based `target_modules`, but their MLP
    projections must be excluded or every expert gets an adapter -- see the
    per-expert branch below.
    """
    if args.lora_target_modules.strip():
        targets = [t.strip() for t in args.lora_target_modules.split(",") if t.strip()]
        LOG.info("LoRA targets (explicit override): %s", targets)
        return LoraConfig(
            r=args.lora_r, lora_alpha=args.lora_alpha, lora_dropout=args.lora_dropout,
            bias="none", target_modules=targets, task_type="CAUSAL_LM",
        )

    fused_expert_params = [
        name for name, _ in model.named_parameters()
        if name.endswith("mlp.experts.gate_up_proj") or name.endswith("mlp.experts.down_proj")
    ]
    if fused_expert_params:
        layer_re = re.compile(r"\.layers\.(\d+)\.")
        by_layer = {}
        for name in fused_expert_params:
            m = layer_re.search(name)
            if m:
                by_layer.setdefault(int(m.group(1)), []).append(name)

        if args.target_parameters_layers.strip():
            layers = [int(x) for x in args.target_parameters_layers.split(",") if x.strip()]
        elif args.model_profile in PROFILE_TARGET_PARAMETER_LAYERS:
            layers = list(PROFILE_TARGET_PARAMETER_LAYERS[args.model_profile])
        else:
            # Auto-sample ~3 layers spread across the depth (start/mid/end),
            # mirroring the cookbook's own "sampled subset, not fixed" guidance.
            all_layers = sorted(by_layer)
            n = len(all_layers)
            idxs = sorted(set([all_layers[0], all_layers[n // 2], all_layers[-1]])) if n else []
            layers = idxs

        target_params = sorted(
            name for layer in layers for name in by_layer.get(layer, [])
        )
        LOG.info("MoE fused-expert-parameter targeting engaged: %d tensors across layers %s",
                 len(target_params), layers)
        return LoraConfig(
            r=args.lora_r, lora_alpha=args.lora_alpha, lora_dropout=args.lora_dropout,
            bias="none", target_modules="all-linear", target_parameters=target_params,
            task_type="CAUSAL_LM",
        )

    # MoE architectures that expose each expert as its own nn.Linear (OLMoE,
    # Mixtral-style) need the MLP projections dropped from the target list.
    # Name-based matching is per-module, so "up_proj" etc. would match inside
    # every expert of every layer -- on OLMoE (64 experts x 16 layers) that is
    # ~3000 adapters and 8.2% trainable params, ~13x the dense model's count,
    # which both defeats the point of LoRA and OOMs a 16GB card. Attention
    # projections are shared per layer, so they stay.
    expert_re = re.compile(r"\.experts\.\d+\.")
    n_expert_linear = sum(
        1 for name, mod in model.named_modules()
        if expert_re.search(name) and isinstance(mod, torch.nn.Linear)
    )
    if n_expert_linear:
        targets = [t.strip() for t in ATTENTION_ONLY_TARGETS.split(",") if t.strip()]
        LOG.info("Per-expert-Linear MoE detected (%d expert Linear modules). Targeting "
                 "attention projections only: %s. Pass --lora-target-modules to include "
                 "expert MLP projections (expect a large trainable-parameter count).",
                 n_expert_linear, targets)
    else:
        targets = [t.strip() for t in DENSE_DEFAULT_TARGETS.split(",") if t.strip()]
        LOG.info("Dense architecture: standard name-based LoRA target_modules: %s", targets)
    return LoraConfig(
        r=args.lora_r, lora_alpha=args.lora_alpha, lora_dropout=args.lora_dropout,
        bias="none", target_modules=targets, task_type="CAUSAL_LM",
    )


def build_base_model(args: argparse.Namespace):
    quantization = resolve_quantization(args)
    compute_dtype = torch.bfloat16 if args.bf16 else torch.float16
    quant_config = None
    model_kwargs = {}

    if quantization == "native":
        # gpt-oss ships MXFP4-quantized. Training never happens in native
        # MXFP4 (HANDOFF sec3) -- Mxfp4Config(dequantize=True) unpacks it to
        # bf16 for the forward/backward. On sub-Hopper hardware transformers
        # itself falls back to bf16 silently; log it here so it's not silent
        # to whoever's watching this run.
        if not gpu_supports_hopper_mxfp4():
            cc = torch.cuda.get_device_capability(0) if torch.cuda.is_available() else None
            LOG.warning(
                "::warning::MXFP4 requires compute capability >= %s (Hopper); this GPU reports %s. "
                "transformers will dequantize to bf16 -- training still works, just without the "
                "MXFP4 memory/speed benefit.", MIN_HOPPER_COMPUTE_CAPABILITY, cc,
            )
        try:
            from transformers import Mxfp4Config
            model_kwargs["quantization_config"] = Mxfp4Config(dequantize=True)
        except ImportError:
            LOG.warning("::warning::Mxfp4Config unavailable in this transformers version; "
                        "loading without quantization_config.")
        model_kwargs["attn_implementation"] = "eager"
    elif quantization == "4bit":
        quant_config = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_compute_dtype=compute_dtype,
            bnb_4bit_use_double_quant=True, bnb_4bit_quant_type="nf4",
        )
    elif quantization == "8bit":
        quant_config = BitsAndBytesConfig(load_in_8bit=True)

    if quant_config is not None:
        model_kwargs["quantization_config"] = quant_config

    is_local = os.path.isdir(args.base_model_id)
    is_multimodal = args.model_profile in MULTIMODAL_PROFILES
    if is_multimodal:
        # gemma-4-31b needs the multimodal processor even for text-only
        # training (HANDOFF sec2). Not exercised on this dev box (30B won't
        # fit a single T4) -- best-effort per HANDOFF sec3, unverified.
        LOG.warning("::warning::model_profile=%s uses the multimodal loader path, which has not "
                    "been run/verified on this hardware.", args.model_profile)
        from transformers import AutoModelForImageTextToText
        model_cls = AutoModelForImageTextToText
    else:
        model_cls = AutoModelForCausalLM

    model = model_cls.from_pretrained(
        args.base_model_id,
        trust_remote_code=args.trust_remote_code,
        use_auth_token=None if is_local else args.hf_token,
        local_files_only=is_local,
        device_map="auto",
        torch_dtype=compute_dtype,
        **model_kwargs,
    )
    # Deliberately NOT calling prepare_model_for_kbit_training() or
    # get_peft_model() here: SFTTrainer is handed the raw model plus a
    # peft_config and does both itself, in the right order
    # (trl/models/utils.py:prepare_peft_model). Pre-wrapping a *quantized*
    # model before handing it over silently breaks training: TRL sees an
    # existing PeftModel, re-runs prepare_model_for_kbit_training() on it --
    # which sets requires_grad=False on every parameter, adapters included --
    # and then skips get_peft_model() because peft_config is None, so nothing
    # re-enables them. The run then trains zero parameters while still
    # reporting a plausible-looking loss.
    lora_config = resolve_lora_config(args, model)

    tokenizer = AutoTokenizer.from_pretrained(
        args.base_model_id,
        trust_remote_code=args.trust_remote_code,
        use_fast=True,
        use_auth_token=None if is_local else args.hf_token,
        local_files_only=is_local,
    )
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"

    model.config.use_cache = False
    return model, tokenizer, lora_config


def write_report(output_dir: Path, args: argparse.Namespace, trainer: SFTTrainer,
                  started_at: float) -> None:
    """Persistent, offline-viewable record of the run (HANDOFF: TensorBoard is
    only live during training; this is what documents the run afterward)."""
    report_dir = output_dir / "report"
    report_dir.mkdir(parents=True, exist_ok=True)

    log_history = trainer.state.log_history
    metadata = {
        "model_profile": args.model_profile,
        "base_model_id": args.base_model_id,
        "lora_r": args.lora_r,
        "lora_alpha": args.lora_alpha,
        "lora_dropout": args.lora_dropout,
        "quantization": resolve_quantization(args),
        "num_epochs": args.num_epochs,
        "learning_rate": args.learning_rate,
        "micro_batch_size": args.micro_batch_size,
        "gradient_accumulation": args.gradient_accumulation,
        "eval_split_fraction": args.eval_split_fraction,
        "wall_clock_seconds": round(time.time() - started_at, 1),
        "final_train_loss": trainer.state.log_history[-1].get("train_loss") if log_history else None,
    }
    (report_dir / "metrics.json").write_text(
        json.dumps({"metadata": metadata, "log_history": log_history}, indent=2)
    )

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        def series(key):
            xs = [e["step"] for e in log_history if key in e and "step" in e]
            ys = [e[key] for e in log_history if key in e and "step" in e]
            return xs, ys

        plots = []
        for key, title in [("loss", "Training loss"), ("eval_loss", "Held-out eval loss"),
                            ("learning_rate", "Learning rate")]:
            xs, ys = series(key)
            if not xs:
                continue
            fig, ax = plt.subplots(figsize=(6, 4))
            ax.plot(xs, ys)
            ax.set_xlabel("step")
            ax.set_ylabel(key)
            ax.set_title(title)
            fname = f"{key}.png"
            fig.savefig(report_dir / fname, bbox_inches="tight")
            plt.close(fig)
            plots.append((title, fname))

        rows = "".join(f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in metadata.items())
        imgs = "".join(f'<h3>{title}</h3><img src="{fname}" style="max-width:720px">'
                        for title, fname in plots)
        (report_dir / "report.html").write_text(
            f"<html><head><title>Fine-tuning report: {args.model_profile}</title></head>"
            f"<body><h1>Fine-tuning report: {args.model_profile}</h1>"
            f"<table border=1 cellpadding=4>{rows}</table>{imgs}</body></html>"
        )
        LOG.info("Wrote offline report to %s", report_dir)
    except ImportError:
        LOG.warning("::warning::matplotlib not available; wrote metrics.json but skipped plots/report.html")


def train(args: argparse.Namespace) -> Path:
    started_at = time.time()
    maybe_login(args.hf_token)
    dataset = load_training_dataset(args)

    LOG.info("Pre-formatting dataset for SFTTrainer...")
    if args.prompt_field != "text":
        dataset = dataset.map(lambda x: {"text": x[args.prompt_field]}, remove_columns=[args.prompt_field])
        LOG.info("Renamed '%s' field to 'text'", args.prompt_field)

    eval_dataset = None
    if args.eval_split_fraction and args.eval_split_fraction > 0:
        split = dataset.train_test_split(test_size=args.eval_split_fraction, seed=args.seed)
        dataset, eval_dataset = split["train"], split["test"]
        LOG.info("Held-out eval split: %d train / %d eval", len(dataset), len(eval_dataset))

    model, tokenizer, lora_config = build_base_model(args)

    output_dir = Path(args.output_dir).expanduser().resolve()
    adapter_dir = output_dir / "adapters"
    adapter_dir.mkdir(parents=True, exist_ok=True)

    tensorboard_dir = output_dir / "tensorboard"
    if args.tensorboard:
        tensorboard_dir.mkdir(parents=True, exist_ok=True)
        LOG.info("TensorBoard logging enabled. Logs will be saved to: %s", tensorboard_dir)

    training_args = SFTConfig(
        output_dir=str(adapter_dir),
        per_device_train_batch_size=args.micro_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation,
        num_train_epochs=args.num_epochs,
        learning_rate=args.learning_rate,
        weight_decay=args.weight_decay,
        warmup_steps=args.warmup_steps,
        logging_steps=args.logging_steps,
        save_steps=args.save_steps,
        save_total_limit=args.save_total_limit,
        bf16=args.bf16,
        fp16=not args.bf16,
        gradient_checkpointing=args.gradient_checkpointing,
        optim=args.optim,
        lr_scheduler_type="cosine",
        report_to="tensorboard" if args.tensorboard else "none",
        logging_dir=str(tensorboard_dir) if args.tensorboard else None,
        seed=args.seed,
        max_length=args.max_seq_length,
        packing=args.packing,
        dataset_text_field="text",
        eval_strategy="steps" if eval_dataset is not None else "no",
        eval_steps=args.eval_steps if eval_dataset is not None else None,
    )

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        eval_dataset=eval_dataset,
        processing_class=tokenizer,
        peft_config=lora_config,
    )

    # trainer.model is the PeftModel that SFTTrainer built (the raw `model`
    # handed in above is never wrapped in place), so every adapter-level
    # operation below has to go through it.
    peft_model = trainer.model
    if hasattr(peft_model, "print_trainable_parameters"):
        peft_model.print_trainable_parameters()
    trainable = sum(p.numel() for p in peft_model.parameters() if p.requires_grad)
    if trainable == 0:
        raise RuntimeError(
            "No trainable parameters after SFTTrainer setup -- training would silently "
            "update nothing. Check the PEFT/quantization wiring."
        )

    trainer.train()
    trainer.save_state()
    peft_model.save_pretrained(adapter_dir)
    tokenizer.save_pretrained(adapter_dir)
    LOG.info("Saved LoRA adapters to %s", adapter_dir)

    write_report(output_dir, args, trainer, started_at)

    if args.push_to_hub:
        hub_target = args.hub_model_id or f"{Path(args.base_model_id).name}-finetuned"
        peft_model.push_to_hub(hub_target)
        tokenizer.push_to_hub(hub_target)

    if args.merge_full_weights:
        merged_dir = output_dir / "merged"
        merged_dir.mkdir(parents=True, exist_ok=True)
        merged_model = peft_model.merge_and_unload()
        merged_model.save_pretrained(
            merged_dir, safe_serialization=args.merged_save_format == "safetensors",
        )
        tokenizer.save_pretrained(merged_dir)
        LOG.info("Saved merged weights to %s", merged_dir)

    return adapter_dir


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s :: %(message)s")
    args = parse_args()
    if not args.hf_token:
        args.hf_token = os.environ.get("HF_TOKEN")
    train(args)


if __name__ == "__main__":
    main()
