# DeepSeek Web на Railway с Supabase

DeepSeek Web выключен по умолчанию. Для пилота используйте отдельную среду, Telegram-бота, базу и аккаунт DeepSeek. Проверьте обычный режим без поиска и DeepThink. Подготовьте синтетические сообщения для двух разных топиков.

## Railway Free

На Free одна реплика сервиса получает до 0,5 ГБ RAM и 1 vCPU. У проекта есть том 0,5 ГБ. Если база уже в Supabase, проверьте, доступен ли этот том для профиля Firefox. Месячный кредит $1 расходуется также на CPU, том и исходящий трафик. Локальная проба браузера без Swift и сайта достигала 437 МиБ при ограничении 512 МиБ. Оставьте Web выключенным в рабочей среде, пока полный образ не пройдёт замеры с запасом 25% в худшем сценарии. [Railway Free](https://docs.railway.com/pricing/free-plan) · [Замеры браузера](deepseek-web-agent-instructions.md#1-агент-деплоя)

Прикрепите том к сервису бота, например в `/data`. При старте контейнер берёт точку монтирования из `RAILWAY_VOLUME_MOUNT_PATH` и создаёт `deepseek-web/profile` с правами `0700`. Под UID/GID 65532 работают Swift, worker, Firefox, Xvfb и VNC. Без смонтированного записываемого тома worker недоступен. Во время redeploy с томом Railway останавливает предыдущий экземпляр перед подключением тома к новому. [Тома Railway](https://docs.railway.com/volumes/reference#caveats)

## Настройки пилота

В новом сервисе укажите сборку через корневой `Dockerfile`, проверку `/ready` с таймаутом 300 секунд и политику рестарта On Failure с 10 повторами. Команду запуска оставьте из образа, чтобы стартовый процесс подготовил том и снизил привилегии. Сверьте значения в Deployment Details. Railway указывает 1 декабря 2026 года как дату отключения прежнего формата `railway.toml`. [Настройки деплоя Railway](https://docs.railway.com/config-as-code)

| Переменная | Значение |
| --- | --- |
| `TG_BOT_TOKEN` | Токен выделенного бота |
| `OWNER_USER_ID` | Telegram ID владельца |
| `DATABASE_URL` | URL подключения Supabase в режиме Session pooler, порт 5432 |
| `DEEPSEEK_WEB_ENABLED` | `true` после настройки тома |
| `DEEPSEEK_WEB_WORKER_TOKEN` | Отдельный токен из `openssl rand -hex 32` |
| `DEEPSEEK_WEB_WORKER_PORT` | Порт loopback, по умолчанию 8765 |
| `DEEPSEEK_WEB_IDLE_SECONDS` | Время простоя перед закрытием Firefox, по умолчанию 60 секунд |
| `DEEPSEEK_WEB_DEEPTHINK` | `1` включает DeepThink; для первых замеров оставьте пустым |
| `DEFAULT_AI_PROVIDER` | По умолчанию `deepseek-web`, когда Web включён. Можно явно указать другой настроенный сервис |
| `DEEPSEEK_WEB_REMOTE_UNIT_LIMIT` | Порог ротации диалога по сумме UTF-16 единиц вопросов и ответов, по умолчанию 60 000 |
| `DEEPSEEK_WEB_QUOTA_PAUSE_SECONDS` | Пауза после подтверждённой квоты без срока, по умолчанию 300 секунд |
| `TELEGRAM_WEBHOOK_SECRET` | Секрет webhook, отделённый от токена worker |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | 30 секунд для первого замера; скорректируйте по времени остановки полного сервиса |

При выборе DeepSeek Web по умолчанию сохранённые чаты получают этот сервис при обновлении, а новые используют его сразу. Последующие переключения через меню сохраняются. В группах бот сообщает об отправке вопросов в аккаунт DeepSeek перед первым ответом. Для отправки реплик из прослушки администратор разрешает передачу контекста через меню прослушки.

Возьмите адрес и имя пользователя Session pooler из **Connect** в Supabase. Режим 5432 сохраняет сессионную advisory-блокировку писателя. Шаблон URL для приложения приведён ниже. URL с паролем храните в переменных сервиса. Укажите ключи `DEEPSEEK_API_KEY` и `ROUTER_API_KEY` для используемых API-адаптеров. [Подключение к Postgres в Supabase](https://supabase.com/docs/guides/database/connecting-to-postgres)

```text
postgres://postgres.<project-ref>:<password>@<session-pooler-host>:5432/postgres?sslmode=require
```

Telegram webhook и `/ready` обслуживает Swift на `PORT`. При передаче writer lock `/ready` может ответить 200, пока webhook отвечает 503. Web допускает работу отдельно после восстановления Postgres и получения writer lock и готовности worker. Порты worker и VNC доступны на loopback контейнера. Проверьте полноту записи состояния на SIGTERM. При остановке Swift и worker получают сигнал, открытое окно входа закрывается. [Завершение деплоя Railway](https://docs.railway.com/deployments/deployment-teardown)

## Вход с Mac

1. Добавьте свой SSH-ключ в Railway. Возьмите поле `@deploymentInstanceId` из HTTP-лога целевого активного деплоя. Используйте этот ID для всех команд и туннеля, чтобы оба канала попадали в один контейнер. [Логи Railway](https://docs.railway.com/cli/logs) · [SSH Railway](https://docs.railway.com/cli/ssh)
2. В первом терминале начните временный сеанс. Команда закрывает допуск Web, освобождает профиль и печатает одноразовый пароль VNC. Она работает на переднем плане до завершения сеанса, выхода Firefox или таймаута. По умолчанию сеанс длится 600 секунд. Допустимый диапазон `--seconds` составляет 60–900 секунд.

   ```sh
   ssh -t '<deployment-instance-id>@ssh.railway.com' 'deepseek-web-maintenance start'
   ```

3. Во втором терминале откройте туннель. В третьем выполните `open vnc://127.0.0.1:15943` и введите временный пароль. Войдите непосредственно в DeepSeek, пройдите ручную проверку, если она появилась, и проверьте имя аккаунта. Отключите **Improve the model for everyone** и память между чатами, если эта настройка доступна.

   ```sh
   ssh -N -T -o ExitOnForwardFailure=yes \
     -L 127.0.0.1:15943:127.0.0.1:15943 \
     '<deployment-instance-id>@ssh.railway.com'
   ```

4. Подтвердите, что вошли в ожидаемый аккаунт, командой завершения. Для первого входа в чистый профиль укажите `--account-changed`. При повторной авторизации того же аккаунта используйте `finish` без флага. При подтверждённой смене аккаунта выполните `finish --account-changed`, чтобы сменить эпоху и прекратить использование старых привязок и паузы квоты. Команда закрывает окно и проверяет авторизованный composer в headless-режиме. При таймауте, обрыве SSH или ошибке входа допуск остаётся закрытым до подтверждения владельца.

   ```sh
   ssh '<deployment-instance-id>@ssh.railway.com' 'deepseek-web-maintenance status'
   ssh '<deployment-instance-id>@ssh.railway.com' 'deepseek-web-maintenance finish'
   ```

5. Закройте SSH-туннель. Сделайте синтетический ход из Telegram, перезапустите контейнер и проверьте, что бот продолжает тот же диалог. В отдельном топике проверьте отсутствие доступа к слову из первого. После очистки убедитесь, что слово из прежнего диалога не воспроизводится.

## Замеры перед включением

Снимите показания при работающем Swift без Firefox, в headless-простое, на серии запросов, на длинном диалоге, при входе через VNC и во время выключения. Для сравнения памяти повторите прогоны в свежих контейнерах с лимитом 512 МиБ и 1 ГиБ, одинаковым лимитом RAM+swap и одним vCPU. Запишите объём образа, время запуска, выбранный объём выборки и p95 времени хода на имитаторе. Для живого пилота хватит ограниченной серии в пределах квоты владельца. Сверьте реальные лимиты и стоимость в Railway.

```sh
uname -m
df -h /dev/shm "${RAILWAY_VOLUME_MOUNT_PATH}"
cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.current \
    /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events
cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu.stat
du -sh "${RAILWAY_VOLUME_MOUNT_PATH}/deepseek-web/profile"
firefox-esr --version
geckodriver --version
```

Проверьте права записи профиля после redeploy, отсутствие параллельного владельца, восстановление после принудительной остановки и доступность chat.deepseek.com из региона сервиса. Зафиксируйте сообщения песочницы Firefox и проверьте браузер со штатными защитами. Повторите вход и замеры на целевой архитектуре Railway.

### Локальная проверка контейнера

На Linux ARM64 в Docker Desktop собран этап `browser-runtime` с Firefox ESR 153.7.0 и geckodriver 0.36.0. Два вспомогательных процесса имитировали Swift и HTTP worker. Сценарий открывал локальную страницу из временного окна входа, проверял ответ VNC на loopback, закрывал окно командой `finish` и читал постоянную cookie через новый headless Firefox. В обоих прогонах использовались один vCPU и `/dev/shm` 64 МиБ. Во втором контейнере использован том первого.

| Лимит RAM и RAM+swap | `memory.current` с окном | `memory.current` headless | `memory.peak` | События `max` / OOM | Профиль |
| --- | --- | --- | --- | --- | --- |
| 512 МиБ | 512 МиБ | 512 МиБ | 512 МиБ | 2807 / 0 | 38 МиБ |
| 1 ГиБ | 584 МиБ | 631 МиБ | 657 МиБ | 0 / 0 | 40 МиБ |

Проверены UID/GID 65532, права профиля `0700`, освобождение блокировки после VNC, остановка обоих процессов по SIGTERM и работа имитатора `/ready` без worker. Прогон 512 МиБ исчерпал запас памяти уже с локальной страницей. Полный Swift-сервис, регион Railway, вход в DeepSeek и SSH с Mac требуют отдельного прогона на стенде.

Соберите тот же этап контейнера и запустите браузерные тесты с локальной страницей:

```sh
docker build --target browser-runtime -t deepseek-web-fixture .
docker run --rm --memory=1g --memory-swap=1g --cpus=1 --shm-size=64m \
  -v "$PWD/deepseek-web:/source:ro" deepseek-web-fixture sh -ec '
    pip install --no-cache-dir -r /source/requirements.txt
    runuser -u bot -- env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/source \
      DEEPSEEK_WEB_TEST_FIREFOX=/usr/bin/firefox-esr \
      DEEPSEEK_WEB_TEST_GECKODRIVER=/usr/local/bin/geckodriver \
      /opt/deepseek-venv/bin/python -m unittest discover -s /source/tests -v
  '
```
