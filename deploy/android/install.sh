#!/bin/sh
set -eu
umask 077

root=/opt/llmchat
account=llmchat
init=/etc/init.d/llmchat
scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'Run inside Alpine as root.'
browser_only=false
if [ "${1:-}" = --browser-only ]; then
    browser_only=true
    shift
fi
[ "$#" -eq 3 ] || fail "Usage: $0 [--browser-only] STAGED_RELEASE RELEASE_ID ENV_FILE"
[ "$(uname -m)" = aarch64 ] || fail 'This release requires aarch64.'
[ -r /etc/alpine-release ] || fail 'This installer requires Alpine.'
stage=$(realpath "$1")
release_id=$2
env_file=$(realpath "$3")
case "$release_id" in *[!a-zA-Z0-9-]*) fail 'Invalid release ID.' ;; esac
printf '%s\n' "$release_id" | grep -Eq '^([0-9a-f]{40}|local-[0-9a-f]{8}-[0-9]{8}T[0-9]{6}Z)$' || \
    fail 'Use a full Git SHA or local-<short-sha>-<UTC timestamp> for the release ID.'
[ -f "$env_file" ] || fail 'Environment file missing.'
[ "$browser_only" = true ] || [ -f "$stage/bin/LLM_chat_bot" ] || fail 'Swift binary missing.'
for file in requirements.txt worker.py browser.py maintenance.py; do
    [ -f "$stage/deepseek-web/$file" ] || fail "Missing deepseek-web/$file in staged release."
done
for program in python3.12 getent useradd usermod start-stop-daemon runuser runsvdir sv svlogd chpst bash; do
    command -v "$program" >/dev/null || fail "Missing $program."
done
inet_group=$(getent group 3003 | cut -d: -f1)
[ -n "$inet_group" ] || fail 'Android network group GID 3003 is unavailable.'
python3.12 "$scripts/runtime.py" check "$env_file"

if [ -L "$root" ] || [ -L "$init" ]; then
    fail 'Deployment paths must be real files or directories.'
fi
marker=$root/.llm-chat-bot-deployment
if [ -e "$root" ] || [ -e "$init" ] || id "$account" >/dev/null 2>&1 || getent group "$account" >/dev/null; then
    [ -f "$marker" ] && [ "$(cat "$marker")" = 'LLM_chat_bot Alpine runit' ] || fail 'The llmchat name is already in use.'
    [ ! -e "$root/current" ] && [ ! -L "$root/current" ] || fail 'The initial release is already installed.'
    [ ! -e /run/llmchat-runsvdir.pid ] || fail 'The llmchat supervisor is already registered.'
else
    install -d -m 0750 "$root"
    printf '%s\n' 'LLM_chat_bot Alpine runit' > "$marker"
fi

if ! id "$account" >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir "$root/home" --shell /sbin/nologin "$account"
fi
usermod --append --groups "$inet_group" "$account"
install -d -m 0750 -o root -g "$account" "$root" "$root/releases" "$root/service" "$root/log" "$root/run"
install -d -m 0700 -o "$account" -g "$account" \
    "$root/home" "$root/data" "$root/data/firefox-profile" "$root/data/cache" \
    "$root/run/worker" "$root/run/tmp" "$root/log/bot" "$root/log/web"
install -m 0600 -o "$account" -g "$account" "$env_file" "$root/.env"

release=$root/releases/$release_id
mkdir -m 0750 "$release" || fail "Cannot create release directory: $release."
trap 'rm -rf -- "$release"' EXIT
install -d -m 0750 -o root -g "$account" "$release/bin" "$release/deepseek-web"
if [ "$browser_only" = false ]; then
    install -m 0750 -o root -g "$account" "$stage/bin/LLM_chat_bot" "$release/bin/LLM_chat_bot"
    if [ -d "$stage/lib" ]; then
        [ -f "$stage/lib/ld-linux-aarch64.so.1" ] || fail 'The bundled glibc loader is missing.'
        install -d -m 0750 -o root -g "$account" "$release/lib"
        install -m 0640 -o root -g "$account" "$stage/lib/"*.so* "$release/lib"
        chmod 0750 "$release/lib/ld-linux-aarch64.so.1"
    fi
fi
install -m 0640 -o root -g "$account" "$stage/deepseek-web/requirements.txt" "$stage/deepseek-web/"*.py "$release/deepseek-web"
python3.12 -m venv "$release/.venv"
if [ -d "$stage/wheels" ]; then
    set -- --no-index --find-links "$stage/wheels"
else
    set --
fi
"$release/.venv/bin/python" -m pip --disable-pip-version-check install \
    --no-cache-dir --only-binary=:all: "$@" -r "$release/deepseek-web/requirements.txt"
"$release/.venv/bin/python" -B -c 'import selenium'
chgrp -R "$account" "$release"
chmod -R g+rX "$release"

install -m 0640 -o root -g "$account" "$scripts/runtime.py" "$root/runtime.py"
install -m 0755 -o root -g root "$scripts/llmchat.init" "$init"
for service in bot web; do
    directory=$root/service/$service
    install -d -m 0750 -o root -g "$account" "$directory" "$directory/log" "$directory/control"
    install -d -m 0700 -o "$account" -g "$account" "$directory/supervise" "$directory/log/supervise"
    printf '#!/bin/sh\nexec 2>&1\ncd /opt/llmchat\nexec chpst -P python3.12 -B /opt/llmchat/runtime.py %s\n' "$service" > "$directory/run"
    printf '#!/bin/sh\nsleep 3\n' > "$directory/finish"
    printf '#!/bin/sh\nexec svlogd -tt /opt/llmchat/log/%s\n' "$service" > "$directory/log/run"
    printf 's1000000\nn5\n' > "$root/log/$service/config"
    chown "$account:$account" "$root/log/$service/config"
    install -m 0750 -o root -g "$account" "$scripts/signal-group.sh" "$directory/control/t"
    install -m 0750 -o root -g "$account" "$scripts/signal-group.sh" "$directory/control/k"
    chgrp "$account" "$directory/run" "$directory/finish" "$directory/log/run"
    chmod 0750 "$directory/run" "$directory/finish" "$directory/log/run"
    touch "$directory/down"
done

ln -s "releases/$release_id" "$root/current"
trap - EXIT
printf 'Prepared %s at %s. Both services are initially down.\n' "$release_id" "$root"
if [ "$browser_only" = true ]; then
    printf '%s\n' 'Install the static Swift binary into current/bin/LLM_chat_bot before starting the bot service.'
fi
