#!/bin/sh
set -eu

if [ -z "${DEEPSEEK_WEB_PROFILE_DIR:-}" ] && [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]; then
    volume=$(realpath -e -- "$RAILWAY_VOLUME_MOUNT_PATH")
    export DEEPSEEK_WEB_PROFILE_DIR="$volume/deepseek-web/profile"
fi
export HOME=/run/bot

if [ "$(id -u)" -eq 0 ]; then
    exec setpriv --reuid=65532 --regid=65532 --clear-groups --no-new-privs \
        /opt/deepseek-venv/bin/python3 /opt/deepseek-web/maintenance.py "$@"
fi
exec /opt/deepseek-venv/bin/python3 /opt/deepseek-web/maintenance.py "$@"
