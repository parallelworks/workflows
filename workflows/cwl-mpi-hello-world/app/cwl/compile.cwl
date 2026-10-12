cwlVersion: v1.2
class: CommandLineTool
baseCommand: [bash, compile.sh]

inputs:
  load_mpi:
    type: string
    doc: "Command to load MPI (e.g., module load mpi)"
    
  source_code:
    type: File
    doc: "MPI C source file"
    inputBinding:
      position: 1

outputs:
  executable:
    type: File
    outputBinding:
      glob: "mpitest"

requirements:
  InitialWorkDirRequirement:
    listing:
      - entryname: "compile.sh"
        entry: |
          #!/bin/bash
          $(inputs.load_mpi)
          mpicc -o mpitest $(inputs.source_code.path)
          chmod +x mpitest
