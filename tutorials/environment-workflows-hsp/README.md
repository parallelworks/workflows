# Request Nodes on a DSRC System in One Workflow, Run on Them from Another — A Workflow Tutorial (environments and workers)

This is the HSP edition of the [environments tutorial](../environment-workflows/README.md), for the DSRC systems connected to Activate. One workflow **requests** nodes of a given **node type** and finishes while they stay reserved, and a second workflow **runs on them**, as many times as you like, without queueing again.

The example is **Nautilus** (Navy DSRC) and its `mla` node type: the AI/ML nodes, with four GPUs each. Every other system works the same way with its own values.

Two platform features do the work:

- An **[environment](https://parallelworks.com/docs/compute/environments)** is a named set of scheduler settings saved on a cluster. On a DSRC system that is the partition, your account, the QoS, the wall time and the directives that select the node type.
- A **[worker](https://parallelworks.com/docs/run/workers)** is a scheduler job that Activate submits with an environment's settings. It holds the nodes until its wall time ends or you delete it.

```
  environment ──settings──▶ worker ◀──commands── your workflows
  one per node type,          a scheduler job       run as often as you like
  saved once on the cluster   holding the nodes
```

Three stages build it up:

| Stage | File | What it shows |
|---|---|---|
| 0 | — | Add an `mla` environment to Nautilus, request a worker and run a command on it by hand, in the UI and with `pw` |
| 1 | [`01-request-nodes.yaml`](01-request-nodes.yaml) | A workflow that requests the nodes from an environment |
| 2 | [`02-run-on-nodes.yaml`](02-run-on-nodes.yaml) | A second workflow that runs a command on those nodes |

By the end of this tutorial you will understand how to:

- Save a node type's scheduler settings (account, QoS, constraint, GPUs) in an environment instead of in every workflow
- Request nodes of that type from a workflow with one `pw workers create` line and no scheduler headers
- Hand the nodes from one workflow to another with a worker ID
- Run a command on the worker's node, or on every node it holds, with `pw ssh`
- Add the other node types, and other systems, without touching the workflows

---

## Prerequisites

- Nautilus connected as a cluster on Activate, and an account (project) you can charge there
- The [`pw` CLI](https://parallelworks.com/docs/cli) for the command-line path. It is already installed and signed in on your user workspace

The commands below call the cluster `nautilus`. `pw cluster list` shows what yours is called.

---

## Stage 0 — Do it by hand

Every step is shown twice: in the Activate UI and with `pw`. Pick either; they do the same thing.

### 1. Add the environment for the node type

**In the UI.** Open your Nautilus cluster and click the **Environments** tab. It already lists one auto-detected environment per partition. Click **Add** and fill in **New environment**:

| Field | Value |
|---|---|
| Name | `mla` |
| Partition or queue | `general` |
| Scheduler | SLURM |
| Default wall time | `01:00:00` |

Click **Create**. The environment reopens in edit mode. Expand **Defaults and directives** and set:

| Field | Value |
|---|---|
| Account | your account |
| QoS | `standard` |
| Dedicated node | off |
| Scheduler directives | `#SBATCH --constraint=mla`<br>`#SBATCH --gres=gpu:4` |

Click **Save**.

**With `pw`.**

```bash
pw environments create --cluster nautilus --name mla --partition general --scheduler slurm
pw environments update --cluster nautilus \
  --default numNodes=1 \
  --default ntasks=1 \
  --default walltime=01:00:00 \
  --default account=<account> \
  --default qos=standard \
  --default $'schedulerDirectives=#SBATCH --constraint=mla\n#SBATCH --gres=gpu:4' \
  mla
pw environments get --cluster nautilus mla    # shows what you saved
```

Pass every `--default` in one command: each `update --default` call replaces the defaults saved before it. The `$'…\n…'` quoting puts each directive on its own line.

**The two directives are the node type.** `--constraint=mla` selects the AI/ML nodes and `--gres=gpu:4` asks for all four GPUs of one. Together with the `general` partition and the `standard` QoS, this is the request the repo's HSP workflows already make for a full AI/ML node on Nautilus. The field takes any `#SBATCH` line, one per row, so whatever a node type needs goes here.

### 2. Request the node

**In the UI.** Go to **Run → Workers** and click **Create**. Choose **mla** under your Nautilus cluster and click **Request worker**. The worker moves from *pending* to *queued* to *connected*.

**With `pw`.**

```bash
pw workers create --environment mla --wait nautilus
```

The command prints the worker's ID and returns when the worker is connected. `pw workers ls` lists your workers at any time.

> The request waits in the queue like any other job. Drop `--wait` to get the prompt back at once and watch the status with `pw workers ls`.

### 3. Run a command on it

**In the UI.** On the worker's row, click **Open in terminal**. You are on the reserved node.

**With `pw`.**

```bash
pw ssh worker/<worker-id> hostname
pw ssh worker/<worker-id> 'squeue -u $USER -o "%.10i %.6D %.12f %b"'    # job ID, nodes, constraint, GPUs
pw ssh worker/<worker-id> nvidia-smi -L                                 # the node's four GPUs
```

The second command shows the scheduler job behind the worker, with the constraint and the GPUs straight from the environment.

### 4. Release the node

**In the UI.** On the worker's row, click **Delete worker** and confirm.

**With `pw`.**

```bash
pw workers delete <worker-id>
```

> A connected worker holds its node, and charges your allocation, even when nothing runs on it. Delete a worker as soon as you are done with it.

---

## Stage 1 — Request the nodes from a workflow (`01-request-nodes.yaml`)

Stage 0's step 2 as a workflow. This is [`01-request-nodes.yaml`](01-request-nodes.yaml):

```yaml
permissions:
  - '*'

jobs:
  request:                                    # No ssh block: runs in your user workspace
    steps:
      - name: Request Nodes
        run: |
          set -o pipefail
          pw workers create --environment "${{ inputs.environment }}" --wait "${{ inputs.resource.uri }}" 2>&1 | tee worker.log
          WORKER_ID=$(grep -o 'Worker [0-9a-f]*' worker.log | head -1 | cut -d' ' -f2)
          echo "WORKER_ID=${WORKER_ID}" | tee -a $OUTPUTS
          echo "::notice::Nodes are ready. Worker ID: ${WORKER_ID}"
          echo "::notice::The worker holds the nodes until its wall time ends or you delete it: pw workers delete ${WORKER_ID}"

'on':
  execute:
    inputs:
      resource:
        type: compute-clusters                # Renders a cluster picker
        label: Resource target
        tooltip: The compute cluster to request the nodes on.
        autoselect: true
        optional: false
      environment:
        type: string
        label: Environment
        description: Name of an environment on the cluster; its saved settings decide the account, the QoS, the node type and the wall time.
        default: mla
```

### Concepts introduced

**One line instead of scheduler headers.**
The workflow holds no account, no QoS, no partition, no list of node types and no `#SBATCH` line. It names an environment, and the environment supplies all of them. Change the settings on the cluster and every workflow that names the environment follows.

**No `ssh` block.**
The job has no `ssh.remoteHost`, so its step runs in your user workspace. `pw workers create` asks the platform for the nodes, and the platform submits the scheduler job on the cluster. `${{ inputs.resource.uri }}` is the chosen cluster's `pw://<user>/<cluster>` address.

**`--wait` — a completed run means the nodes are ready.**
With `--wait`, the step ends only when the scheduler job is running and its node has connected, so the next workflow can start right away. The run stays open while the request is in the queue.

**The worker ID is the handle.**
Everything that happens to the nodes from here on goes through the worker ID. The step publishes it as a job output (`WORKER_ID` in [`$OUTPUTS`](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions#writing-outputs)) and as a `::notice::` on the run page, which is where you copy it from for Stage 2.

**The nodes outlive the run.**
The run completes; the worker keeps the nodes. If you cancel the run while it is still waiting, the request stays in the queue: delete the worker as in Stage 0.

**Overriding a saved setting.**
A value passed with `--param` wins over the environment's default for that one request. To let the form choose the wall time, add a `string` input and pass it:

```bash
pw workers create --environment "${{ inputs.environment }}" \
  --param walltime=${{ inputs.walltime }} \
  --wait "${{ inputs.resource.uri }}"
```

### Run it

**In the UI.** [Add the file as a workflow](https://parallelworks.com/docs/run/workflows/adding-workflows), pick your Nautilus cluster, leave **Environment** as `mla` and click **Execute**. When the run completes, copy the worker ID from the notice on the run page.

**With `pw`.**

```bash
pw workflows run -i '{"resource": "pw://<user>/nautilus", "environment": "mla"}' ./01-request-nodes.yaml
pw workflows runs logs <slug>        # the worker ID is in the last lines
```

---

## Stage 2 — Run on the nodes from a second workflow (`02-run-on-nodes.yaml`)

Stage 0's step 3 as a workflow. This is [`02-run-on-nodes.yaml`](02-run-on-nodes.yaml):

```yaml
permissions:
  - '*'

jobs:
  hello:                                      # No ssh block and no cluster input
    steps:
      - name: Hello From the Worker's Node
        run: pw ssh "worker/${{ inputs.worker }}" 'echo "Hello world from $(hostname)"'
      - name: Hello From Every Node
        run: |
          JOB_ID=$(pw workers get -o json "${{ inputs.worker }}" | jq -r .schedulerJobId)
          pw ssh "worker/${{ inputs.worker }}" "srun --jobid=${JOB_ID} bash -c 'echo Hello world from \$(hostname)'"

'on':
  execute:
    inputs:
      worker:
        type: string
        label: Worker ID
        description: Printed by 01-request-nodes.yaml when the nodes are ready; pw workers ls lists it too.
```

### Concepts introduced

**`pw ssh worker/<id>` — a command on the reserved node.**
[`pw ssh`](https://parallelworks.com/docs/cli/pw/ssh) connects to the node the worker runs on and runs the command there. The form asks for nothing but the worker ID: no cluster, no account, no node type. This workflow never talks to the scheduler queue.

**Every node, not just the first.**
A worker that holds several nodes still runs on one of them. `pw workers get -o json` returns the ID of the scheduler job behind the worker, and `srun --jobid=<id>` starts a command inside that job, once per task. The `mla` environment asks for one node, so both steps print the same host. Request two nodes and two tasks (`--param numNodes=2 --param ntasks=2`) and the second step prints one line per node.

**Run it as often as you like.**
Nothing in this workflow waits in a queue or releases the nodes, so it starts at once and can run again and again, from several workflows, until the worker is deleted or its wall time ends.

### Run it

**In the UI.** Add the file as a workflow, paste the worker ID from Stage 1 and click **Execute**.

**With `pw`.**

```bash
pw workflows run -i '{"worker": "<worker-id>"}' ./02-run-on-nodes.yaml
pw workflows runs logs <slug>
```

---

## Adding node types and systems

**Another node type** is one more environment on the same cluster: repeat step 1 of Stage 0 with another name and that type's directives. Nautilus's node types are `standard`, `highclock`, `bigmem`, `mla`, `viz` and `transfer`, each selected with `#SBATCH --constraint=<node type>`. For the large-memory nodes:

```bash
pw environments create --cluster nautilus --name bigmem --partition general --scheduler slurm
pw environments update --cluster nautilus \
  --default numNodes=1 \
  --default ntasks=1 \
  --default walltime=01:00:00 \
  --default account=<account> \
  --default qos=standard \
  --default 'schedulerDirectives=#SBATCH --constraint=bigmem' \
  bigmem
```

Then run Stage 1 with **Environment** set to `bigmem`. Neither workflow changes, because what makes a node a `bigmem` node lives in the environment, not in the YAML.

**Another system** is the same steps on that cluster, with its own partition, QoS and node types. On a PBS system choose **PBS** as the scheduler, give the queue as the partition and write `#PBS` lines as the directives. Stage 2's `srun` step is SLURM only; its first step works on any scheduler.

---

## Cleanup

Delete the worker (Stage 0, step 4) to release the nodes. To remove an environment too, click **Delete** on its row in the **Environments** tab, or:

```bash
pw environments delete --cluster nautilus mla
```
