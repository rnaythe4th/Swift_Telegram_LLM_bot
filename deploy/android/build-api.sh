#!/bin/sh
# Prepare a code-only DeepSeek Web API transport upgrade; never package auth.
set -eu
umask 077
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
    echo 'Usage: sh deploy/android/build-api.sh <new staging directory>' >&2
    exit 2
fi
mkdir -p "$1"
out=$(CDPATH='' cd -- "$1" && pwd)
source=$repo/FreeDeepseekAPI
for file in package.json server.js lib/pow.js lib/updater.js scripts/lib/tui-menu.js; do
    [ -f "$source/$file" ] || { echo "Missing FreeDeepseekAPI/$file" >&2; exit 2; }
done
mkdir -p "$out/deepseek-web" "$out/free-deepseek-api/lib" "$out/free-deepseek-api/scripts/lib" "$out/free-deepseek-api/public"
cp "$repo/deepseek-web/worker.py" "$repo/deepseek-web/browser.py" \
    "$repo/deepseek-web/api_backend.py" "$repo/deepseek-web/requirements.txt" \
    "$repo/deploy/deepseek-web/maintenance.py" "$out/deepseek-web/"
cp "$repo/deploy/android/runtime.py" "$out/runtime.py"
cp "$source/package.json" "$source/server.js" "$out/free-deepseek-api/"
cp "$source/lib/pow.js" "$source/lib/updater.js" "$out/free-deepseek-api/lib/"
cp "$source/scripts/lib/tui-menu.js" "$out/free-deepseek-api/scripts/lib/"
cp -R "$source/public/dashboard" "$out/free-deepseek-api/public/"
# Safety check: only enumerated source files, never credentials, profiles or Git.
if find "$out" -type f \( -name '.env' -o -name 'deepseek-auth.json' -o -name '*.pem' -o -name '*.key' \) | grep -q .; then
    echo 'Refusing to stage any credentials' >&2
    exit 2
fi
printf 'Prepared code-only API stage: %s\n' "$out"
