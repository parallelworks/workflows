# NVIDIA PhysicsNeMo in the NGC container

> Learned migrating `parallelworks/activate-physicsnemo` to `workflows/physicsnemo`
> (2026-10-09, `a30gpuserver` A30 and `gcpsmall` CPU nodes). The workflow's README
> covers the design; this file lists the facts and traps.

## The image

- `nvcr.io/nvidia/physicsnemo/physicsnemo:25.06`: PhysicsNeMo 1.1.0, PyTorch
  2.7.0a0 (nv25.04), CUDA 12.9, Python 3.12.3, PhysicsNeMo-Sym, Warp 1.7.2. **No
  MLflow** (`physicsnemo.launch.logging.mlflow` raises ImportError). 94 layers,
  16.9 GB to download, 31.4 GB unpacked (`docker images`). Anonymous pulls work; the
  manifest list has amd64 and arm64. Tags as of 2026-10: 25.03 … 26.08.
- Match the examples to the image: `git clone --branch v<physicsnemo.__version__>`
  of github.com/NVIDIA/physicsnemo. A sparse checkout of `examples/` is ~10 MB (the
  repository ~250 MB).
- A SIF needs the layers, the unpacked tree and the squashfs at once: ~65-70 GB free
  while building, 13 GB afterwards; `singularity build` from `docker://` took 7 minutes
  on a30gpuserver (Apptainer 1.3.4 as `singularity`, 20 cores) and the SIF runs the examples with `--nv`
  as the user, unchanged. gcpsmall's login node (56 GB free on the 100 GB disk that also holds
  `/home`) cannot build it; there Docker on the compute nodes works (67 GB free each),
  pulling the image on every fresh cloud node.
- Run the container as the user (`docker run --user $(id -u):$(id -g)` with
  `HOME=/workspace/.home`, `USER`, `LOGNAME`): the job directory stays the user's and
  the NGC entrypoint and the examples are fine with it.
- Warp prints `Warp CUDA error: Failed to get driver entry point 'cuDeviceGetUuid'`
  and `API call is not supported in the installed CUDA driver` under driver 580
  (CUDA 13); it then initializes the GPU and trains normally.
- `nvidia-physicsnemo.sym` on PyPI is an sdist that compiles a CUDA extension (nvcc),
  so PINN examples (`ldc_pinns`) really need the container.

## The v1.1.0 examples

- **No TensorBoard.** `LaunchLogger` prints `[time][<namespace>][INFO] - Epoch <N>
  Metrics: <name> = <value>, …` and `Epoch Execution Time: <s>s, Time/Iter: <ms>ms`
  through Hydra's root logger, and can log to MLflow or W&B. `workflows/physicsnemo`
  parses the console into TensorBoard events on the login node
  (`app/metrics.py`, `app/tensorboard-server.py`); `tensorboard.compat.proto` and
  `tensorboard.summary.writer.event_file_writer` write scalars and PNG images with no
  TensorFlow or PyTorch.
- `Darcy2D` (darcy_fno, darcy_transolver) defaults to `device="cuda"`: pass
  `device=dist.device` to run on a CPU. Without MLflow/W&B, `log_figure` writes
  `validation_step_<NNN>.png` into the working directory.
- `darcy_transolver` calls `initialize_mlflow(mode="offline")` and
  `LaunchLogger.initialize(use_mlflow=True)`: patch both out for the NGC image.
- `ldc_pinns` hard-codes `for i in range(10000)` and prints/plots every 1000
  iterations; nothing in its config controls the length.
- Not runnable as shipped from a workflow: `gray_scott_rnn` downloads a 22 GB + 2.4 GB
  Zenodo dataset and hard-codes `device="cuda"`; `darcy_physics_informed` fetches its
  data from Google Drive with gdown (`download_data.py`); `vortex_shedding_mesh_reduced`
  needs a 1.7 GB NGC dataset and trains in two stages. The source workflow listed all
  three with scripts that called non-existent entry points.
- Speed on one A30 at the examples' resolution 256: darcy_fno (batch 64) 80 s per
  pseudo-epoch of 2048 samples, 10.4 GB of GPU memory; darcy_transolver (batch 8)
  350 s; ldc_pinns 0.07 s per iteration (10000 in ~12 min). On 8 CPU cores (gcpsmall) the FNO at
  resolution 64, batch 8, 64 samples per pseudo-epoch takes 40 s per pseudo-epoch.
- Docker 29 with the containerd image store (gcpsmall's compute nodes) keeps the
  compressed layers and the unpacked image: ~48 GB of disk for 25.06, and the pull
  took ~29 min on a fresh node (2026-10-09).
- **That store is `/var/lib/containerd`, whatever the install directory says.** awsgpu's
  login node has `/var` as a 15 GB partition (13 GB free) beside a 160 GB `/home`: the
  pull downloaded for minutes, failed with `no space left on device` in
  `.../io.containerd.content.v1.content/ingest/`, and a plain retry loop repeated it twice
  (2026-10-09). `train.sh` now checks the store's free space first (the containerd store
  when `docker info` shows `io.containerd.snapshotter`, else `DockerRootDir`) and refuses,
  pointing at Singularity, whose SIF goes to the install directory.

## TensorBoard from conda-forge

- `tensorboard=2.20.0` imports `pkg_resources` in `tensorboard.program`, which
  setuptools 81 removed: pin `setuptools<81` in the env, and check
  `import tensorboard.program`, not just `import tensorboard`, or a fresh env passes
  the install check and the server dies on start (gcpsmall, 2026-10-09).
- `tb = program.TensorBoard(); tb.configure(argv=[None, "--logdir", d, "--host",
  "0.0.0.0", "--port", p, "--load_fast", "false"]); tb.main()` serves it from your own
  process, so one process can feed the event files and serve them under
  `pw endpoints run`.

## Hardened hosts (awsgpu, Rocky 9.8, 2026-10-09)

- **squashfs disabled** (`/etc/modprobe.d/squashfs.conf`: `install squashfs /bin/false`):
  setuid singularity-ce 4.4.2 fails with `squashfs filesystem seems not enabled and/or
  supported by your kernel`. `singularity exec --userns` mounts the same SIF with its
  bundled `squashfuse_ll` over `/dev/fuse` ("Mounting image with FUSE"), and `--nv` still
  gives PyTorch the GPU. `train.sh` probes `exec <sif> true`, then `--userns`.
- **FIPS mode** (`/proc/sys/crypto/fips_enabled` = 1, visible inside every container):
  the image's Ubuntu OpenSSL 3.0.13 then enables FIPS, has only `legacy.so` in
  `ossl-modules`, and `ssl.create_default_context()` raises `[CRYPTO] unknown error`,
  so `import physicsnemo` fails. `OPENSSL_FORCE_FIPS_MODE=0` fixes it (`OPENSSL_FIPS=0`
  and `OPENSSL_CONF=/dev/null` do not); binding a file with `0` over
  `/proc/sys/crypto/fips_enabled` works too. Applies to Docker as well.
- `/var` is a 15 GB partition: Docker cannot hold the image (see above).
- A10G: 120 s per darcy_fno pseudo-epoch at the defaults (A30: 80 s).
