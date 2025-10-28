#!/bin/bash

# Cleans up preproc input

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <preproc_input_dir>"
    exit 1
fi

input_dir="$1"

echo "Cleaning up preproc input directory: ${input_dir}"

rm ${input_dir}/*
rmdir ${input_dir}