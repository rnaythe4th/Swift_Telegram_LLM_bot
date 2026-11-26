# Xiaomi Mi 5s с Alpine 3.23

`llmchat` состоит из двух служб runit. Swift читает Telegram через long polling, а DeepSeek Web использует Firefox и отдельный профиль. Swift, HTTP worker и временный VNC используют локальные порты `18080`, `8766` и `15944` соответственно. Профиль хранится в `/opt/llmchat/data/firefox-profile`.

По умолчанию служба открывает DeepSeek в Firefox при запуске и держит окно открытым между запросами. При переходе с локального API задайте `DEEPSEEK_WEB_BACKEND=browser` и `DEEPSEEK_WEB_IDLE_SECONDS=never` в `/opt/llmchat/.env`. Служба использует существующий профиль Firefox. Чтобы ограничить время простоя, задайте `DEEPSEEK_WEB_IDLE_SECONDS` в секундах.

До установки сверить статусы всех работающих ботов, свободные порты, память и место на диске. Из прежнего `.env` нужны `TG_BOT_TOKEN` и `DATABASE_URL` с сессионным подключением к PostgreSQL, а также `STATE_ENCRYPTION_KEY`, если он использовался раньше. Перенести `ROUTER_API_KEY` для OpenRouter и Yandex и `DEEPSEEK_API_KEY` для DeepSeek API, чтобы сохранить доступ к этим сервисам. Добавить новый `DEEPSEEK_WEB_WORKER_TOKEN` со значением из `openssl rand -hex 32`. Скопировать файл по SSH с правами `0600`. Если предыдущий экземпляр этого же Telegram-бота активен, остановить его перед включением polling на телефоне.

Для Supabase взять корневой сертификат в настройках базы. После установки пользователя разместить его в `/opt/llmchat/certs/supabase-ca.crt` с владельцем `root:llmchat` и правами `0640`, каталог создать с тем же владельцем и правами `0750`. В URL подключения указать `sslmode=verify-full&sslrootcert=/opt/llmchat/certs/supabase-ca.crt`. Использовать хост и порт Session pooler из настроек своего проекта. [Подключение и проверка сертификата Supabase](https://supabase.com/docs/guides/database/connecting-to-postgres#connecting-with-ssl)

## Установка

На Mac запустить `sh deploy/android/build.sh /tmp/llmchat-stage`. Сборка подготовит Linux aarch64 бинарник `bin/LLM_chat_bot`, его приватный glibc-рантайм в `lib/` и каталог `deepseek-web/`. Версия статического SDK использует инструкцию ARMv8.1, которой нет у процессора этого телефона. Приватный загрузчик работает из каталога релиза вместе с его библиотеками. В staging-каталог скопировать скрипты `deploy/android/{install.sh,llmchat.init,runtime.py,signal-group.sh}`, сохранив путь `deploy/android/`. При наличии подготовленных wheels положить их в `wheels/`.

На телефоне нужны `python3.12`, runit, `runuser`, `start-stop-daemon`, Bash и пакеты `firefox-esr geckodriver xvfb x11vnc xauth xdpyinfo font-liberation`. Перед установкой недостающих пакетов посмотреть план `apk add --simulate`. Для первой установки выполнить в Alpine от root:

```sh
sh /tmp/STAGE/deploy/android/install.sh /tmp/STAGE RELEASE_ID /tmp/phone.env
/etc/init.d/llmchat start
cd /opt/llmchat
runuser -u llmchat -- sv status /opt/llmchat/service/bot /opt/llmchat/service/web
rm /opt/llmchat/service/web/down
runuser -u llmchat -- sv -w 45 up /opt/llmchat/service/web
```

`RELEASE_ID` принимает полный Git SHA или `local-<short-sha>-<UTC timestamp>` для локального рабочего дерева. Пока компилируется Swift, установщик с `--browser-only` позволяет запустить один Web worker. Перед включением Swift перенести `bin/LLM_chat_bot` и `lib/` в `/opt/llmchat/current/`. Владелец файлов `root:llmchat`, права каталогов, бинарника и `lib/ld-linux-aarch64.so.1` — `0750`, остальных библиотек — `0640`.

## Вход с Mac

Mac и телефон должны быть в одной локальной сети. Команда подключения к `192.168.100.9:2222`, настройки ключа хоста и пример `~/.ssh/config` приведены в [инструкции SSH](../../docs/deepseek-api-phone.md#4-ssh-доступ-к-телефону-с-mac). Если ключ SSH защищён паролем, загрузите его в свой агент командой `ssh-add ~/.ssh/milby_phone` перед запуском с `BatchMode=yes`.

В отдельном SSH-сеансе на телефоне запустить временное окно:

```sh
cd /opt/llmchat
runuser -u llmchat -- python3.12 -B /opt/llmchat/runtime.py maintenance start
```

С Mac открыть SSH-туннель на тот же телефон. К своей рабочей SSH-команде добавить `-N -T -o ExitOnForwardFailure=yes -L 127.0.0.1:15944:127.0.0.1:15944`. Подключиться командой `open vnc://127.0.0.1:15944`, ввести временный пароль из первого терминала и войти в DeepSeek в открытом Firefox.

Завершить окно из другого SSH-сеанса. При первом входе или смене аккаунта использовать `--account-changed`. После подтверждения `ready` включить Swift:

```sh
cd /opt/llmchat
runuser -u llmchat -- python3.12 -B /opt/llmchat/runtime.py maintenance finish --account-changed
test -x /opt/llmchat/current/bin/LLM_chat_bot
rm /opt/llmchat/service/bot/down
runuser -u llmchat -- sv -w 45 up /opt/llmchat/service/bot
wget -qO- http://127.0.0.1:18080/ready
```

Проверить запуск polling и восстановление PostgreSQL по `/opt/llmchat/log/bot/current`. DeepSeek Web выбран в новых чатах и автоматически применяется к ранее сохранённым чатам при первом запуске этой версии. Выбор другого сервиса через /menu → «Сервис ИИ» сохраняется после перезапуска.

В DeepSeek Web любой участник может настроить DeepThink в меню или командами `/reasoning on` и `/reasoning off`, а роль можно изменить через меню или `/setrole`. В группе обе настройки действуют на текущий топик. В меню «Своя роль» отправьте текст ответом на подсказку бота.

## Управление

Из `/opt/llmchat` выполнять `runuser -u llmchat -- sv status /opt/llmchat/service/bot /opt/llmchat/service/web`. Логи находятся в `/opt/llmchat/log/{bot,web}/current`. Чтобы выключить службу до явного включения, создать её файл `down` от root, затем вызвать `sv -w 45 down` с полным путём службы.

Профиль Linux Deploy на этом телефоне уже использует `/etc/bots.d`. Для автозапуска проверить, что имя свободно, и добавить ссылку `/etc/bots.d/40-llmchat` на `/etc/init.d/llmchat`. Запуск нового init-скрипта можно проверить без перезапуска телефона.
