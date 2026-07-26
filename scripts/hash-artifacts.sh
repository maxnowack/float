#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=()
if [[ "$#" -gt 0 ]]; then
  files=("$@")
else
  shopt -s nullglob
  files=("$ROOT_DIR"/artifacts/*)
  shopt -u nullglob
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "error: no artifacts supplied and artifacts/ is empty." >&2
  exit 1
fi

for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "error: artifact is not a regular file: $file" >&2
    exit 1
  fi
  shasum -a 256 "$file"
done
