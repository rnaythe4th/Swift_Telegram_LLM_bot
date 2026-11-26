# DeepSeek API на телефоне

**Состояние документа:** 24 ноября 2026 года  
**Устройство:** Xiaomi Mi 5s, Alpine Linux  
**Корень приложения:** `/opt/llmchat`  
**Релиз API на эту дату:** `releases/deepseek-api-20261124-02`

Этот документ описывает конфигурацию локального API и общие процедуры SSH. Для актуальной конфигурации с постоянно открытым Firefox см. [инструкцию Android](../deploy/android/README.md).

## 1. Архитектура

```text
Telegram
   │
   ▼
Swift bot service
/opt/llmchat/service/bot
   │  очередь, контекст и маршрутизация чатов
   ▼
HTTP 127.0.0.1:8766
   │
   ▼
Python DeepSeek worker
deepseek-web/worker.py
   │
   ▼
APIBackend
deepseek-web/api_backend.py
   │  HTTP + x-agent-session
   ▼
HTTP 127.0.0.1:9655
   │
   ▼
FreeDeepseekAPI (Node.js)
   │
   ▼
DeepSeek Web API
```

### Процессы и управление

- `/opt/llmchat/service/bot` — отдельная runit-служба Swift-приложения и Telegram polling.
- `/opt/llmchat/service/web` — runit-служба, запускающая `/opt/llmchat/runtime.py web`.
- `runtime.py web` запускает и контролирует два дочерних процесса: Python worker и Node.js FreeDeepseekAPI. Если один из процессов завершается, web-служба считается неисправной и перезапускается runit.
- Milby работает в отдельных runit-службах и не зависит от переключения DeepSeek API.

### Локальные HTTP-интерфейсы

| Компонент | Адрес | Назначение |
|---|---|---|
| Python worker | `127.0.0.1:8766` | Контракт между Swift и DeepSeek transport |
| FreeDeepseekAPI | `127.0.0.1:9655` | Локальный API-прокси к DeepSeek Web |

Оба сервера привязаны только к loopback. Их порты не предназначены для доступа из LAN или интернета. Оба интерфейса используют Bearer-аутентификацию.

Worker предоставляет операции `prepare`, `send`, `status`, `reconcile`, `cancel`, `health` и maintenance. Node API принимает `POST /v1/chat/completions`, health-запросы и внутреннюю команду перезагрузки auth-данных.

### Изоляция окружения

`runtime.py` формирует отдельное окружение для Node.js. В него передаются адрес loopback, порт API, путь к auth-файлу и отдельный proxy key. Telegram bot token и параметры БД в окружение Node API не передаются.

## 2. Сессии, история и поведение запросов

- Для каждого диалога создаётся отдельный случайный идентификатор upstream-сессии. Он передаётся Node API в заголовке `x-agent-session`.
- Локальный журнал диалога хранится в `/opt/llmchat/data/api-chats/`. Каталог закрыт правами `0700`, файлы — `0600`.
- Журнал содержит завершённые пары user/assistant и отметку незавершённой операции. Запись выполняется через временный файл, `fsync` и атомарную замену.
- При перезапуске Node API следующий запрос восстанавливает контекст из локального журнала. В рамках живой upstream-сессии передаются только новые сообщения.
- Если соединение оборвалось после возможной отправки запроса, операция получает состояние `uncertain`. Автоматического повторного отправления того же prompt нет: это защищает от дублирования ответа и побочных эффектов.
- `reconcile` возвращает результат только тогда, когда завершённый ответ уже присутствует в локальном журнале. Если подтверждения нет, результат остаётся неопределённым.
- Для обычного и DeepThink-запроса выбираются разные модели FreeDeepseekAPI; выбор DeepThink может задаваться на уровне конкретной операции.

## 3. Авторизация и временный Firefox

Постоянный обмен сообщениями выполняется через Node API. Firefox используется только для проверки/обновления авторизации и ручного входа.

