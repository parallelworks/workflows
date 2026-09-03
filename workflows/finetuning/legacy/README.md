# Legacy reference (not runtime code)

These scripts are the original `activate-medical-finetuning` training logic,
seeded into this workflow as salvage reference before the endpoint-pattern
port. Their useful logic has been harvested into:

- `run.sh` / `run_local.sh` / `run_finetune.sh` → `app/controller.sh`,
  `app/start-template.sh`, `app/train-entrypoint.sh`
- `build_container.sh` → `app/build-container.sh` (+ `app/finetune.def`)
- (`pw_finetune.py` → `app/train.py`, done in place)

Nothing here is invoked at runtime and none of it is checked out by the
workflow (only `app/` is sparse-checked-out). Kept for reference/diffing only.
