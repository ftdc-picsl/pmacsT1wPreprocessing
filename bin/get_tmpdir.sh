#!/bin/bash

output_file=$1

x=$(mktemp -d /scratch/t1w_preproc_tmp.XXXXXXXX)

if [[ ! -d "$x" ]]; then
    echo "tmp dir $x was not created"
    exit 1
fi

echo $x > ${output_file}
