cwlVersion: v1.2
class: CommandLineTool
baseCommand: [bash]

inputs:
  sbatch_output:
    type: File
    inputBinding:
      position: 2
  wait_script:
    type: File  # Expecting a file input for the script
    inputBinding:
      position: 1


outputs:
  job_status:
    type: File
    outputBinding:
      glob: job_status.txt
