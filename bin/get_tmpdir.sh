#!/bin/bash

output_file=$1

x=$(mktemp -d /scratch/t1w_preproc_tmp.XXXXXXXX)

echo $x > ${output_file}
