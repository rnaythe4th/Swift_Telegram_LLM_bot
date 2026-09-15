# LLM Telegram Bot

_[Русская версия ниже](#русская-версия)_

A multi-tenant LLM chat bot for Telegram, written in **Swift 6.2 server-side** with
the HTTP server, the Telegram client and the SSE streaming client built on SwiftNIO.

One binary serves many independent "virtual copies" (tenants), each with its own owner, defaults,
presets, licences and money. State survives restarts: everything is write-behind into Postgres,
money is write-through inside transactions.

|          |                                                                                         |
| -------- | --------------------------------------------------------------------------------------- |
| Language | Swift 6.2, strict concurrency, zero warnings enforced in CI                             |
| Tests    | 587 XCTest cases, run against a real Postgres in CI and in the Docker build             |
| Runtime  | Linux container (`swift:6.2-bookworm`), deployed on Railway with a health-gated rollout |

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/chat.jpg" alt="Answer with a cost and model footer" width="260"></td>
<td width="50%" align="center"><img src="docs/screenshots/voice.jpg" alt="A voice note answered by the model" width="260"></td>
</tr>
</table>

---

## Stack

- **Swift 6.2**, executable SwiftPM target, strict concurrency checking.
- **SwiftNIO** — the HTTP server.
- **AsyncHTTPClient** — outbound calls; a hand-written SSE framer for token streaming.
- **PostgresNIO** — Postgres driver.
- **swift-crypto** — AES-GCM encryption of payment secrets at rest, signature checks for checkout
  callbacks.
- **Telegram Bot API** — webhook or long polling, HTML output, inline menus, streaming drafts.
- **LLM providers** — OpenRouter (text/image/audio/video, reasoning effort, provider routing) and
  DeepSeek, both behind one port and one shared OpenAI-compatible stream decoder.
- **Docker**

---

## Features

### Input

| Input            | Handling                                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Text**         | Chat turn with per-chat history.                                                                                                             |
| **Voice notes**  | Sent to the model as an `input_audio` part; transcription and answer in one call.                                                            |
| **Photos**       | Sent as an `image_url` data URL; the caption is the question.                                                                                |
| **Photo albums** | `media_group` parts stitched into one turn: up to 16 parts, 750 ms hold-back.                                                                |
| **Video**        | Sent as an `input_video` part when the model supports it.                                                                                    |
| **Replies**      | Trigger in groups; the answer is anchored to the asking message. In listening mode the reply target enters the prompt as `(in reply to #N)`. |
| **Forum topics** | Separate history, settings and transcript per topic.                                                                                         |

Attachments are resolved before the generation slot is taken, under a 20 MiB per-turn budget.
Unsupported media is rejected against the model's capabilities before the request.

### Chatting

- Streaming: ephemeral drafts in private chats, throttled edits in groups. Watchdog at 75 s without
  an event, 600 s overall. **Stop** button cancels mid-answer.
- Memory: 1…50 messages and 200 KB per chat, trimmed newest-first. `/forget` clears the chat history.
- Groups: answers a reply or an @-mention. Private chats: everything.
- Output is HTML, split on a UTF-16 budget; never cuts inside a tag or entity, reopens tags across
  parts.
- Footer per answer: tokens, cost with markup, model, balance, truncation marker on
  `finish_reason=length`. Each part toggleable per chat.

### Menu and settings

- Modes: one tap sets model, style, memory, reasoning effort and optionally a role. Tiers 🆓 and ⭐;
  a ⭐ mode without access opens the purchase page.
- Roles and presets: custom system prompt, presets per chat and per tenant.
- Fine tuning: style, memory length, reasoning effort, provider pin.
- Prompt examples: onboarding buttons that run as real requests.
- Commands mirror the menu (`/model`, `/setrole`, `/settemp`, `/historylength`, `/reasoning`,
  `/provider`, `/forget`) under the same access gates.

### Group listening mode

- A transcript of the room, separate from the dialogue history: the addressed message goes in as the
  question, the transcript as context.
- Opt-in, announced in the chat when switched on or off.
- Seeded from an in-memory pre-buffer: up to 100 messages, 12 hours, never persisted.
- Limits: 10…300 messages, 400 characters per line, 60 KB per chat. Readable and erasable from the
  menu.
- With Telegram privacy mode on, the bot receives only messages addressed to it; the page and the
  status line state this.

### Money, access and administration

- Multi-tenant: an owner buys a subscription and sponsors their chats, guests and users. Access
  resolves to one status — own subscription / sponsored / guest / balance / free.
- Four payment rails: Telegram Stars, Telegram card payments, crypto (TON, ETH, BSC, TRON — native
  coins and USDT), hosted checkout. One post-payment path, one idempotency key per rail.
- Balances in integer nano-dollars, credit packs, configurable markup on every visible price, daily
  free quota of premium models.
- Spend caps: daily, global and per tenant. On reaching one, paid models are off until midnight and
  the owner is alerted.
- Configured in-bot, not in environment variables: prices, payment credentials, free models, modes,
  ads, reminders, limits.
- Growth and retention: onboarding examples, referrals with anti-fraud, `?start=src_…` attribution,
  ad campaigns, expiry reminders, winback discounts, funnel with daily buckets, owner alerts.

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/menu.jpg" alt="The chat menu" width="260"></td>
<td width="50%" align="center"><img src="docs/screenshots/superadmin.jpg" alt="The super-admin menu" width="260"></td>
</tr>
<tr>
<td align="center"><sub>The chat menu: modes, role, fine tuning, listening.</sub></td>
<td align="center"><sub>The super-admin menu: payment rails, tenants, limits, funnel.</sub></td>
</tr>
</table>

### Operations

Webhook or long polling behind one intake (dedup, album stitching), per-chat serial queues with
parallel chats, a FIFO concurrency limiter, a token-bucket rate limiter for the Bot API, a single
writer held by a Postgres advisory lock, `/health`, `/ready`, a token-protected `/metrics`
(Prometheus), graceful drain on SIGTERM.

---

## Build and run

```bash
swift build -c release --product LLM_chat_bot
swift test
```

The database tests skip themselves without `TEST_DATABASE_URL`, so run them against a real server:

```bash
docker run -d --rm --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=botdb \
  -p 55432:5432 postgres:16-alpine

TEST_DATABASE_URL='postgres://postgres:test@127.0.0.1:55432/botdb?sslmode=disable' swift test
```

Deployment is the `Dockerfile` (tests run inside the build) plus `railway.toml`; `/ready` returns 503
until state is restored and the writer lock is held, and again while draining, which makes redeploys
lossless.

### Environment

| Variable                                                |                                                                                                        |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `TG_BOT_TOKEN`, `ROUTER_API_KEY`, `DEEPSEEK_API_KEY`    | required                                                                                               |
| `DATABASE_URL`                                          | Postgres in **session** pool mode (port 5432); without it the bot runs memory-only and refuses to sell |
| `STATE_ENCRYPTION_KEY`                                  | 32 bytes base64; encrypts payment secrets at rest                                                      |
| `TELEGRAM_WEBHOOK_SECRET`, `METRICS_TOKEN`              | webhook authentication, `/metrics` bearer token                                                        |
| `UPDATE_MODE`, `WEBHOOK_PUBLIC_URL`, `PORT`             | transport: `auto` / `webhook` / `polling`                                                              |
| `MAX_CONCURRENT_GENERATIONS`, `LOG_LEVEL`, `LOG_FORMAT` | limits and logging (`json` for structured output)                                                      |

Prices, payment credentials and feature configuration are **not** environment variables — they live
in the database and are edited from the in-bot super-admin menu.

---

# Русская версия

Мультитенантный LLM-чат-бот для Telegram на **Swift 6.2** (server-side).

Один бинарник обслуживает много независимых «виртуальных копий» (тенантов) — у каждой свой владелец,
дефолты, заготовки, лицензии и деньги. Состояние переживает рестарты: всё пишется в Postgres.

|         |                                                                             |
| ------- | --------------------------------------------------------------------------- |
| Язык    | Swift 6.2, strict concurrency                                               |
| Тесты   | 587 XCTest-кейсов, в CI и в Docker-сборке прогоняются на настоящем Postgres |
| Рантайм | Linux-контейнер (`swift:6.2-bookworm`), деплой на Railway.                  |

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/chat.jpg" alt="Ответ с футером" width="260"></td>
<td width="50%" align="center"><img src="docs/screenshots/voice.jpg" alt="Голосовое сообщение" width="260"></td>
</tr>
</table>

---

## Стек

- **Swift 6.2**.
- **SwiftNIO** — HTTP-сервер.
- **AsyncHTTPClient** — исходящие запросы; собственный парсер SSE для стриминга.
- **PostgresNIO** — Postgres.
- **swift-crypto** — AES-GCM для платёжных секретов в базе, проверка подписей уведомлений кассы.
- **Telegram Bot API** — webhook или long polling, HTML, inline-меню, draft-стриминг.
- **LLM-провайдеры** — OpenRouter (текст/картинки/аудио/видео, обдумывание, provider routing) и
  DeepSeek, оба за одним портом и общим OpenAI-совместимым декодером потока.
- **Docker**

---

## Возможности

### Входящие

| Вход              | Обработка                                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Текст**         | Обычный текст в промпте пользователя.                                                                                                  |
| **Голосовые**     | Уходят в модель как `input_audio`: ответ от модели приходит сразу.                                                                     |
| **Фото**          | Уходят как data-URL `image_url`; может идти вместе с текстом.                                                                          |
| **Альбомы**       | Несколько фото в одном сообщении -> парсится как альбом, до 16 частей.                                                                 |
| **Видео**         | Уходит как `input_video`, если модель поддерживает.                                                                                    |
| **Реплаи**        | Триггер для ответа бота в группе, ответ привязан к спросившему сообщению. В прослушке цель реплая едет в промпт как `(в ответ на #N)`. |
| **Топики форума** | Своя история, настройки и стенограмма на каждый топик.                                                                                 |

Неподдерживаемое медиа отсекается по capabilities модели до запроса.

### Диалог

- Стриминг: живые черновики в личке, постепенные правки в группе, кнопка **Стоп** прерывает ответ.
- Память: 1…50 сообщений и 200 КБ на чат, считается от новейших. `/forget` стирает переписку чата.
- Группа: бот отвечает на реплай на любое его сообщение и @-упоминание. Личка: на всё.
- Вывод — HTML, сообщения длиннее лимита телеграм разбивает на несколько частей и отправляет друг за другом.
- Футер под ответом: токены, стоимость с наценкой, модель, остаток баланса.

### Меню и настройки

- Режимы: один тап ставит модель, стиль, память, обдумывание и опционально роль.
- Роли и заготовки: свой system prompt, заготовки на чат и на тенанта.
- Тонкая настройка: стиль, длина памяти, обдумывание.
- Примеры-запросы: кнопки онбординга, выполняются как настоящий запрос.
- Команды дублируют меню (`/model`, `/setrole`, `/settemp`, `/historylength`, `/reasoning`,
  `/provider`, `/forget`)

### Прослушка беседы

- Полная история чата (стенограмма), отдельная от истории диалога с ИИ: адресованное сообщение уходит вопросом,
  стенограмма — контекстом.
- Включается явно, включение и выключение объявляется в чате.
- История собирается всегда, но для использования прослушки ее нужно явно включить. Не персистится.
- Границы: 10…300 сообщений, 400 символов на строку, 60 КБ на чат. Читается и стирается из меню.

### Деньги, доступ и администрирование

- Мультитенантность: владелец покупает подписку и дает доступ своим чатам и пользователям.
- Оплата через стороннюю кассу или Telegram Stars
- Суточная бесплатная порция сообщений к платным моделям.
- Лимиты расходов: суточные, глобальный и на тенанта. При достижении платные модели выключаются до
  полуночи, владельцу уходит алерт.
- Настраивается в боте, а не в переменных окружения: цены, платёжные секреты, бесплатные модели,
  режимы, реклама, напоминания, лимиты.
- Рост и удержание: примеры-запросы, реферал с антифродом, атрибуция `?start=src_…`, рекламные
  кампании, напоминания об истечении, winback-скидки, воронка с подневными бакетами, алерты
  владельцу.

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/menu.jpg" alt="Меню чата" width="260"></td>
<td width="50%" align="center"><img src="docs/screenshots/superadmin.jpg" alt="Супер-меню" width="260"></td>
</tr>
<tr>
<td align="center"><sub>Меню чата: режимы, роль, тонкая настройка, прослушка.</sub></td>
<td align="center"><sub>Супер-меню: платёжные рельсы, тенанты, лимиты, воронка.</sub></td>
</tr>
</table>

---

## Сборка и запуск

```bash
swift build -c release --product LLM_chat_bot
swift test
```

Тесты базы пропускают себя без `TEST_DATABASE_URL`, поэтому запускать их надо с настоящим сервером:

```bash
docker run -d --rm --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=botdb \
  -p 55432:5432 postgres:16-alpine

TEST_DATABASE_URL='postgres://postgres:test@127.0.0.1:55432/botdb?sslmode=disable' swift test
```

Деплой — `Dockerfile`

### Переменные окружения

| Переменная                                              |                                                                                               |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `TG_BOT_TOKEN`, `ROUTER_API_KEY`, `DEEPSEEK_API_KEY`    | обязательные                                                                                  |
| `DATABASE_URL`                                          | Postgres в **session**-режиме пула (порт 5432); без неё бот работает memory-only и не продаёт |
| `STATE_ENCRYPTION_KEY`                                  | 32 байта base64; шифрует платёжные секреты в базе                                             |
| `TELEGRAM_WEBHOOK_SECRET`, `METRICS_TOKEN`              | аутентификация вебхука, bearer-токен `/metrics`                                               |
| `UPDATE_MODE`, `WEBHOOK_PUBLIC_URL`, `PORT`             | транспорт: `auto` / `webhook` / `polling`                                                     |
| `MAX_CONCURRENT_GENERATIONS`, `LOG_LEVEL`, `LOG_FORMAT` | лимиты и логи (`json` — структурный вывод)                                                    |

Цены, платёжные секреты и настройки фич — не переменные окружения: они лежат в базе и правятся из
супер-меню бота.
