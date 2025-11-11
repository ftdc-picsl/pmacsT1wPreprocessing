#!/bin/bash

module load apptainer

scriptPath=$(readlink -f "$0")
scriptDir=$(dirname "${scriptPath}")
# Repo base dir under which we find bin/ and containers/
repoDir=${scriptDir%/bin}

queue=ftdc_normal

numThreads=4

resetOrigin=0
trimNeck=1

function usage() {
  echo "Usage:
  $0 [-h] -i input_dataset  -o output_dataset  <input_list> [options] <level=participant|session>

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

  The processing workflow is optimized for efficiency, but it will not recover efficiently from failed jobs.
  It also requires enough scratch space to hold all the intermediate T1w images and masks. Therefore, it is
  recommended to run in batches of several hundred images.


  Required arguments:
    -i input_dataset    : path to the input dataset
    -o output_dataset   : path to the output dataset

  Optional arguments:
    -n num_threads      : number of CPU cores to request for the job (default=$numThreads).
    -q queue_name       : queue name (default=$queue). The queue must be able to support GPU jobs.
    -r 0/1              : reset the origin of T1w images to the centroid of the mask (default=${resetOrigin}).
    -t 0/1              : trim the neck from the T1w images before processing (default=${trimNeck}).

  "
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while getopts "i:n:o:q:r:t:h" opt; do
  case $opt in
    h) usage; exit 1;;
    i) inputBIDS=$OPTARG;;
    n) numThreads=$OPTARG;;
    o) outputBIDS=$OPTARG;;
    q) queue=$OPTARG;;
    r) resetOrigin=$OPTARG;;
    t) trimNeck=$OPTARG;;
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

# Have to bsub into a node to get a temp dir because /scratch is not visible from the head node
local_tmpdir_file=$(mktemp ${outputBIDS}/code/logs/t1w_preproc_local_tmpdir_XXXXXXXX.txt)

jid0=$(bsub -cwd . -q ${queue} -J t1w_preproc_mk_scratch -o wtf.out \
  ${repoDir}/bin/get_tmpdir.sh ${local_tmpdir_file} | sed -n 's/Job <\([0-9]\+\)>.*/\1/p')

echo "Requested working dir on compute node, waiting for result"

bwait -w "done($jid0)"
local_tmpdir=$(cat ${local_tmpdir_file}) || { echo "no path"; exit 1; }
echo "Local working dir for preprocessing: $local_tmpdir"
rm -f ${local_tmpdir_file}

container=${repoDir}/containers/ftdc-t1w-preproc-0.6.0.sif

# prepare input does not need GPU
jid1=$(bsub \
    -J t1w_preproc_prep \
    -o ${outputBIDS}/code/logs/ftdc-t1w-preproc_prep_${date}_%J.txt \
    -q ${queue} \
    -n ${numThreads} \
    apptainer run --containall \
      -B /scratch:/tmp,${local_tmpdir}:/workdir,${inputBIDS}:${inputBIDS}:ro,${outputBIDS}:${outputBIDS},${inputList}:/input/list.txt \
      ${container} \
        prepare_input \
        --input-dataset ${inputBIDS} \
        --output-directory /workdir \
        --${level}-list /input/list.txt | sed -n 's/Job <\([0-9]\+\)>.*/\1/p')

echo "Submitted prepare_input job with Job ID $jid1"
sleep 0.1
# hdbet needs GPU
jid2=$(bsub -cwd . \
    -J t1w_preproc_hdbet_gpu \
    -o "${outputBIDS}/code/logs/ftdc-t1w-preproc_hdbet_${date}_%J.txt" \
    -w "done($jid1)" \
    -q ${queue} \
    -n ${numThreads} \
    -gpu "num=1:mode=exclusive_process:mps=no:gtile=1" \
    apptainer run --containall --nv \
      -B /scratch:/tmp,${local_tmpdir}:/workdir \
      ${container} \
        hdbet \
        --input-directory /workdir | sed -n 's/Job <\([0-9]\+\)>.*/\1/p')

echo "Submitted run_hdbet job with Job ID $jid2"
sleep 0.1
#postprocessing does not need GPU
postProcFlags=""
if [[ ${resetOrigin} -eq 1 ]]; then
  postProcFlags="${postProcFlags} --reset-origin"
fi
if [[ ${trimNeck} -eq 1 ]]; then
  postProcFlags="${postProcFlags} --trim-neck"
fi

# Postprocessing includes optional neck trimming and origin resetting,
# followed by QC and writing outputs to BIDS output dataset
jid3=$(bsub -cwd . \
    -J t1w_preproc_postproc \
    -o ${outputBIDS}/code/logs/ftdc-t1w-preproc_postproc_${date}_%J.txt \
    -w "done($jid2)" \
    -q ${queue} \
    -n ${numThreads} \
    apptainer run --containall \
      -B /scratch:/tmp,${local_tmpdir}:/workdir,${inputBIDS}:${inputBIDS}:ro,${outputBIDS}:${outputBIDS},${inputList}:/input/list.txt \
      ${container} \
        postprocessing \
        --input-dataset ${inputBIDS} \
        --hd-bet-input-dir /workdir \
        --output-dataset ${outputBIDS} \
        --${level}-list /input/list.txt \
        ${postProcFlags} | sed -n 's/Job <\([0-9]\+\)>.*/\1/p')

echo "Submitted run_postprocessing job with Job ID $jid3"
sleep 0.1

# Cleanup temporary directory, don't need multiple slots for this
echo "Submitting cleanup job, will run after completion of job $jid3"

bsub -cwd . \
    -J t1w_preproc_cleanup \
    -o ${outputBIDS}/code/logs/ftdc-t1w-preproc_cleanup_${date}_%J.txt \
    -w "ended(${jid3})" \
    -q ${queue} \
    -n 1 \
    ${repoDir}/bin/cleanup.sh ${local_tmpdir}

