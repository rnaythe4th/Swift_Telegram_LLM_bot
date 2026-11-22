#!/bin/sh
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
    echo 'Usage: sh deploy/android/build.sh <new output directory>' >&2
    exit 2
fi
mkdir -p "$1"
output=$(cd "$1" && pwd)
context=$(mktemp -d)
trap 'rm -rf "$context"' EXIT

cp "$repo/Package.swift" "$repo/Package.resolved" "$context/"
cp -R "$repo/Sources" "$repo/Tests" "$context/"
docker build --platform linux/arm64 \
    --file "$repo/deploy/android/Dockerfile" \
    --output "type=local,dest=$output" "$context"

mkdir "$output/deepseek-web"
cp "$repo"/deepseek-web/*.py "$repo/deepseek-web/requirements.txt" \
    "$repo/deploy/deepseek-web/maintenance.py" "$output/deepseek-web/"