- Auth-файл: `/opt/llmchat/data/deepseek-auth.json`.
- Владелец файла: `llmchat`; права: `0600`.
- Профиль Firefox: `/opt/llmchat/data/firefox-profile`.
- По умолчанию период проверки авторизации — 21600 секунд (6 часов), параметр `DEEPSEEK_WEB_AUTH_REFRESH_SECONDS`.
- Worker временно открывает Firefox с сохранённым профилем, проверяет авторизацию, получает актуальные token/cookies, безопасно обновляет локальный auth-файл и вызывает локальный `POST /admin/accounts/reload` в Node API. После проверки Firefox закрывается.
- Значения token, cookies, proxy key и содержимое auth-файла не выводить в логи, не копировать в Git и не передавать через GitHub Actions.

## 4. SSH-доступ к телефону с Mac

Подключение выполняется из Terminal на Mac. Используются root-доступ по SSH, порт `2222` и отдельный приватный ключ `~/.ssh/milby_phone`.

### Одноразовая команда

```bash
ssh -p 2222 \
  -i "$HOME/.ssh/milby_phone" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o HostKeyAlgorithms=ssh-ed25519 \
  -o HostKeyAlias='[192.168.0.104]:2222' \
  root@192.168.100.9
```

Команда использует проверку host key. Не заменяйте `StrictHostKeyChecking=yes` на отключённую проверку и не принимайте неожиданный новый ключ без отдельной проверки.

### Постоянный alias в `~/.ssh/config`

Добавьте на Mac:

```sshconfig
Host llmchat-phone
    HostName 192.168.100.9
    Port 2222
    User root
    IdentityFile ~/.ssh/milby_phone
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    HostKeyAlgorithms ssh-ed25519
    HostKeyAlias [192.168.0.104]:2222
```

После этого подключение выполняется короткой командой:

```bash
ssh llmchat-phone
```

Для передачи файлов используйте тот же host key policy и ключ:

```bash
scp -P 2222 \
  -i "$HOME/.ssh/milby_phone" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o HostKeyAlgorithms=ssh-ed25519 \
  -o HostKeyAlias='[192.168.0.104]:2222' \
  /path/to/file root@192.168.100.9:/tmp/
```

Не копируйте в staging-каталог `.env`, auth-файлы, Firefox-профиль, Cookies или приватные ключи.

## 5. Проверка состояния на телефоне

После SSH-подключения:

```sh
# Активный релиз
readlink /opt/llmchat/current

# Основные службы
sv status /opt/llmchat/service/web
sv status /opt/llmchat/service/bot
sv status /opt/milby/service/bot
sv status /opt/milby/service/updater

# Loopback listeners
netstat -lnt | grep -E ':8766|:9655'

# Процессы API и worker
ps -eo pid,ppid,rss,comm,args | grep -E 'runtime.py|worker.py|free-deepseek-api/server.js'

# Память
free -m
```

Ожидаемые listeners: `127.0.0.1:8766` и `127.0.0.1:9655`. Не публикуйте вывод окружения и не используйте `cat` для `.env` или auth-файла.

Maintenance health/status запускается от пользователя `llmchat`:

```sh
cd /opt/llmchat
/sbin/runuser -u llmchat -- /opt/llmchat/current/.venv/bin/python -B /opt/llmchat/runtime.py maintenance status
```

## 6. Ручной вход через VNC

VNC доступен только на loopback телефона, порт `15944`. Для доступа с Mac используется SSH-туннель; открывать VNC-порт наружу не нужно.

1. В первом SSH-сеансе на телефоне запустите временную сессию:

   ```sh
   cd /opt/llmchat
   /sbin/runuser -u llmchat -- /opt/llmchat/current/.venv/bin/python -B /opt/llmchat/runtime.py maintenance start --seconds 600
   ```

   Команда выведет одноразовый VNC-пароль. Сессия ограничена 600 секундами; worker остаётся на maintenance до успешного `finish`.

2. Во втором Terminal на Mac откройте туннель:

   ```bash
   ssh -N -p 2222 \
     -i "$HOME/.ssh/milby_phone" \
     -o IdentitiesOnly=yes \
     -o BatchMode=yes \
     -o StrictHostKeyChecking=yes \
     -o HostKeyAlgorithms=ssh-ed25519 \
     -o HostKeyAlias='[192.168.0.104]:2222' \
     -L 15944:127.0.0.1:15944 \
     root@192.168.100.9
   ```

