# Request Nodes in One Workflow, Run on Them from Another — A Workflow Tutorial (environments and workers)

Most workflows ask the scheduler for nodes, use them, and give them back, all in one run. This tutorial splits that in two: one workflow **requests** the nodes and finishes while they stay reserved, and a second workflow **runs on them**, as many times as you like, without queueing again.

Two platform features do the work:

- An **[environment](https://parallelworks.com/docs/compute/environments)** is a named set of scheduler settings saved on a cluster: the partition, the node count, the wall time and any extra scheduler directives.
- A **[worker](https://parallelworks.com/docs/run/workers)** is a scheduler job that Activate submits with an environment's settings. It holds the nodes until its wall time ends or you delete it.

```
  environment ──settings──▶ worker ◀──commands── your workflows
  saved once on the cluster   a scheduler job       run as often as you like
                              holding the nodes
```

Three stages build it up:

| Stage | File | What it shows |
|---|---|---|
| 0 | — | Create an environment, request a worker and run a command on it by hand, in the UI and with `pw` |
| 1 | [`01-request-nodes.yaml`](01-request-nodes.yaml) | A workflow that requests the nodes from an environment |
| 2 | [`02-run-on-nodes.yaml`](02-run-on-nodes.yaml) | A second workflow that runs a command on those nodes |

By the end of this tutorial you will understand how to:

- Save scheduler settings, custom directives included, in an environment instead of in every workflow
- Request nodes from a workflow with one `pw workers create` line and no scheduler headers
- Hand the nodes from one workflow to another with a worker ID
- Run a command on the worker's node, or on every node it holds, with `pw ssh`
- Add node types (GPU, big memory, ...) without touching the workflows

The tutorial is written for a **cloud cluster**, which runs SLURM and boots its compute nodes on demand. For a DSRC system, with a node type saved as the environment, follow the [HSP edition](../environment-workflows-hsp/README.md).

---

## Prerequisites

- An active cloud cluster with at least two nodes free in one partition
- The [`pw` CLI](https://parallelworks.com/docs/cli) for the command-line path. It is already installed and signed in on your user workspace

---

## Stage 0 — Do it by hand

Every step is shown twice: in the Activate UI and with `pw`. Pick either; they do the same thing.

### 1. Create the environment

**In the UI.** Open your cluster and click the **Environments** tab. It already lists one auto-detected environment per partition, which is where you can read your partition's name. Click **Add** and fill in **New environment**:

| Field | Value |
|---|---|
| Name | `demo` |
| Partition or queue | your partition, for example `compute` |
| Scheduler | SLURM |
| Default wall time | `00:30:00` |

Click **Create**. The environment reopens in edit mode. Expand **Defaults and directives**, set **Number of Nodes** to `2`, **Number of tasks** to `2` and **Scheduler directives** to `#SBATCH --comment=demo`, then click **Save**.

**With `pw`.**

```bash
pw environments create --cluster <cluster> --name demo --partition <partition> --scheduler slurm
pw environments update --cluster <cluster> \
  --default numNodes=2 \
  --default ntasks=2 \
  --default walltime=00:30:00 \
  --default 'schedulerDirectives=#SBATCH --comment=demo' \
  demo
pw environments get --cluster <cluster> demo    # shows what you saved
```

Pass every `--default` in one command: each `update --default` call replaces the defaults saved before it.

**Scheduler directives are yours to write.** The field takes any extra `#SBATCH` lines (or `#PBS` on a PBS cluster), one per row: GPUs, memory, constraints, a reservation, anything the scheduler accepts. `--comment=demo` does nothing except let you see, in step 3, that the directive reached the scheduler.

### 2. Request the nodes

**In the UI.** Go to **Run → Workers** and click **Create**. Choose **demo** under your cluster and click **Request worker**. The worker moves from *pending* to *queued* to *connected*.

**With `pw`.**

```bash
pw workers create --environment demo --wait <cluster>
```

The command prints the worker's ID and returns when the worker is connected. `pw workers ls` lists your workers at any time.

> On a cloud cluster the nodes boot first, so expect a few minutes in *queued*.

### 3. Run a command on them

**In the UI.** On the worker's row, click **Open in terminal**. You are on the first node of the request.

**With `pw`.**

```bash
pw ssh worker/<worker-id> hostname
pw ssh worker/<worker-id> 'squeue -o "%.8i %.6D %k"'    # job ID, node count, comment
```

The second command shows the scheduler job behind the worker: two nodes, and `demo` in the comment column, both straight from the environment.

### 4. Release the nodes

**In the UI.** On the worker's row, click **Delete worker** and confirm.

**With `pw`.**

```bash
pw workers delete <worker-id>
```

> A connected worker holds its nodes even when nothing runs on them, and on a cloud cluster held nodes are running nodes. Delete a worker as soon as you are done with it.

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
        description: Name of an environment on the cluster; its saved settings decide the partition, the node count and the wall time.
        default: demo
```

### Concepts introduced

**One line instead of scheduler headers.**
The workflow holds no partition, no node count, no wall time and no `#SBATCH` line. It names an environment, and the environment supplies all of them. Change the settings on the cluster and every workflow that names the environment follows.

**No `ssh` block.**
The job has no `ssh.remoteHost`, so its step runs in your user workspace. `pw workers create` asks the platform for the nodes, and the platform submits the scheduler job on the cluster. `${{ inputs.resource.uri }}` is the chosen cluster's `pw://<user>/<cluster>` address.

**`--wait` — a completed run means the nodes are ready.**
Without `--wait` the command returns as soon as the request is queued. With it, the step ends only when the scheduler job is running and its node has connected, so the next workflow can start right away.

**The worker ID is the handle.**
Everything that happens to the nodes from here on goes through the worker ID. The step publishes it as a job output (`WORKER_ID` in [`$OUTPUTS`](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions#writing-outputs)) and as a `::notice::` on the run page, which is where you copy it from for Stage 2.

**The nodes outlive the run.**
The run completes; the worker keeps the nodes. If you cancel the run while it is still waiting, the request stays in the queue: delete the worker as in Stage 0.

**Overriding a saved setting.**
A value passed with `--param` wins over the environment's default for that one request. To let the form choose the node count, add a `number` input and pass it:

```bash
pw workers create --environment "${{ inputs.environment }}" \
  --param numNodes=${{ inputs.nodes }} --param ntasks=${{ inputs.nodes }} \
  --wait "${{ inputs.resource.uri }}"
```

### Run it

**In the UI.** [Add the file as a workflow](https://parallelworks.com/docs/run/workflows/adding-workflows), pick your cluster, leave **Environment** as `demo` and click **Execute**. When the run completes, copy the worker ID from the notice on the run page.

**With `pw`.**

```bash
pw workflows run -i '{"resource": "pw://<user>/<cluster>", "environment": "demo"}' ./01-request-nodes.yaml
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
[`pw ssh`](https://parallelworks.com/docs/cli/pw/ssh) connects to the node the worker runs on and runs the command there. The form asks for nothing but the worker ID: no cluster, no partition, no scheduler settings. This workflow never talks to the scheduler queue.

**Every node, not just the first.**
A worker that holds several nodes still runs on one of them. `pw workers get -o json` returns the ID of the scheduler job behind the worker, and `srun --jobid=<id>` starts a command inside that job, once per task. The environment asked for two tasks on two nodes, so the second step prints one line per node:

```
Hello world from <node-1>
Hello world from <node-2>
```

`srun --jobid` is SLURM. The first step works on any scheduler.

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

## Adding node types

A node type is one more environment on the same partition, with the scheduler directives that select that kind of node. For a GPU node type:

```bash
pw environments create --cluster <cluster> --name gpu --partition <partition> --scheduler slurm
pw environments update --cluster <cluster> \
  --default numNodes=1 \
  --default ntasks=1 \
  --default walltime=01:00:00 \
  --default 'schedulerDirectives=#SBATCH --gpus-per-node=1' \
  gpu
```

In the UI it is the same **Add** on the **Environments** tab, with the directive under **Defaults and directives**.

Then run Stage 1 with **Environment** set to `gpu`. Neither workflow changes, because what makes a node a GPU node lives in the environment, not in the YAML. A site that selects node types with a constraint would save `#SBATCH --constraint=<node type>` instead, one environment per node type.

---

## Cleanup

Delete the worker (Stage 0, step 4) to release the nodes. To remove the environment too, click **Delete** on its row in the **Environments** tab, or:

```bash
pw environments delete --cluster <cluster> demo
```
