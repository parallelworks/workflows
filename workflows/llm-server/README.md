# LLM Server

Serves a language model behind an OpenAI-compatible endpoint on a cluster, with the inference engine chosen on the form. The endpoint is registered as a pw endpoint, so the platform chat, pw code, and any OpenAI client can use it.

| Engine | Model format | Runs from |
|---|---|---|
| vLLM | Hugging Face safetensors checkpoint | SIF image pulled from ghcr.io as an ORAS artifact |
| SGLang | Hugging Face safetensors checkpoint | SIF image pulled from ghcr.io as an ORAS artifact |
| llama.cpp | GGUF files | prebuilt `llama-server` tarball |

vLLM and SGLang need a GPU with enough memory for the weights and KV cache. llama.cpp serves quantized models, which fit larger models on smaller GPUs, at a lower prompt and generation speed.

## How a run works

1. The controller installs what the engine needs into the install directory: the SIF image under `containers/`, or the llama.cpp build and GGUF files under `llamacpp/`. Anything already there is reused read-only, so a model or image staged once serves every account on the system.
2. For vLLM and SGLang with a Hugging Face model, `prepare_model` downloads the checkpoint into the model cache directory, or finds it already there.
3. The service script runs on a compute node through the scheduler, or on the login node, starts the engine on a local port, waits for its `/health` check, and registers the port with `pw endpoints http --link --openai`.
4. The run completes once the endpoint answers. The server keeps running until the job's walltime ends or the endpoint is deleted with `pw endpoints delete <name>`.

A run whose engine exits before it answers, or whose model cannot be found or downloaded, ends in error.

The endpoint is named `<engine>-<run slug>` unless an endpoint name is set under Advanced settings. A fixed name keeps model ids in chat clients stable across relaunches. Launching with a name that is already listed replaces that endpoint: it is deleted, which stops its server, once the new run has everything installed.

## Variants

The engines, their settings and the scripts under `app/` are the same in every variant. What differs is the platform:

| Variant | Platform | Install directory | Scheduler form |
|---|---|---|---|
| `general.yaml` | activate.parallel.works and any other | `${HOME}/pw/software`, models in `~/pw/models` | partition, walltime and free directives; GPUs are requested in the directives where the scheduler tracks them |
| `hsp.yaml` | activate.hpc.mil | `$PROJECTS_HOME/hsp`, models in `models/` under it | account, partition, QoS, CPUs, nodes, node type |
| `noaa.yaml` | noaa.parallel.works | the cluster's shared software directory (`/contrib/pw` on Hera, Mercury and Ursa), models in `models/` under it; `${HOME}/pw/software` on cloud clusters | account, partition, QoS, tasks, nodes; `--gres=gpu:<number of GPUs>` and `--mem=0` are added to the job |

An empty model cache directory resolves to `models/` under the install directory in every variant.

## Engine notes

*SGLang:* compiled kernels are kept in `cache/sglang` under the install directory and shared by every run and account. The first start on a GPU type compiles them; later starts reuse them. Serving Inkling 2 Mini on an H100 NVL, a cold start took 531 s and a warm one 112 s.

*vLLM:* arguments go on the command line unquoted, so JSON values such as `--speculative-config '{...}'` do not survive; use dotted keys (`--speculative-config.method dspark`).

*llama.cpp:* `--jinja` in the extra arguments is required for tool calling. The context size sets the KV cache allocation; 0 uses the model's trained maximum.

## Presets

The presets (`configurations:`) of the HSP and NOAA yamls are the vLLM presets of `rag-vllm`, one per system and model, with `runtype: vllm` read as `engine: vllm` and the RAG settings dropped. The HSP yaml adds Inkling 2 Mini on Makau with each engine; the comment above those presets records the measured startup and prompt speeds. The general yaml has none, like `rag-vllm`'s.

## Tests

`tests/<variant>/` holds the recorded end-to-end tests (`tools/tests/README.md`): each engine on a small model, the scheduler path, a fixed endpoint name, and two failure paths that must end the run in error (a model path that does not exist, a model id that cannot be downloaded).

```bash
python3 tools/tests/run-workflow-test.py workflows/llm-server/tests/general/awsgpu-vllm.json
```

## Relation to rag-vllm and llamacpp

This workflow generalizes the vLLM path of `rag-vllm` and the `llamacpp` workflow into one launcher. It uses the same install directory layout as `rag-vllm`, so images and models staged by either are reused. The RAG stack of `rag-vllm` is not included.
