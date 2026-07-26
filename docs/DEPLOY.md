# Деплой и настройка бота

Инструкция по развёртыванию бота в production-конфигурации: сотни параллельных
чатов, переживание рестартов без потери данных, лимиты Telegram API под
контролем.

## Что изменилось в архитектуре (кратко)

| Было | Стало |
|---|---|
| Long polling, offset в снапшоте | **Webhook** (Telegram сам хранит очередь до 24ч при рестартах); polling остался для локальной разработки |
| Бэкап всего состояния одним JSON-блобом раз в 60 сек | **Построчное хранение** в Postgres (чат / тенант / владение / конфиг) + **write-behind**: изменённые записи пишутся раз в 2 сек, платежи — мгновенно |
| Потеря до 60 сек данных при рестарте | Окно потерь ≈ 2 сек для переписки, **0 для платежей** |
| Нет лимитов на Telegram API → шторм 429 | **Token-bucket rate limiter**: ~18 msg/s глобально, 1 msg/s на личный чат, 20/min на группу + автоматический retry по `retry_after` |
| Убийство процесса при деплое | **Graceful shutdown** по SIGTERM: дожидаемся стримов (до 8с), сбрасываем всё грязное состояние |
| Повторная обработка старых updates после рестарта | Дедупликация `update_id` + **идемпотентность платежей** по `telegram_payment_charge_id` |
| — | `/health`, `/ready`, `/metrics`, лимит очереди на чат, глобальный лимит одновременных LLM-стримов |

Стек сервисов (бесплатно или дёшево):

- **Railway** (Hobby $5/мес) — хостинг, публичный домен для вебхука.
- **Supabase** (Free) — Postgres-хранилище состояния. Апгрейд: Pro $25/мес.
- **UptimeRobot** (Free, опционально) — мониторинг аптайма по `/health`.

---

## Шаг 1. Supabase

