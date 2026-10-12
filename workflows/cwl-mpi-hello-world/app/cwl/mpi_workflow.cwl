cwlVersion: v1.2
class: Workflow

inputs:
  load_mpi:
    type: string
    doc: "Command to load MPI"
    
  np:
    type: int
    doc: "Number of processes for mpirun"
    
  scheduler_directives:
    type: string
    doc: "SLURM directives as text"

  source_code:
    type: File
    doc: "MPI C source file"

  wait_script:
    type: File
    doc: "Bash code to wait for SLURM job"

  output_dir:
    type: Directory
    doc: "Output directory for SLURM job"


steps:
  compile:
    run: compile.cwl
    in:
      load_mpi: load_mpi
      source_code: source_code
    out: [executable]

  generate_sbatch:
    run: generate_sbatch.cwl
    in:
      load_mpi: load_mpi
      np: np
      scheduler_directives: scheduler_directives
      output_dir: output_dir
      executable: compile/executable
    out: [sbatch_script]

  submit_job:
    run: submit_job.cwl
    in:
      sbatch_script: generate_sbatch/sbatch_script
    out: [sbatch_output]

  wait_for_slurm_job:
    run: wait_for_slurm_job.cwl
    in:
      sbatch_output: submit_job/sbatch_output
      wait_script: wait_script

    out: [job_status]


outputs:
  job_status:
    type: File
    outputSource: wait_for_slurm_job/job_status
  sbatch_script:
    type: File
    outputSource: generate_sbatch/sbatch_script

