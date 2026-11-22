# llama.cpp GGUF

Serves a GGUF model with llama.cpp's `llama-server` through a platform
endpoint. The endpoint is registered as an OpenAI-compatible provider
(`pw endpoints run --openai`), so the model appears in the platform's built-in
chat and AI providers and can be used by any tool that speaks the OpenAI API.
`--jinja` applies the model's own chat template, which is what makes OpenAI
tool calling (`tools`, `tool_calls`) work, including several calls in one
response.

The defaults serve [Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini)
from [unsloth/Inkling-2-Mini-GGUF](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF).
Its GGUFs use a looped-layer layout that mainline llama.cpp, and so Ollama,
does not read correctly yet, which is why this workflow runs Unsloth's
prebuilt llama.cpp. Any other GGUF repository and any Linux CUDA build of
llama.cpp can be set in the form.

## What a run does

On the controller (login) node, which needs internet access:

1. Downloads the llama.cpp tarball once and reuses it afterwards. Prebuilt
   CUDA tarballs often leave out the CUDA runtime; since llama-server loads
   its CUDA backend as a plugin, a missing runtime makes it serve on CPU
   without an error. The run installs NVIDIA's CUDA runtime and cuBLAS wheels from PyPI
   beside the binary, and copies a newer `libstdc++` from a `gcc` module where
   the system one is too old (RHEL 9 is).
2. Downloads the GGUF, the vision projector and the speculative drafter (each
   optional) with the Hugging Face CLI, which is far faster than a single
   HTTP stream. A model directory that already holds every file is used as is,
   even read-only.

Then, on the same node or on a compute node through the scheduler, it starts
`llama-server`, refuses to serve if no CUDA device is visible, and registers
the endpoint.

## Workflows

- `yamls/general.yaml`: any cluster or GPU server. Software and models go
  under `${HOME}/pw/software/llamacpp` unless a model directory is set.
- `yamls/hsp.yaml`: HSP systems. Software and models are staged under
  `${PROJECTS_HOME}/hsp/llamacpp`, shared by every user of the system, with a
  private fallback in the work filesystem. Includes a Makau configuration for
  one H100 NVL.

## Sizing

Measured with Inkling 2 Mini on a 300-word answer and a 2,170-token prompt:

| GPU | Quant | Settings | Generation | Prompt |
|---|---|---|---|---|
| 24 GB A30 | UD-Q4_K_XL, vision, 32K context | defaults | 20.7 tok/s | 284 tok/s |
| 24 GB A30 | same | `--fit on` (experts spill to CPU) | 15 tok/s | 178 tok/s |
| 24 GB A30 | same, with the DSpark drafter | `--fit on` | 12 tok/s | 162 tok/s |
| 94 GB H100 NVL | UD-Q8_K_XL, vision, DSpark drafter, 128K context | earlier test | 46 to 51 tok/s | 1,288 tok/s |
| 94 GB H100 NVL | UD-Q8_K_XL, vision, 1M context, no drafter | Makau configuration | 37 to 44 tok/s | 1,020 to 1,140 tok/s on 232K to 388K-token prompts |

On a 24 GB GPU the default micro-batch needs a 3.3 GB compute buffer and runs
out of memory with every layer on the GPU, so the defaults use
`--ubatch-size 256` and a q8_0 KV cache. On a larger GPU drop those for faster
prompt processing, and consider UD-Q8_K_XL (full precision) and speculative
decoding. Agent clients can send prompts of 200K tokens or more, which a
smaller window rejects and clients then report as a tool-calling failure. At
about 1,100 tok/s a 230K-token prompt takes over three minutes to the first
token; later turns reuse the cached prefix (`--parallel 1` keeps one slot) and
answer in seconds. The drafter allocates its own KV cache for the full window,
so it does not fit beside a 1M window on one 94 GB GPU.

Sampling follows the model card: temperature 1.0, top-p 1.0, top-k off,
min-p 0.

## Using the model

The model id is `session:<user>:<endpoint name>/<GGUF file without .gguf>`,
for example `session:<user>:inkling2-mini/Inkling-2-Mini-UD-Q4_K_XL`. Set a
fixed endpoint name to keep that id stable across relaunches.
