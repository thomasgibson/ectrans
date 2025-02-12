#!/bin/bash

MAX_RUNS=10
count=0

ROOT_DIR=$(pwd)

while [[ $MAX_RUNS -eq 0 || $count -lt $MAX_RUNS ]]; do
    echo "Run #$((count + 1))"
    ${ROOT_DIR}/build/bin/test-program-gpu-sp
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error detected (exit code: $exit_code). Stopping execution."
        exit $exit_code
    fi
    ((count++))
done

echo "Finished execution."