3. На Mac откройте VNC:

   ```bash
   open vnc://127.0.0.1:15944
   ```

   Введите одноразовый пароль из первого SSH-сеанса.

4. После завершения входа в отдельном SSH-сеансе на телефоне выполните:

   ```sh
   cd /opt/llmchat
   /sbin/runuser -u llmchat -- /opt/llmchat/current/.venv/bin/python -B /opt/llmchat/runtime.py maintenance finish
   ```

   Если был сменён DeepSeek-аккаунт, используйте `maintenance finish --account-changed`. Команда проверит вход, обновит auth-файл и вернёт worker в состояние ready. Не завершайте обслуживание, пока status не станет ready.

## 7. Сборка и обновление

Для развёртывания этой конфигурации требуется явный выбор `DEEPSEEK_WEB_BACKEND=api` в `/opt/llmchat/.env`. В браузерном режиме локальный Node API не запускается.

Зависимость FreeDeepseekAPI хранится как Git submodule в `FreeDeepseekAPI`, зафиксированный на проверенном upstream-коммите. После клонирования проекта:

```bash
git submodule update --init --recursive
```

Сборка code-only staging выполняется из корня проекта на Mac:

```bash
sh deploy/android/build-api.sh /tmp/llmchat-deepseek-api-stage
```

Скрипт собирает только необходимые runtime-файлы. Он не должен включать `.env`, `deepseek-auth.json`, профили браузера, `.git`, `.pem` или `.key`.

После безопасной передачи staging-каталога на телефон и копирования `deploy/android/upgrade-api.sh` запустите на телефоне от root:

```sh
sh /tmp/upgrade-api.sh /tmp/llmchat-deepseek-api-stage RELEASE_ID
```

Используйте новый уникальный `RELEASE_ID`. Upgrade-скрипт:
- создаёт отдельный каталог релиза;
- переносит Swift binary и libraries из текущего релиза;
- повторно использует его Python virtualenv через symlink;
- устанавливает Python worker, API adapter, Node API и runtime;
- проверяет Python/Node syntax и доступ пользователя `llmchat` к файлам;
- атомарно переключает `/opt/llmchat/current`;
- перезапускает только `/opt/llmchat/service/web`;
- проверяет health обоих локальных API и при ошибке запуска восстанавливает предыдущий runtime/release.

Не удаляйте предыдущие каталоги релизов: новый релиз использует их virtualenv. Telegram bot и Milby не требуют перезапуска при обновлении только web/API слоя.

## 8. Проверки кода

Из корня проекта:

```bash
PYTHONPATH=deepseek-web python3 -m unittest discover -s deepseek-web/tests -v
node --check FreeDeepseekAPI/server.js
# Полный Node unit suite запускайте на Linux: integration test peer UID использует Linux-specific semantics.
npm test --prefix FreeDeepseekAPI
sh -n deploy/android/build-api.sh
sh -n deploy/android/upgrade-api.sh
git diff --check
git -C FreeDeepseekAPI diff --check
```

После деплоя дополнительно проверьте runit status, symlink `current`, оба loopback listeners и выполните один реальный тестовый запрос через приложение. Не используйте для smoke test реальный пользовательский диалог.

## 9. Зафиксированное состояние телефона

Проверка по SSH 24 ноября 2026 года подтвердила:

- `current -> releases/deepseek-api-20261124-02`;
- службы `/opt/llmchat/service/web` и `/opt/llmchat/service/bot` находятся в состоянии run;
- службы `/opt/milby/service/bot` и `/opt/milby/service/updater` находятся в состоянии run;
- listeners доступны только на `127.0.0.1:9655` и `127.0.0.1:8766`;
- maintenance status сообщает `DeepSeek Web worker: ready`;
- временная VNC-сессия закрыта;
- приватные значения конфигурации, ключи и содержимое пользовательских данных в документацию не включаются.