1. Зарегистрируйтесь на [supabase.com](https://supabase.com), создайте проект
   (регион ближе к Railway-региону, например `eu-central-1`).
2. Откройте **SQL Editor** и выполните целиком:

```sql
-- Контексты чатов: история, модель, настройки. PK = (chat_id, thread_id).
create table if not exists public.bot_chat_contexts (
  chat_id    bigint not null,
  thread_id  bigint not null default 0,
  data       jsonb  not null,
  updated_at timestamptz not null default now(),
  primary key (chat_id, thread_id)
);

-- Тенанты (владельцы лицензий) и их настройки/пресеты/статистика.
create table if not exists public.bot_tenants (
  username   text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- Какому тенанту принадлежит чат.
create table if not exists public.bot_chat_ownership (
  chat_id        bigint primary key,
  owner_username text not null,
  updated_at     timestamptz not null default now()
);

-- Синглтон-конфиги: цена в Stars, бесплатные модели, крипто-настройки,
-- суперадмины, обработанные платежи, offset для polling-режима.
create table if not exists public.bot_config (
  key        text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- updated_at обновляется при каждом upsert.
create or replace function public.bot_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_bot_chat_contexts_updated on public.bot_chat_contexts;
create trigger trg_bot_chat_contexts_updated
  before update on public.bot_chat_contexts
  for each row execute function public.bot_set_updated_at();

drop trigger if exists trg_bot_tenants_updated on public.bot_tenants;
create trigger trg_bot_tenants_updated
  before update on public.bot_tenants
  for each row execute function public.bot_set_updated_at();

drop trigger if exists trg_bot_chat_ownership_updated on public.bot_chat_ownership;
create trigger trg_bot_chat_ownership_updated
  before update on public.bot_chat_ownership
  for each row execute function public.bot_set_updated_at();

drop trigger if exists trg_bot_config_updated on public.bot_config;
create trigger trg_bot_config_updated
  before update on public.bot_config
  for each row execute function public.bot_set_updated_at();

-- Безопасность: включаем RLS без политик. Анонимный ключ теряет доступ,
-- бот ходит с service_role ключом, который RLS обходит.
alter table public.bot_chat_contexts  enable row level security;
alter table public.bot_tenants        enable row level security;
alter table public.bot_chat_ownership enable row level security;
alter table public.bot_config         enable row level security;
```

3. Если у вас уже была старая таблица `bot_state` (один JSON-блоб) — **не
   удаляйте её**: при первом старте бот сам импортирует из неё данные в новые
   таблицы (однократная миграция). Только закройте её RLS-ом:

```sql
alter table if exists public.bot_state enable row level security;
```

4. Возьмите ключи: **Project Settings → API**:
   - `Project URL` → это `SUPABASE_URL`;
   - `service_role` ключ (secret!) → это `SUPABASE_SERVICE_KEY`.
   Анонимный ключ боту больше не нужен (оставлен как fallback, но с RLS он
   перестанет работать — обязательно задайте service key).

> ⚠️ Free-проект Supabase ставится на паузу после ~7 дней без запросов.
> У живого бота запросы идут постоянно, но если бот остановлен надолго —
> зайдите в дашборд и нажмите Restore, либо перейдите на Pro.

---

## Шаг 2. Переменные окружения на Railway

Сервис → **Variables**. Обязательные:

| Переменная | Значение |
|---|---|
| `TG_BOT_TOKEN` | токен бота от @BotFather |
| `ROUTER_API_KEY` | ключ OpenRouter |
| `DEEPSEEK_API_KEY` | ключ DeepSeek |
| `COMPANY_CHAT_ID` | ID «корпоративного» чата (или `0`, если не нужен) |
| `SUPABASE_URL` | URL проекта Supabase |
| `SUPABASE_SERVICE_KEY` | service_role ключ Supabase |
| `TELEGRAM_WEBHOOK_SECRET` | случайная строка, сгенерируйте: `openssl rand -hex 32` |
| `OWNER_USER_ID` | ваш числовой Telegram userID (узнать: напишите боту и посмотрите `/chatid` в личке). См. ниже — без него владельца опознают по @нику |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `30` — сколько Railway ждёт после SIGTERM, прежде чем убить процесс (нужно для финального сброса состояния) |

Опциональные:

| Переменная | Значение |
|---|---|
| `UPDATE_MODE` | `auto` (по умолчанию) / `webhook` / `polling` |
| `WEBHOOK_PUBLIC_URL` | нужен только вне Railway (на Railway домен подхватывается сам из `RAILWAY_PUBLIC_DOMAIN`) |
| `METRICS_TOKEN` | токен для `GET /metrics`. Если не задан, используется `TELEGRAM_WEBHOOK_SECRET` — эндпоинт закрыт в любом случае |
| `MAX_CONCURRENT_GENERATIONS` | лимит одновременных LLM-стримов, по умолчанию `64` |
| `LOG_LEVEL` | `info` (по умолчанию) / `warning` / `error` |
| `TONAPI_KEY`, `ETHERSCAN_API_KEY`, `TRONGRID_API_KEY` | ключи крипто-обозревателей, если используете крипто-платежи. Один ключ etherscan.io покрывает и ETH, и BSC (Etherscan API V2). `BSCSCAN_API_KEY` — legacy-фолбэк, не нужен. Подробно — PAYMENTS_SETUP.md |

`TELEGRAM_WEBHOOK_SECRET` технически опционален (бот сгенерирует случайный на
старте), но статический лучше: при перекрывающихся деплоях оба инстанса
принимают один и тот же секрет без окна 401-ошибок.

**`OWNER_USER_ID` — задайте его.** Без него владелец бота опознаётся только по
@нику из конфигурации, а ник в Telegram арендуемый: если владелец его освободит,
следующий, кто этот ник займёт, получит права root при первом же сообщении боту.
userID передать нельзя, поэтому с ним root закреплён за аккаунтом навсегда — и
не зависит ни от ника, ни от того, что успело записаться в базу.

**`/metrics` закрыт токеном.** Эндпоинт живёт на том же публичном домене, что и
вебхук, и отдаёт воронку, выручку и счётчики подписчиков. Запрос:

```
curl -H "Authorization: Bearer $METRICS_TOKEN" https://<домен>/metrics
```

`/health` и `/ready` остаются открытыми — на `/ready` смотрит healthcheck Railway.

---

## Шаг 3. Railway

1. Подключите GitHub-репозиторий к сервису (Deploy from GitHub repo).
   `railway.toml` в корне уже настраивает: сборку по Dockerfile, healthcheck
   на `/ready` (таймаут 300с — с запасом на восстановление состояния),
   рестарт при падении.
2. **Settings → Networking → Generate Domain** — обязательно: этот публичный
   домен нужен вебхуку. Порт — тот, что Railway подставит в `PORT` (бот
   слушает его автоматически).
3. Задеплойте. В логах должно появиться:

```
[INFO] HTTP server started on port 8080 (/health, /ready, /metrics, webhook)
[INFO] state restored (chats: N, tenants: M)   ← или "migrated legacy snapshot"
[INFO] webhook registered: https://<домен>/telegram/webhook
[INFO] Bot started as @ваш_бот
```

4. Проверка вебхука со своей машины:

```bash
curl "https://api.telegram.org/bot<TG_BOT_TOKEN>/getWebhookInfo"
# url должен указывать на ваш домен, pending_update_count → 0
curl https://<домен>/health    # OK
curl https://<домен>/ready     # ready
curl https://<домен>/metrics   # JSON со счётчиками
```

### Как проходит редеплой без потерь

1. Railway поднимает новый инстанс; `/ready` отдаёт 503, пока тот
   восстанавливает состояние из Supabase — трафик ещё идёт в старый.
2. Старому приходит SIGTERM → он перестаёт принимать вебхуки (503), Telegram
   откладывает недоставленные updates у себя (до 24ч), инстанс дожидается
   активных генераций (до 8с) и сбрасывает всё в Supabase.
3. Новый инстанс становится ready, регистрирует вебхук, Telegram доставляет
   отложенное. Дедупликация по `update_id` и по `telegram_payment_charge_id`
   гасит возможные повторы.

---

## Шаг 4. Мониторинг (опционально, бесплатно)

- **UptimeRobot** ([uptimerobot.com](https://uptimerobot.com), Free): HTTP(s)
  монитор на `https://<домен>/health`, интервал 5 минут — алерты на почту/TG,
  если бот упал.
- **`/metrics`** — JSON: аптайм, активные генерации, глубина очередей, счётчик
  429 от Telegram, статистика записи в Supabase (`persistence`), количество
  несброшенных изменений (`dirtyEntities`). Полезно смотреть под нагрузкой.
- Логи — во вкладке Railway → Deployments → View Logs (все логи структурные,
  одна строка = одно событие с ISO-временем).
- Чаты с включённым в меню «уведомлением о бэкапах» теперь раз в 60с получают
  статус синхронизации хранилища.

---

## Локальная разработка

Публичного домена нет → бот сам переходит в long polling:

```bash
export TG_BOT_TOKEN=...       # лучше отдельный тестовый бот
export ROUTER_API_KEY=...
export DEEPSEEK_API_KEY=...
export COMPANY_CHAT_ID=0
# SUPABASE_* можно не задавать — состояние будет только в памяти
swift run
```

Если задать `SUPABASE_URL`/`SUPABASE_SERVICE_KEY` локально, offset для polling
хранится в `bot_config` — рестарты не приводят к повторной обработке.
**Не запускайте локальную копию с тем же токеном одновременно с продом**:
polling-копия снесёт вебхук прода (`deleteWebhook` при старте).

---

## Пути апгрейда при росте

| Порог | Что сделать |
|---|---|
| Ответы бота стали задерживаться в группах | Это лимит Telegram (20 msg/min на группу), не бота. Не лечится масштабированием |
| `/metrics` → `active_generations` упирается в лимит | Поднять `MAX_CONCURRENT_GENERATIONS` и/или память сервиса в Railway (vertical scale — один клик) |
| Supabase Free (500 МБ) заканчивается | Supabase Pro ($25/мес, 8 ГБ) — тот же URL/ключи, без миграции |
| Тысячи чатов, нужен второй инстанс | Понадобится вынести rate limiter и дедупликацию в Redis (Upstash Free) и шардировать чаты между инстансами по `chat_id`. Текущая построчная схема БД к этому уже готова |

## Troubleshooting

| Симптом | Причина / решение |
|---|---|
| В логах `state restore failed … PGRST205 / relation does not exist` | Не выполнен SQL из шага 1. Бот работает, но только в памяти (запись отключена, чтобы не портить данные). Выполните SQL и передеплойте |
| `using SUPABASE_ANON_KEY — create SUPABASE_SERVICE_KEY` | Задайте `SUPABASE_SERVICE_KEY`; с включённым RLS анонимный ключ не сможет писать |
| `setWebhook failed, falling back to polling` | Нет публичного домена (Generate Domain в Railway) или невалиден `WEBHOOK_PUBLIC_URL` |
| Вебхук отвечает 401 в `getWebhookInfo` (`last_error_message`) | Секрет в Telegram не совпадает с текущим — задайте статический `TELEGRAM_WEBHOOK_SECRET` и передеплойте |
| Бот молчит после долгого простоя | Free-проект Supabase на паузе — Restore в дашборде Supabase |
| `telegram_429` в `/metrics` растёт | Лимитер сглаживает пики, единичные 429 нормальны; лавинообразный рост — признак, что кто-то шлёт массовые рассылки через бота |
