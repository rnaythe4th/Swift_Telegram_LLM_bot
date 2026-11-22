#!/bin/sh
set -eu

umask 077
unset DEEPSEEK_WEB_PROFILE_DIR

prepare_profile() {
    volume=${RAILWAY_VOLUME_MOUNT_PATH:-}
    [ -n "$volume" ] || return 1
    volume=$(realpath -e -- "$volume") || return 1
    [ "$volume" != / ] && mountpoint -q -- "$volume" || return 1
    private_dir=$volume/deepseek-web
    profile=$private_dir/profile
    [ ! -L "$private_dir" ] && [ ! -L "$profile" ] || return 1
    if [ "$(id -u)" -eq 0 ]; then
        install -d -m 0700 -o 65532 -g 65532 -- "$private_dir" "$profile" || return 1
        setpriv --reuid=65532 --regid=65532 --clear-groups -- test -w "$profile" || return 1
    else
        [ -w "$profile" ] || return 1
    fi
    export DEEPSEEK_WEB_PROFILE_DIR="$profile"
}

case "${DEEPSEEK_WEB_ENABLED:-}" in
    [Tt][Rr][Uu][Ee]|1)
        if ! prepare_profile; then
            echo 'DeepSeek Web worker unavailable: expected a mounted writable Railway volume' >&2
        fi
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    exec setpriv --reuid=65532 --regid=65532 --clear-groups --no-new-privs \
        /opt/deepseek-venv/bin/python3 /opt/deepseek-web/supervise.py
fi
exec /opt/deepseek-venv/bin/python3 /opt/deepseek-web/supervise.py
