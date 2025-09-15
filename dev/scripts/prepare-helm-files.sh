#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <root_folder> <helm_folder>" >&2
  exit 1
fi

root=${1%/}
dest=$2

if [ ! -d "$root" ]; then
  echo "Root folder '$root' does not exist or is not a directory." >&2
  exit 1
fi

mkdir -p "$dest"

find "$root" -type f \( -name 'composition.yaml' -o -name 'definition.yaml' \) -print0 |
while IFS= read -r -d '' file; do
  rel=${file#"$root"/}
  dir=$(dirname "$rel")
  if [ "$dir" = "." ]; then
    destdir="$dest"
  else
    destdir="$dest/$dir"
  fi
  mkdir -p "$destdir"
  cp -p "$file" "$destdir/"
done