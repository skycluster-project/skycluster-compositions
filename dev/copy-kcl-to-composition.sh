#!/bin/bash

# check if both arguments are provided and print usage if not
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <kcl_path> <composition_path>"
    exit 1
fi

KCL_PATH=$(realpath $1)
COMPOSITION_PATH=$(realpath $2)

COMPOSITION_FILENAME=$(basename "$COMPOSITION_PATH")
COMPOSITION_DIR=$(dirname "$COMPOSITION_PATH")

main_k_content=$(sed 's/^/            /' "$KCL_PATH")
echo "$main_k_content" > "main.tmp"

yq -iY '
  .spec.pipeline[] |= (
    if .step == "resources" then 
      .input.spec.source = "TO_BE_FILLED"
    else . 
    end
  )
' "$COMPOSITION_PATH"
