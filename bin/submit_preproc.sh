#!/bin/bash

module load singularity/3.8.3

scriptPath=$(readlink -f "$0")
scriptDir=$(dirname "${scriptPath}")
# Repo base dir under which we find bin/ and containers/
repoDir=${scriptDir%/bin}

function usage() {
  echo "Usage:
  $0 [-h] -i input_dataset -o output_dataset <participant_list>

  This is a wrapper script to submit images for processing. The participant list should be
  a text file containing one participant ID per line, without the 'sub-' prefix.

  Images will be processed from all participants in input dataset. Only images with the suffix
  '_T1w.nii.gz' will be processed. Images that already have masks in the output dataset will not
  be reprocessed.

  If the output dataset directory does not exist, it will be created, however the user must create
  dataset_description.json for the dataset to be valid BIDS.

  Logs will be written to 'code/logs' in the output dataset.

  Required arguments:
    -i input_dataset    : path to the input dataset
    -o output_dataset   : path to the output dataset
  "
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while getopts "i:o:p:h" opt; do
  case $opt in
    h) usage; exit 1;;
    i) inputBIDS=$OPTARG;;
    o) outputBIDS=$OPTARG;;
    \?) echo "Unknown option $OPTARG"; exit 2;;
    :) echo "Option $OPTARG requires an argument"; exit 2;;
  esac
done

shift $((OPTIND-1))

participantList=$1

export SINGULARITYENV_TMPDIR=/tmp

date=`date +%Y%m%d_%H%M%S`

if [[ ! -d "${outputBIDS}/code/logs" ]]; then
  mkdir -p "${outputBIDS}/code/logs"
fi

bsub -cwd . -o "${outputBIDS}/code/logs/ftdc-t1w-preproc_${date}_%J.txt"\
    -gpu "num=1:mode=exclusive_process:mps=no" \
    singularity run --containall --nv \
    -B /scratch:/tmp,${inputBIDS}:/input,${outputBIDS}:/output,${participantList}:/participants/list.txt \
    ${repoDir}/containers/ftdc-t1w-preproc-0.1.2.sif \
    --input-dataset /input \
    --output-dataset /output \
    --participant /participants/list.txt
