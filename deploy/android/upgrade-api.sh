#!/bin/sh
# Phone-side code-only rollout of the DeepSeek Web worker; bot binary and
# other applications are not restarted or overwritten.
set -eu
umask 077
root=/opt/llmchat
service=$root/service/web
if [ "$(id -u)" -ne 0 ] || [ "$#" -ne 2 ]; then
    echo 'Usage (root on Alpine): upgrade-api.sh STAGED_DIRECTORY RELEASE_ID' >&2
    exit 2
fi
stage=$(realpath "$1")
id=$2
case "$id" in *[!a-zA-Z0-9-]*|'') echo 'Invalid release ID' >&2; exit 2;; esac
[ -d "$stage/free-deepseek-api" ] && [ -f "$stage/deepseek-web/api_backend.py" ] || exit 2
[ -f "$stage/runtime.py" ] || exit 2
[ -x /usr/bin/node ] || { echo 'node is required before upgrading' >&2; exit 2; }
[ -L "$root/current" ] || { echo 'Expected release symlink' >&2; exit 2; }
old_link=$(readlink "$root/current")
old=$(realpath "$root/current")
case "$old" in "$root"/releases/*) ;; *) echo 'Invalid previous release' >&2; exit 2;; esac
[ -d "$old/.venv" ] && [ -x "$old/bin/LLM_chat_bot" ] || exit 2
[ -f "$root/runtime.py" ] && [ -d "$root/service/web" ] || exit 2
new=$root/releases/$id
[ ! -e "$new" ] && [ ! -L "$new" ] || { echo 'Release already exists' >&2; exit 2; }
mkdir -m 0750 "$new"
chown root:llmchat "$new"
# Keep a forensic copy of the previous runtime in this distinct new release.
cp -p "$root/runtime.py" "$new/runtime.py.previous"
cp -a "$old/bin" "$new/bin"
if [ -d "$old/lib" ]; then cp -a "$old/lib" "$new/lib"; fi
ln -s "$old/.venv" "$new/.venv"
cp -a "$stage/deepseek-web" "$new/deepseek-web"
cp -a "$stage/free-deepseek-api" "$new/free-deepseek-api"
install -m 0640 -o root -g llmchat "$stage/runtime.py" "$new/runtime.py.new"
chown -R root:llmchat "$new/deepseek-web" "$new/free-deepseek-api"
find "$new/deepseek-web" "$new/free-deepseek-api" -type d -exec chmod 0750 {} +
find "$new/deepseek-web" "$new/free-deepseek-api" -type f -exec chmod 0640 {} +
# Verify syntax before altering the live service.
python3.12 -m py_compile "$new/deepseek-web/worker.py" "$new/deepseek-web/api_backend.py" "$new/runtime.py.new"
/usr/bin/node --check "$new/free-deepseek-api/server.js"
# py_compile may create private __pycache__ directories under the restrictive umask.
find "$new/deepseek-web" "$new/free-deepseek-api" -type d -exec chmod 0750 {} +
find "$new/deepseek-web" "$new/free-deepseek-api" -type f -exec chmod 0640 {} +
# Live switching only touches the llmchat/web service. Bot and milby remain up.
# runuser inherits cwd; llmchat must not inherit root's private SSH home.
cd "$root"
/sbin/runuser -u llmchat -- test -x "$new/.venv/bin/python"
/sbin/runuser -u llmchat -- test -x "$new/bin/LLM_chat_bot"
/sbin/runuser -u llmchat -- test -r "$new/deepseek-web/worker.py"
/sbin/runuser -u llmchat -- test -r "$new/free-deepseek-api/server.js"
next_link="$root/.current-api-next-$id"
rollback_link="$root/.current-api-rollback-$$"
[ ! -e "$next_link" ] && [ ! -L "$next_link" ] || { echo 'Temporary release link exists' >&2; exit 2; }
[ ! -e "$rollback_link" ] && [ ! -L "$rollback_link" ] || { echo 'Temporary rollback link exists' >&2; exit 2; }
rollback_needed=1
rollback() {
    status=$?
    trap - 0 HUP INT TERM
    if [ "$rollback_needed" -eq 1 ]; then
        echo 'API rollout failed; restoring previous web release' >&2
        /sbin/runuser -u llmchat -- /usr/sbin/sv -w 45 down "$service" >/dev/null 2>&1 || true
        current_link=$(readlink "$root/current" 2>/dev/null || true)
        if [ "$current_link" != "$old_link" ]; then
            if ln -s "$old_link" "$rollback_link"; then
                mv -Tf "$rollback_link" "$root/current" || echo 'ERROR: could not restore current symlink' >&2
            else
                echo 'ERROR: could not prepare rollback symlink' >&2
            fi
        fi
        install -m 0640 -o root -g llmchat "$new/runtime.py.previous" "$root/runtime.py" ||
            echo 'ERROR: could not restore previous runtime.py' >&2
        /sbin/runuser -u llmchat -- /usr/sbin/sv -w 45 up "$service" >/dev/null 2>&1 ||
            echo 'ERROR: previous web service did not restart' >&2
    fi
    exit "$status"
}
trap rollback 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/sbin/runuser -u llmchat -- /usr/sbin/sv -w 45 down "$service"
ln -s "releases/$id" "$next_link"
mv -Tf "$next_link" "$root/current"
install -m 0640 -o root -g llmchat "$new/runtime.py.new" "$root/runtime.py"
/sbin/runuser -u llmchat -- /usr/sbin/sv -w 45 up "$service"
# Check both child services. Refuse to call rollout complete until health passes.
if ! python3.12 - "$root" <<'PY'
import http.client, json, pathlib, shlex, sys, time
root=pathlib.Path(sys.argv[1]); data={}
for line in (root/'.env').read_text().splitlines():
    if not line.strip() or line.lstrip().startswith('#'): continue
    k,_,v=line.partition('='); vals=shlex.split(v, comments=True)
    if vals: data[k.strip().removeprefix('export ')]=vals[0]
key=data.get('DEEPSEEK_WEB_WORKER_TOKEN','')
if not key: sys.exit(2)
api_port=int(data.get('DEEPSEEK_WEB_API_PORT','9655'))
def get(port,path):
    con=http.client.HTTPConnection('127.0.0.1',port,timeout=1)
    try:
        con.request('GET',path,headers={'Authorization':'Bearer '+key})
        response=con.getresponse()
        body=json.loads(response.read(65536))
        return response.status,body
    finally:
        con.close()
for attempt in range(24):
    try:
        worker_status,worker=get(8766,'/v1/health')
        api_status,api=get(api_port,'/health')
        if (worker_status==200 and worker.get('status')=='ready' and worker.get('ready') is True
                and api_status==200 and api.get('service')=='FreeDeepseekAPI'
                and api.get('config_ready') is True):
            sys.exit(0)
    except (OSError, ValueError, http.client.HTTPException):
        pass
    time.sleep(0.5)
sys.exit(1)
PY
then
    echo 'API startup health check failed' >&2
    exit 1
fi
rollback_needed=0
trap - 0 HUP INT TERM
printf 'Upgraded llmchat web service to %s; previous release %s\n' "$id" "$old_link"
