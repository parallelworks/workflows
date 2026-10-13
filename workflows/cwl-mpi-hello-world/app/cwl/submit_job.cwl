cwlVersion: v1.0
class: CommandLineTool

requirements:
  ShellCommandRequirement: {}

inputs:
  sbatch_script:
    type: File
    inputBinding:
      position: 1

outputs:
  sbatch_output:
    type: File
    outputBinding:
      glob: "sbatch_output.txt"


baseCommand: ["sbatch"]

stdout: sbatch_output.txt
