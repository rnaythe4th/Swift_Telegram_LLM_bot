# LLM Telegram Bot

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
- История собирается всегда, но для использования прослушки ее нужно явно включить.
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

---

# English version

A multi-tenant LLM chat bot for Telegram, built on **Swift 6.2** (server-side).

One binary serves many independent "virtual copies" (tenants) — each with its own owner, defaults,
presets, licences and money. State survives restarts: everything is written to Postgres.

|          |                                                                             |
| -------- | --------------------------------------------------------------------------- |
| Language | Swift 6.2, strict concurrency                                               |
| Tests    | 587 XCTest cases, run against a real Postgres in CI and in the Docker build |
| Runtime  | Linux container (`swift:6.2-bookworm`), deployed on Railway.                |

<table>
<tr>
<td width="50%" align="center"><img src="docs/screenshots/chat.jpg" alt="An answer with a footer" width="260"></td>
<td width="50%" align="center"><img src="docs/screenshots/voice.jpg" alt="A voice message" width="260"></td>
</tr>
</table>

---

## Stack

- **Swift 6.2**.
- **SwiftNIO** — the HTTP server.
- **AsyncHTTPClient** — outbound requests; an own SSE parser for streaming.
- **PostgresNIO** — Postgres.
- **swift-crypto** — AES-GCM for payment secrets in the database, signature checks for checkout
  callbacks.
- **Telegram Bot API** — webhook or long polling, HTML, inline menus, draft streaming.
- **LLM providers** — OpenRouter (text/images/audio/video, reasoning effort, provider routing) and
  DeepSeek, both behind one port and one shared OpenAI-compatible stream decoder.
- **Docker**

---

## Features

### Input

| Input            | Handling                                                                                                                                                           |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Text**         | Plain text in the user prompt.                                                                                                                                     |
| **Voice notes**  | Sent to the model as `input_audio`: the answer comes straight back from the model.                                                                                 |
| **Photos**       | Sent as an `image_url` data URL; can come together with text.                                                                                                      |
| **Albums**       | Several photos in one message -> parsed as an album, up to 16 parts.                                                                                               |
| **Video**        | Sent as `input_video` when the model supports it.                                                                                                                  |
| **Replies**      | A trigger for the bot to answer in a group, the answer anchored to the asking message. In listening mode the reply target enters the prompt as `(in reply to #N)`. |
| **Forum topics** | Separate history, settings and transcript per topic.                                                                                                               |

Unsupported media is rejected against the model's capabilities before the request.

### Chatting

- Streaming: live drafts in private chats, incremental edits in groups, a **Stop** button cancels the
  answer.
- Memory: 1…50 messages and 200 KB per chat, counted from the newest. `/forget` erases the chat's
  history.
- Groups: the bot answers a reply to any of its messages and an @-mention. Private chats: everything.
- Output is HTML; messages longer than the Telegram limit are split into several parts and sent one
  after another.
- Footer under the answer: tokens, cost with markup, model, remaining balance.

### Menu and settings

- Modes: one tap sets the model, style, memory, reasoning effort and optionally a role.
- Roles and presets: a custom system prompt, presets per chat and per tenant.
- Fine tuning: style, memory length, reasoning effort.
- Prompt examples: onboarding buttons, executed as a real request.
- Commands mirror the menu (`/model`, `/setrole`, `/settemp`, `/historylength`, `/reasoning`,
  `/provider`, `/forget`)

### Group listening mode

- The full chat history (a transcript), separate from the history of the dialogue with the AI: the
  addressed message goes in as the question, the transcript as context.
- Switched on explicitly; switching on and off is announced in the chat.
- The history is always collected, but to use listening it has to be switched on explicitly.
- Limits: 10…300 messages, 400 characters per line, 60 KB per chat. Readable and erasable from the
  menu.

### Money, access and administration

- Multi-tenancy: an owner buys a subscription and grants access to their chats and users.
- Payment through a third-party checkout or Telegram Stars
- A daily free quota of messages to paid models.
- Spend caps: daily, global and per tenant. On reaching one, paid models are switched off until
  midnight and the owner gets an alert.
- Configured in the bot, not in environment variables: prices, payment secrets, free models, modes,
  ads, reminders, limits.
- Growth and retention: prompt examples, referrals with anti-fraud, `?start=src_…` attribution, ad
  campaigns, expiry reminders, winback discounts, a funnel with daily buckets, owner alerts.

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

---

## Build and run

```bash
swift build -c release --product LLM_chat_bot
swift test
```

The database tests skip themselves without `TEST_DATABASE_URL`, so they have to be run with a real
server:

```bash
docker run -d --rm --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=botdb \
  -p 55432:5432 postgres:16-alpine

TEST_DATABASE_URL='postgres://postgres:test@127.0.0.1:55432/botdb?sslmode=disable' swift test
```

Deployment — `Dockerfile`

### Environment

| Variable                                                |                                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `TG_BOT_TOKEN`, `ROUTER_API_KEY`, `DEEPSEEK_API_KEY`    | required                                                                                             |
| `DATABASE_URL`                                          | Postgres in **session** pool mode (port 5432); without it the bot runs memory-only and does not sell |
| `STATE_ENCRYPTION_KEY`                                  | 32 bytes base64; encrypts payment secrets in the database                                            |
| `TELEGRAM_WEBHOOK_SECRET`, `METRICS_TOKEN`              | webhook authentication, `/metrics` bearer token                                                      |
| `UPDATE_MODE`, `WEBHOOK_PUBLIC_URL`, `PORT`             | transport: `auto` / `webhook` / `polling`                                                            |
| `MAX_CONCURRENT_GENERATIONS`, `LOG_LEVEL`, `LOG_FORMAT` | limits and logging (`json` — structured output)                                                      |

Prices, payment secrets and feature configuration are not environment variables: they live in the
database and are edited from the bot's super-admin menu.
