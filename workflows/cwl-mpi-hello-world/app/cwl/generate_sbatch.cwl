cwlVersion: v1.2
class: CommandLineTool
baseCommand: [bash]

inputs:
  load_mpi:
    type: string
    doc: "Command to load MPI"

  np:
    type: int
    doc: "Number of MPI processes"

  scheduler_directives:
    type: string
    doc: "SLURM directives"

  executable:
    type: File
    doc: "Path to the mpitest executable file"

  output_dir:
    type: Directory
    doc: "Output directory for SLURM job"


outputs:
  sbatch_script:
    type: File
    outputBinding:
      glob: "run.sh"

requirements:
  InitialWorkDirRequirement:
    listing:
      - entryname: "run.sh"
        entry: |
          $(inputs.scheduler_directives)
          #SBATCH --chdir=$(inputs.output_dir.path)
          $(inputs.load_mpi)
          mpirun -np $(inputs.np) $(inputs.executable.path) &> mpitest.out
          cat mpitest.out
