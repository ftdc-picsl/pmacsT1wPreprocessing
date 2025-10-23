#!/bin/bash

module load apptainer

scriptPath=$(readlink -f "$0")
scriptDir=$(dirname "${scriptPath}")
# Repo base dir under which we find bin/ and containers/
repoDir=${scriptDir%/bin}

queue=ftdc_normal

numThreads=4

function usage() {
  echo "Usage:
  $0 [-h] -i input_dataset  -o output_dataset  <input_list>  <level=participant|session>  [additional args to T1wPreprocessing]

  This is a wrapper script to submit images for processing. The input list should either be:

    participants - a text file containing one participant ID per line, without the 'sub-' prefix.
    sessions - a CSV file containing one participant and session per file, without the 'sub-' and 'ses-' prefixes.

    Example:

      $0 -i /path/to/input/dataset -o /path/to/output/dataset /path/to/participant_list.txt participant
      $0 -i /path/to/input/dataset -o /path/to/output/dataset /path/to/session_list.txt session

  Images will be processed from all participants / sessions in input list. Only images with the suffix
  '_T1w.nii.gz' will be processed. Images that already have masks in the output dataset will not
  be reprocessed.

  If the output dataset directory does not exist, it will be created.

  Logs will be written to 'code/logs' in the output dataset.

  Required arguments:
    -i input_dataset    : path to the input dataset
    -o output_dataset   : path to the output dataset

  Optional arguments:
    -n num_threads      : number of CPU cores to request for the job (default=$numThreads).
    -q                  : queue name (default=$queue). The queue must be able to support GPU jobs.
  "
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while getopts "i:n:o:q:h" opt; do
  case $opt in
    h) usage; exit 1;;
    i) inputBIDS=$OPTARG;;
    n) numThreads=$OPTARG;;
    o) outputBIDS=$OPTARG;;
    q) queue=$OPTARG;;
    \?) echo "Unknown option $OPTARG"; exit 2;;
    :) echo "Option $OPTARG requires an argument"; exit 2;;
  esac
done

shift $((OPTIND-1))

inputList=$1
level=$2

if [[ $level != "participant" && $level != "session" ]]; then
  echo "Error: level must be 'participant' or 'session'"
  exit 1
fi

shift 2

export APPTAINERENV_TMPDIR=/tmp

# Hard-coded for the ftdc-gpu01 cluster
export APPTAINERENV_CUDA_VISIBLE_DEVICES=0
export APPTAINERENV_ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=${numThreads}
export APPTAINERENV_OMP_NUM_THREADS=${numThreads}

date=`date +%Y%m%d_%H%M%S`

if [[ ! -d "${outputBIDS}/code/logs" ]]; then
  mkdir -p "${outputBIDS}/code/logs"
fi

bsub -cwd . -o "${outputBIDS}/code/logs/ftdc-t1w-preproc_${date}_%J.txt" \
    -J t1w_preproc_gpu \
    -q ${queue} \
    -n ${numThreads} \
    -gpu "num=1:mode=exclusive_process:mps=no:gtile=1" \
    apptainer run --containall --nv \
    -B /scratch:/tmp,${inputBIDS}:${inputBIDS}:ro,${outputBIDS}:${outputBIDS},${inputList}:/input/list.txt \
    ${repoDir}/containers/ftdc-t1w-preproc-0.5.3.sif \
    --input-dataset ${inputBIDS} \
    --output-dataset ${outputBIDS} \
    --${level}-list /input/list.txt \
    "$@"
