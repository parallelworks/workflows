#!/bin/bash
# Runs inside the PhysicsNeMo container (Docker or Singularity), from train.sh, in
# /workspace (the run's work/ directory). Reports the software and the device, then
# runs one curated example or the user's script.
#
# Environment: PHYSICSNEMO_MODE (example|custom), PHYSICSNEMO_EXAMPLE, PHYSICSNEMO_EPOCHS,
# PHYSICSNEMO_ITERATIONS, PHYSICSNEMO_BATCH_SIZE, PHYSICSNEMO_DEVICE (gpu|cpu),
# PHYSICSNEMO_REF (the examples' git tag), PHYSICSNEMO_SRC (the examples tree, read-only).
# Hydra overrides, one per line, in /workspace/overrides.txt; the custom script in
# /workspace/custom.sh.
set -eo pipefail

src="${PHYSICSNEMO_SRC:-/opt/physicsnemo-src}"
cd /workspace

python - << 'EOF'
import os, platform, sys
import torch
try:
    import physicsnemo
    version = physicsnemo.__version__
except Exception as e:
    version = "not importable (%s)" % e
print("Python      : %s" % platform.python_version())
print("PyTorch     : %s" % torch.__version__)
print("PhysicsNeMo : %s" % version)
ref = os.environ.get("PHYSICSNEMO_REF", "")
if ref and version != ref.lstrip("v"):
    print("::warning::The container has PhysicsNeMo %s but the examples are %s: an example may not match the installed library. Set the examples version to v%s." % (version, ref, version))
device = os.environ.get("PHYSICSNEMO_DEVICE", "gpu")
if device == "gpu":
    if not torch.cuda.is_available():
        print("::error::No CUDA device is visible to PyTorch in the container (CUDA_VISIBLE_DEVICES=%s)" % os.environ.get("CUDA_VISIBLE_DEVICES", ""))
        sys.exit(1)
    props = torch.cuda.get_device_properties(0)
    print("Device      : %s, %.1f GiB, CUDA %s" % (props.name, props.total_memory / 2**30, torch.version.cuda))
else:
    print("Device      : CPU, %d threads" % torch.get_num_threads())
EOF

if [ "${PHYSICSNEMO_MODE}" = custom ]; then
    echo "Running /workspace/custom.sh (the examples are in ${src}/examples)"
    echo
    exec bash /workspace/custom.sh
fi

example="${PHYSICSNEMO_EXAMPLE}"
overrides=()
if [ -f /workspace/overrides.txt ]; then
    while read -r -a words; do
        overrides+=("${words[@]}")
    done < /workspace/overrides.txt
fi

rm -rf /workspace/example
cp -r "${src}/examples/cfd/${example}" /workspace/example
chmod -R u+w /workspace/example
cd /workspace/example

# Edits the example copy: each replacement must match exactly once, so an
# example that changed upstream fails here instead of training something else
f_patch() {
    python - "$@" << 'EOF'
import sys
path, pairs = sys.argv[1], sys.argv[2:]
text = open(path).read()
for old, new in zip(pairs[::2], pairs[1::2]):
    if text.count(old) != 1:
        sys.exit("::error::%s: expected one occurrence of %r to patch, found %d" % (path, old, text.count(old)))
    text = text.replace(old, new)
open(path, "w").write(text)
EOF
}

case "${example}" in
    darcy_fno|darcy_transolver)
        script=train_fno_darcy.py
        # Darcy2D generates the training data on the GPU unless told otherwise
        if [ "${example}" = darcy_transolver ]; then
            script=train_transolver_darcy.py
            # the NGC image has no MLflow, which this example logs to: console and
            # figure files instead, as the FNO example does
            f_patch "${script}" \
                "from physicsnemo.launch.logging.mlflow import initialize_mlflow" "initialize_mlflow = lambda **kwargs: None" \
                "LaunchLogger.initialize(use_mlflow=True)" "LaunchLogger.initialize()"
        fi
        f_patch "${script}" "dataloader = Darcy2D(" "dataloader = Darcy2D(device=dist.device, "
        # 0: about half an hour on one A30 (80 s per FNO pseudo-epoch, 350 s per Transolver one)
        epochs="${PHYSICSNEMO_EPOCHS:-0}"
        if [ "${epochs}" -eq 0 ]; then
            epochs=20
            [ "${example}" = darcy_transolver ] && epochs=4
        fi
        args=("training.max_pseudo_epochs=${epochs}")
        # the examples validate every 4 pseudo-epochs: a shorter run still validates once, at its end
        if [ "${epochs}" -lt 4 ]; then
            args+=("validation.validation_pseudo_epochs=${epochs}")
        fi
        if [ "${PHYSICSNEMO_BATCH_SIZE:-0}" -gt 0 ]; then
            args+=("training.batch_size=${PHYSICSNEMO_BATCH_SIZE}")
        fi
        ;;
    ldc_pinns)
        script=train.py
        iterations="${PHYSICSNEMO_ITERATIONS:-10000}"
        log_every=$(( iterations / 100 > 0 ? iterations / 100 : 1 ))
        plot_every=$(( iterations / 10 > 0 ? iterations / 10 : 1 ))
        # the example trains a fixed 10000 iterations and reports every 1000
        f_patch "${script}" \
            "for i in range(10000):" "for i in range(${iterations}):" \
            "        if i % 1000 == 0:" "        if i % ${log_every} == 0 or i == ${iterations} - 1:
            print(f\"Iteration {i} Metrics: loss = {phy_loss.item():10.3e}, Learning Rate = {optimizer.param_groups[0]['lr']:10.3e}\", flush=True)
        if i % ${plot_every} == 0 or i == ${iterations} - 1:"
        args=()
        ;;
    *)
        echo "::error::Unknown example '${example}'"
        exit 1
        ;;
esac

echo "Example     : ${example} (PhysicsNeMo examples ${PHYSICSNEMO_REF})"
echo "Command     : python ${script} ${args[*]} ${overrides[*]}"
echo
exec python -u "${script}" "${args[@]}" "${overrides[@]}"
