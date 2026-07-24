# LLM Telegram Bot — архитектура и возможности

Telegram-бот на Swift (server-side, без Vapor), отвечающий пользователям через LLM
с потоковой генерацией. Мультитенантный SaaS: одна кодовая база обслуживает
множество «виртуальных копий» бота (тенантов), у каждого своя память чатов,
настройки, пресеты, статистика и биллинг. Состояние переживает рестарты
(write-behind в Supabase/Postgres), выдерживает сотни параллельных чатов и
работает под лимитами Telegram API.

> Этот файл — источник правды по архитектуре. При изменении кода держи его в
> актуальном состоянии.

---

## 1. TL;DR — что умеет бот

- **LLM-чат** с памятью на каждый чат (история, роль/system prompt, модель,
  температура, длина истории, reasoning, провайдер).
- **Стриминг ответов**: в личке — нативные анимированные draft'ы (Bot API 9.3+),
  в группах — редактирование сообщения по мере генерации. Кнопка «⏹ Остановить».
- **Мультимодальность**: текст, фото (в т.ч. альбомы), голос, видео — если
  провайдер поддерживает.
- **Мультитенантность и роли**: суперадмины, админы (владельцы лицензий),
  обычные пользователи. Каждый тенант — изолированная копия настроек.
- **Монетизация**: подписки (30 дней) через Telegram Stars / карту / крипту;
  pay-as-you-go балансы с наценкой; реклама во free-tier чатах.
- **Удержание**: напоминание спонсору перед концом подписки и winback-офферы
  со срочной скидкой после истечения (расписание настраивается суперадмином).
- **Управление**: слэш-команды + богатое inline-меню (`/menu`).
- **Надёжность**: webhook с очередью Telegram, дедупликация updates,
  идемпотентность платежей, graceful shutdown, rate limiting, health-эндпоинты.

---

## 2. Стек и сборка

- **Язык**: Swift 6.2, strict concurrency (акторы + `Sendable`). Executable target.
- **Зависимости** (`Package.swift`): `async-http-client`, `swift-nio`
  (`NIOPosix`, `NIOHTTP1`, `NIOFoundationCompat`). **Никакого Vapor** —
  HTTP-сервер и клиент собраны напрямую на NIO/AsyncHTTPClient.
- **Платформа**: `.macOS(.v13)`; в проде — Linux в Docker (`swift:6.2-bookworm`).
- **Сборка**: `swift build -c release --product LLM_chat_bot`.
- **Деплой**: Docker → Railway (см. `DEPLOY.md`), состояние в Supabase.

---

## 3. Архитектура: слои (Ports & Adapters / гексагональная)

Каталог `Sources/LLM_chat_bot/` разбит на 4 слоя. Зависимости направлены внутрь:
Infrastructure → Application → Domain. Application общается с внешним миром только
через **порты** (протоколы), реализуемые адаптерами в Infrastructure.

```
App/            — точка входа, конфиг из env, сборка графа зависимостей
Application/    — оркестрация, юз-кейсы, порты, runtime-механика
Domain/         — чистые модели состояния и бизнес-правила (акторы/структуры)
Infrastructure/ — адаптеры: Telegram, LLM-провайдеры, Supabase, HTTP, крипто-эксплореры
```

### App/
- `LLM_chat_bot.swift` — `@main`. Собирает **весь граф зависимостей** вручную
  (composition root), запускает HTTP-сервер, восстанавливает состояние,
  ставит обработчики SIGTERM/SIGINT, запускает оркестратор. Константы: владелец
  по умолчанию `maythe4th`, дефолтный system prompt, `formatOptions`.
- `AppConfig.swift` — загрузка и валидация переменных окружения (см. §15).

### Application/
- `BotOrchestrator.swift` — центральный координатор. `dispatch(update:)` — вход
  для всех апдейтов; маршрутизация в callback / pre-checkout / message; boot
  (restore + миграция), run-loop (webhook/polling), graceful shutdown,
  обработка платежей, `/metrics`-отчёт.
- `ChatUpdateDispatcher.swift` — актор, **сериализует сообщения per-chat**
  (в рамках одного чата обработка строго по очереди, разные чаты — параллельно).
  Очередь на чат ограничена (16); переполнение → дроп с одним предупреждением.
- `Telegram/MessageRouting.swift` — `MessageRoutingPolicy`: решает, реагировать ли
  на сообщение (личка — всегда; группа — только reply боту или @-упоминание),
  и нормализует текст (убирает @упоминание).
- `Telegram/TelegramPhotoAlbumBuffer.swift` — склейка `media_group` (альбомов) в
  один синтетический апдейт.
- `Generation/GenerationCoordinator.swift` — весь пайплайн генерации ответа:
  проверка доступа к модели, выбор режима биллинга, snapshot истории, запуск
  стрима (draft или edit), сборка футера, показ рекламы. См. §9.
- `Generation/DraftStreamer.swift` — «печатающая машинка» через `sendMessageDraft`.
- `Commands/` — `CommandParser.swift` (парсинг `/cmd@bot`+suffix) и
  `BotCommandHandler.swift` (~1900 строк, реализация всех команд). См. §12.
- `Callbacks/` — `BotCallbackAction.swift` (типы callback_data: `stop`, `menu`,
  `faq`) и `BotCallbackHandler.swift` (роутинг нажатий кнопок).
- `Menu/BotMenuHandler.swift` — inline-меню (~3700 строк): страницы, рендеринг,
  обработка ввода текста после нажатия кнопок. См. §13.
- `Formatting/ResponseFooterFormatter.swift` — футер под ответом (токены, стоимость
  ×markup, модель, остаток баланса).
- `Payments/` — `CryptoPaymentService.swift` (инвойсы, курсы, матчинг),
  `CryptoPaymentMonitor.swift` (поллинг блокчейнов).
- `Lifecycle/SubscriptionReminderService.swift` — фоновый свип подписок:
  напоминание перед истечением + winback-офферы со скидкой. См. §7/§14.
- `Persistence/PersistenceCoordinator.swift` — write-behind: дренаж грязных
  сущностей и запись раз в 2с; `flushNow()` для платежей; ретрай слиянием. См. §10.
- `Providers/ProviderGatewayRegistry.swift` — реестр `ServiceProvider → адаптер`.
- `Runtime/` — механика масштабирования (см. §11): `UpdateIntake` (дедуп + альбомы),
  `GenerationLimiter` (глобальный семафор), `TelegramRateLimiter` (token-bucket),
  `RuntimeMetrics` (счётчики), `Concurrency.swift` (`LockedValue`, `RuntimeFlags`).
- `SessionRegistry.swift` — актор активных генераций (для остановки и graceful shutdown).
- `ModelPriceMonitor.swift` — фоновый мониторинг цен/бесплатности моделей OpenRouter.
- `UserFacingError.swift` — перевод ошибок в понятные пользователю сообщения.
- `Ports/` — протоколы: `TelegramGatewayPort`, `ProviderGatewayPort`,
  `StatePersistencePort`, `MediaResolverPort`, `LoggerPort` + модели портов.

### Domain/
- `Chat/ChatContextStore.swift` — **сердце системы** (~1950 строк), актор,
  хранит всё состояние в памяти и правила бизнес-логики. См. §5.
- `Chat/ChatContextStore+Persistence.swift` — экспорт/импорт строк (dirty-дренаж,
  restore), изоляция кода персистентности от основного актора.
- `Chat/BotStateSnapshot.swift` — `CumulativeUsage`, снапшот-DTO (`*Snapshot`),
  legacy-блоб для одноразовой миграции.
- `Chat/ChatMessageTypes.swift` — `ChatMessage`/`ChatMessageContent` (text | parts),
  мультимодальные части (image/audio/video), сборка user-сообщения.
- `Chat/ChatSessionTypes.swift` — `ChatKey` (chatID+threadID), `GenerationID`.
- `Chat/PresetTypes.swift` — `Preset`, `PresetCategory`, `PendingInput`,
  `AdminPendingInput(Kind)` (типы «ждём текстовый ввод от юзера»).
- `Chat/ChatMetaInfo.swift` — человекочитаемая идентичность чата + `InviteRecord`.
- `Chat/UserBalance.swift` — кошелёк pay-as-you-go.
- `Chat/AdCampaign.swift` — рекламная кампания (частота + пейсинг).
- `Chat/SubscriptionLifecycle.swift` — `SubscriptionReminderConfig` (расписание
  напоминаний/winback + чистое решение «что слать» — `dueNotice`),
  `SubscriptionNotice`, `SubscriptionDiscount`, `SubscriptionPricing`,
  `SubscriptionLifecycleStats`.
- `Chat/MediaTypes.swift`, `UserInputContent.swift` — медиа-рефы и вход юзера.
- `Providers/ProviderTypes.swift` — `ServiceProvider`, `ProviderCapabilities`,
  `StreamUsageSummary`/`StreamMeta`, `ProviderStreamEvent`, `GenerationOptions`,
  `ReasoningEffort`.
- `Payments/CryptoPayment.swift` — сети/активы/инвойсы крипты + форматтер сумм.
- `Payments/CardPayment.swift` — конфиг карточного эквайринга.

### Infrastructure/
- `Telegram/TelegramHTTPGateway.swift` — реализация `TelegramGatewayPort`: все
  вызовы Bot API (sendMessage/editMessage/sendMessageDraft/sendInvoice/
  answerPreCheckoutQuery/getFile/download/…), маппинг API-DTO → доменных моделей,
  ретрай 429, применение rate limiter'а.
- `Telegram/TelegramApiModels.swift` — сырые DTO Bot API.
- `Telegram/TelegramHTMLFormatter.swift` — санитизация/конвертация в Telegram HTML.
- `Telegram/TelegramMediaResolver.swift` — скачивание медиа → base64/data-URL.
- `Providers/OpenRouterProviderAdapter.swift`, `DeepSeekProviderAdapter.swift` +
  их `*APIModels.swift` — адаптеры LLM (SSE-стриминг). См. §8.
- `Persistence/SupabaseStatePersistence.swift` — REST-клиент Supabase (PostgREST),
  построчная схема + чтение legacy-блоба. См. §10.
- `Networking/NetworkClient.swift` — обёртка AsyncHTTPClient: `send`, `ssePayloads`
  (парсер SSE), лимиты на размер тела.
- `Networking/AppHTTPServer.swift` — минимальный NIO HTTP-сервер (`/health`,
  `/ready`, `/metrics`, webhook).
- `Payments/CryptoExplorers.swift` — `TonExplorer`, `EvmExplorer` (ETH/BSC,
  Etherscan V2 multichain по chainID), `TronExplorer`.
- `Logging/ConsoleLogger.swift` — `LoggerPort`, уровень из `LOG_LEVEL`.

> Файл `Infrastructure/Networking/HealthCheckServer.swift` **удалён** — заменён
> на `AppHTTPServer.swift`.

---

## 4. Жизненный цикл апдейта

```
Telegram
  │  (webhook POST /telegram-webhook  ИЛИ  long polling getUpdates)
  ▼
AppHTTPServer / runPollingLoop
  │  проверка secret-заголовка, 503 пока не ready / при draining
  ▼
UpdateIntake.enqueue([updates])
  │  дедуп по update_id (кольцевой буфер 2048) + склейка альбомов (holdback 300мс)
  ▼
BotOrchestrator.dispatch(update:)
  ├─ callback_query      → BotCallbackHandler (в обход per-chat очереди: stop должен прерывать)
  ├─ pre_checkout_query  → handlePreCheckoutQuery (цена: полная или winback-скидочная
  │                        → answerPreCheckoutQuery)
  ├─ my_chat_member      → handleMyChatMemberUpdate (бота добавили в группу →
  │                        разовое приветствие с оффером; вирусный рост)
  └─ message             → ChatUpdateDispatcher.submit(chatKey) { route(message) }
                              │  (сериализация per-chat, очередь ≤16)
                              ▼
                          BotOrchestrator.route(message:)
                            1. recordChatMeta (title/@username для админ-тулинга)
                            2. successful_payment? → handleSuccessfulPayment (идемпотентно)
                            3. /buy или /start? → пропустить до access-gate
                            4. autoAssignIfNeeded (привязать чат к тенанту отправителя)
                            5. BotCommandHandler.handleIfCommand → true? стоп
                            6. BotMenuHandler.processTextInput → true? стоп (ждали ввод)
                            7. GenerationCoordinator.handleIfNeeded → LLM-ответ
```

Ключевое: **callback'и минуют per-chat очередь** — иначе кнопка «Стоп» не смогла
бы отменить генерацию, которая эту очередь и держит.

---

## 5. Доменное состояние: `ChatContextStore`

Актор — единственный владелец всего изменяемого состояния. Всё наружу отдаётся
через `async`-методы; внешний код никогда не трогает поля напрямую.

**Что хранит:**
- `contexts: [ChatKey: ChatContext]` — память каждого чата (по chatID+threadID).
- `tenants: [String: TenantState]` — тенанты (ключ = lowercased username).
- `chatOwnership: [Int: String]` — какой чат какому тенанту принадлежит.
- `userTenantMap: [Int: String]` — userID → тенант (для автопривязки).
- Глобальные конфиги: суперадмины, цена Stars, крипто-конфиг, карта, free-модели,
  processed payments, polling offset, метаданные чатов, инвайты, реклама, markup%,
  балансы пользователей, счётчики воронки (`funnelCounters`), дневной премиум-лимит
  (`dailyPremiumLimitValue`, §7/§9), расписание напоминаний/winback
  (`reminderConfigValue`, §7/§14).
- **In-memory без персиста** (сброс при рестарте некритичен): `_premiumDailyUsage`
  — дневной счётчик «премиум-вкуса» free-tier (см. §9).
- **Dirty-tracking**: `dirtyContexts`, `dirtyTenants`, `deletedTenants`,
  `dirtyOwnership`, `deletedOwnership`, `dirtyConfigs` (+ `deleted*`). Любая
  мутация помечает грязным — это то, что дренирует `PersistenceCoordinator`.

**`ChatContext`** (память одного чата): `role`, `history: [ChatMessage]`,
`pendingTurns`, `model` (+`modelProviderRouting`), `temp`, `maxHistory`,
`showStats`/`showCost`/`showModel`, `provider`, `suffix` (test-mode),
`reasoningEffort`, `backupNotify`, `cumulativeUsage`, per-chat пресеты, счётчики
рекламы, `funnelFirstMessageCounted` (флаг воронки: первое сообщение чата
засчитано).

**`pendingTurns`** — важный механизм: пока идёт генерация, user-сообщение висит в
`pending`; при завершении (`completed`/`cancelled`) `flushResolvedTurns`
дописывает пары user+assistant в `history` **по порядку**. Это позволяет
параллельно копить несколько запросов и не портить порядок истории.
`visibleHistory` = обрезанная (`trimHistory`, system-сообщение всегда первым)
история + pending user-сообщения.

**`TenantState`**: `ownerUsername`, дефолты (модель/роль/длина истории), 4 набора
глобальных (тенант-скоуп) пресетов, `whitelistedUserIDs`, `adminUsernames`,
`licensedUsernames`, `cumulativeUsage`, `createdAt`, **`paidUntil`** (nil =
бессрочно). `isActive = paidUntil == nil || paidUntil > now`.
Жизненный цикл подписки (§7 «Напоминания»): `noticeCycleUntil` + `sentNotices`
(какие письма уже ушли в текущем сроке — продление меняет `paidUntil` и обнуляет
набор), `winbackDiscount` (одноразовая скидка), `remindersOptOut` (спонсор
отписался сам).

**Роутинг тенанта**: `tenantState(for: chatID)` = тенант из `chatOwnership` или
дефолтный владелец. Мутации дефолтов/пресетов идут через `mutateTenant(for:)`.

---

## 6. Мультитенантность и роли

Три роли (см. также `.claude/CLAUDE.md`-историю продуктовой спеки ниже):

- **Суперадмины** (root по умолчанию `@maythe4th`) — владельцы бота. Могут всё:
  цена подписки, методы оплаты, дефолтные пресеты, free-модели, наценка, реклама,
  балансы, статистика по всем тенантам. `rootSuperAdmin` (@maythe4th) —
  единственный, кто добавляет/удаляет других суперадминов.
- **Админы** (владельцы лицензий) — оплатившие пользователи. Получают свою
  виртуальную копию бота: свои дефолты, глобальные пресеты, могут выдавать доступ
  к платным моделям своим чатам/пользователям. Не могут «суперадминские» вещи.
  Суперадмин обладает всеми возможностями админа.
- **Обычные пользователи** — доступ только к бесплатным моделям, если владелец
  лицензии не открыл платный доступ для их чата/лички. Могут заводить per-chat
  пресеты для быстрого переключения параметров.

**Лицензирование доступа к платным моделям** (`hasSubscriptionCoverage`):
1. пользователь сам активный тенант; либо
2. он в `licensedUsernames` активного тенанта; либо
3. чат привязан (`chatOwnership`) к активному тенанту → доступ всем участникам; либо
4. userID в `whitelistedUserIDs` активного тенанта этого чата.

**Автопривязка** (`autoAssignIfNeeded`): непривязанный чат автоматически
закрепляется за тенантом отправителя (по username или userID). Так админ,
добавивший бота в группу, сразу открывает ей платные модели.

**Инвайты**: `InviteRecord` (токен → owner). Диплинк `/start <token>` даёт
посетителю доступ под лицензией админа (пока подписка активна). Один активный
токен на владельца (`regenerateInviteToken` инвалидирует старый).

**Симуляция ролей** (`/simulate`): суперадмин может «прикинуться» админом или
обычным юзером для тестирования (реклама, биллинг). `isSuperAdmin` возвращает
false во время симуляции; `isActuallySuperAdmin` игнорирует симуляцию (для самой
команды `/simulate`).

---

## 7. Монетизация

**Подписки** (30 дней, `subscriptionDays`): активация продлевает от
`max(now, paidUntil)` — оплата никогда не сокращает срок. `activatePaidSubscription`
создаёт тенанта при первой оплате. Истёкший тенант сохраняет админ-панель (чтобы
продлить), но его чаты/юзеры откатываются на бесплатные модели.

**Способы оплаты** (всё настраивается из бота, см. `PAYMENTS_SETUP.md`):
- **💫 Telegram Stars** — работает сразу. Цена (`starsPrice`) в супер-меню.
  Поток: `/buy` → `sendInvoice` (XTR) → `pre_checkout_query` (валидация цены) →
  `successful_payment`.
- **💳 Карта** — Telegram Payments через провайдера (YooKassa/Stripe/…).
  `CardPaymentConfig` (токен из BotFather, валюта RUB/USD/EUR, цена в minor units)
  хранится в состоянии бота, не в env. Токен маскируется при показе.
- **🪙 Крипта** — TON / BSC / ETH / TRON, нативный TON + USDT (TON/BSC/ERC20/TRC20).
  Два режима матчинга (`CryptoMatchMode`): `amountDelta` (один адрес на сеть,
  инвойсы различаются уникальной дельтой суммы через slot-оффсеты) и
  `uniqueAddress` (пул предвыделенных адресов, по одному на инвойс).
  `CryptoPaymentService` создаёт инвойсы, тянет курс (TON через CoinGecko),
  считает атомарные суммы; `CryptoPaymentMonitor` поллит блокчейн-эксплореры,
  матчит входящие переводы, засчитывает частичные платежи, при полной оплате
  активирует подписку. **API-ключи эксплореров — единственные крипто-настройки
  в env** (`TONAPI_KEY`, `ETHERSCAN_API_KEY`/`BSCSCAN_API_KEY`, `TRONGRID_API_KEY`).

Идемпотентность: `successful_payment` дедуплицируется по
`telegram_payment_charge_id` (`processedPaymentChargeIDs`), крипта — по хешам
транзакций (`creditedTxHashes`). Платежи всегда `flushNow()` — durability без ожидания debounce.

**Pay-as-you-go балансы** (`UserBalance`, `userBalances`): альтернатива подписке.
Пользователь с положительным балансом платит за каждое сообщение по marked-up
цене. `spentRealUsd` (реальная стоимость провайдера) хранится рядом с
`spentBilledUsd` → суперадмин видит маржу. `hasFullModelAccess` = подписка ИЛИ
положительный баланс.

**Кредиты / самостоятельное пополнение** (`CreditPack`, низкий порог первой
оплаты): любой юзер покупает пакет ($2/$5/$10) через Stars или крипту прямо на
странице покупки. Инвойс с payload `credits_<центы>`; `handleSuccessfulPayment`
по этому префиксу зачисляет номинал на баланс (`creditBalance`), а не активирует
подписку. `pre_checkout_query` пропускает credit-payload. Идемпотентность — по
charge_id, как у подписок.

**Наценка** (`markupPercentValue`, дефолт 30%): `priceMultiplier() = 1 + %/100`.
**Все** видимые пользователю цены и списания идут через этот множитель
(`billedCost`, футер, `chargeBalance`). Настраивается суперадмином (0–500%).

**Спонсор-герой**: в группе, покрытой чужой подпиской, под ответами показывается
строка `⚡ премиум для чата открыл @{sponsor}` (`chatSponsor` → `sponsorCreditLine`;
только группы, не сам спонсор), а при оплате, открывшей чат, в чат летит публичное
поздравление. Снимает проблему «безбилетника».

**Дневной премиум-вкус** free-tier: см. §9 (гейт генерации) — `consumeDailyPremium`.
Дневной лимит настраивается суперадмином (`setDailyPremiumLimit`, кнопка
«🎁 Премиум-лимит/день» в супер-меню; 0 = премиум-вкус выключен).

**Напоминания и winback** (`SubscriptionReminderService`, §14): фоновый свип
сравнивает `paidUntil` с now и шлёт спонсору **одно** сообщение на срок подписки:
за N дней до конца — напоминание продлить, после истечения — winback-волны
(`winbackDays`, дефолт +1 и +7 дней) с **срочной скидкой** (`SubscriptionDiscount`,
дефолт −30% на 48 ч). Всё расписание — `SubscriptionReminderConfig` в `bot_config`
(`GlobalConfigKey.reminders`): вкл/выкл, дни до конца, дни winback, процент и срок
скидки, интервал свипа, уведомлять ли чаты спонсора. Правится в супер-меню
(«⏳ Напоминания и winback») и командой `/reminders`, без передеплоя.

- **Дедуп**: `noticeCycleUntil` + `sentNotices` на тенанте; отметка ставится только
  после успешной доставки (иначе ретрай на следующем свипе, ограниченный окном
  волны). Продление меняет `paidUntil` → набор отметок сбрасывается.
- **Скидка** применяется ко всем способам оплаты через **единый источник цен**
  `subscriptionPricing(username:)` (Stars / крипта / карта; карта не опускается ниже
  минимума валюты). `pre_checkout_query` принимает и полную, и скидочную цену
  (grace 1 ч — инвойс, открытый на границе срока). Покупка «съедает» скидку
  (`consumeWinbackDiscount`) и считает `funnel(.winbackRedeemed)`.
- **Каналы**: личка спонсора (если он писал боту) и — опционально (`notifyChats`) —
  его группы (продлить может любой участник; не более 10 чатов на волну, публично
  только первая winback-волна). Нет ни одного канала → отметка ставится, счётчик
  «недоступны» растёт (видно суперадмину).
- **Контроль у спонсора**: кнопка «🔔 Напоминания о продлении» в его админ-панели
  (`remindersOptOut`) + строка с датой ближайшего напоминания и активной скидкой.

**Реклама** (`AdCampaign`): показывается только во free-tier чатах (нет подписки
и нет баланса). Два дросселя: частота (раз в N ответов + мин. интервал) и пейсинг
(равномерное распределение показов по времени кампании). `nextAdToShow` атомарно
решает, считает показ и ротирует кампании (least-shown first). Когда нет активной
кампании суперадмина, слот заполняет встроенный **само-оффер** (`AdCampaign.selfPromo`,
синтетический, не персистится, тот же дроссель) — реклама продаёт сам премиум.
Страница «📣 Реклама» в супер-меню явно показывает, что при отсутствии кампаний слот
занимает само-оффер (прозрачность, §шаг5).

---

## 8. LLM-провайдеры

Абстракция через `ProviderGatewayPort`: `capabilities`, `makeRequest(plan)`,
`stream(request) -> AsyncThrowingStream<ProviderStreamEvent>`,
`fallbackModel(for:)`. Реестр `ProviderGatewayRegistry` мапит `ServiceProvider`
на адаптер.

- **OpenRouter** (`.openrouter`, а также `.yandex` мапится на него) — основной.
  Поддерживает **image/audio/video/reasoning**. Reasoning через
  `OpenRouterReasoning(effort, enabled)`. **Provider routing**: `providerRouting`
  пинит апстрим-провайдера (`order`/`only`, `allow_fallbacks:false`) — для
  моделей, где нужен конкретный бэкенд. Стоимость берётся из usage (`cost` или
  `cost_details.upstream_inference_cost`). Endpoint SSE:
  `openrouter.ai/api/v1/chat/completions`.
- **DeepSeek** (`.deepseek`) — только текст, без reasoning. Модель фиксирована
  `deepseek-chat`. Endpoint `api.deepseek.com/v1/chat/completions`. Стоимость не
  отдаёт (cache hit/miss токены отдаёт).

Оба адаптера парсят SSE через `NetworkClient.ssePayloads`, эмитят
`.text(chunk)` и в конце `.meta(StreamMeta)` (модель + usage), корректно
обрабатывают отмену (`producer.cancel()` на termination) и `[DONE]`.

Дефолтные модели-пресеты (сеются в `main`): Gemini 3 Flash, Gemini Flash latest,
Gemini 3.1 Flash Lite, DeepSeek V4 Pro/Flash, Grok 4.3. Дефолтная модель:
`google/gemini-3-flash-preview`.

`ProviderCapabilities` проверяются **до** генерации: если чат прислал медиа,
которое провайдер не поддерживает, пользователю показывается подсказка сменить
провайдера/отправить только текст.

---

## 9. Генерация и стриминг

`GenerationCoordinator.processContent`:
1. **Воронка + free-model gate с дневным премиум-вкусом**: сначала
   `markFirstMessageIfNeeded` (первое сообщение чата → аналитика, §7). Затем: если у
   отправителя нет полного доступа и текущая модель платная — `consumeDailyPremium`
   (группа: общий счётчик на чат; личка: на `userID`; сброс по UTC-суткам; лимит
   `dailyPremiumLimitValue`, дефолт 5, настраивается суперадмином в супер-меню
   «🎁 Премиум-лимит/день», персист в `bot_config`; сам счётчик расхода —
   **in-memory**). Остаток есть → платная модель отвечает
   (бесплатный «вкус премиума»); исчерпан → переключение на первую бесплатную +
   оффер с кнопками покупки/баланса (`sendDailyLimitOffer`) + `funnel(.capHit)`.
   Free-модели безлимитны; спонсируемые чаты сюда не доходят (`hasFullModelAccess`).
2. **Режим биллинга**: `covered` (подписка/лицензия) → бесплатно для отправителя;
   иначе `billedTo` (положительный баланс) → списание per-message; иначе free-tier
   → `adEligible`.
3. Регистрирует `GenerationID` в `SessionRegistry`, запускает **typing**-индикатор.
4. `generationLimiter.acquire()` — глобальный кап одновременных стримов.
5. Оборачивает текст: `"Тебе пишет @username: <text>"`. Вложения не пишутся в
   историю (только текст) — экономия хранилища; в запрос идут с медиа.
6. `snapshotAndAppend` — атомарный снапшот истории + добавление pending turn.
7. `stream` через шлюз; режим:
   - **draft** (`runDraftStreaming`, только личка, Bot API 9.3+): анимированный
     `sendMessageDraft`; финальный текст/оверфлоу/ошибки **всегда** persist'ятся
     через `sendMessage` (draft эфемерен). Контрол-сообщение «💭 Думаю…» несёт
     только кнопку Стоп и удаляется после записи ответа.
   - **edit** (`runEditStreaming`, группы / серверы без draft): placeholder
     редактируется по мере генерации (тротлинг: раз в 3с или +300 символов).
8. **Разбивка длинных ответов** (`MessageSplitter.charLimit`): при переполнении —
   «↑ продолжение» / «↓ продолжение ниже», новое сообщение.
9. **Футер** (`makeFooter` → `ResponseFooterFormatter`): токены, стоимость ×markup,
   модель, прогнозируемый остаток баланса (для billed-юзеров).
10. Итог: `appendAssistant` (запись в историю + учёт usage + списание баланса) →
    при `adEligible` показ рекламы; либо `cancelPendingTurn` при пустом/отменённом.

**Отмена**: кнопка Стоп → callback → `SessionRegistry.cancel` → отмена task →
пометка `cancelled` → «⏹ Остановлено».

**Слот генерации** освобождается ровно один раз через `finishGeneration`
(release limiter + finish session), какой бы путь ни был.

---

## 10. Персистентность (write-behind, построчная схема)

**Модель**: состояние живёт в памяти (`ChatContextStore`); изменения помечаются
грязными; `PersistenceCoordinator` (актор) каждые **2с** дренирует
`drainDirtyBatch()` и апсертит **только изменившиеся** строки. Flush = O(changed),
не O(all chats).

- `flushNow()` — немедленно (платежи).
- Провал flush → батч кладётся в `retryCarry` и **сливается** (`PersistenceBatch.merged`,
  newer wins) со следующим — транзиентные сбои Supabase не теряют данные.
- `flushOnce` сериализован флагом `flushing` (реентрантность актора через await).
- `stop()` (в SIGTERM-окне): отменяет цикл, финальный flush + один ретрай.

**Схема Supabase (PostgREST)** — `SupabaseStatePersistence`:
```
bot_chat_contexts(chat_id, thread_id, data jsonb)   PK (chat_id, thread_id)
bot_tenants(username PK, data jsonb)
bot_chat_ownership(chat_id PK, owner_username)
bot_config(key PK, data jsonb)                       -- синглтоны (GlobalConfigKey)
bot_state(id PK, data jsonb)                         -- legacy-блоб, read-only для миграции
```
`GlobalConfigKey`: stars_price, stars_per_usd, free_models, crypto, card,
super_admins, processed_payments, polling_offset, chat_meta, invites, ads,
markup, balances, **funnel** (счётчики воронки, §7/§11), **daily_premium_limit**
(суперадмин-настройка дневного премиум-вкуса, §9), **reminders**
(расписание напоминаний/winback, §7/§14).
Значения конфигов оборачиваются в `{"value": …}`.

**Boot** (`BotOrchestrator.bootstrapState`): `loadEverything()`; если строковые
таблицы пусты и есть legacy-блоб — одноразовая миграция (`restoreFromSnapshot`
→ `markAllDirty` → `flushNow`); иначе `restore(from:)`. **При ошибке загрузки —
memory-only режим, запись отключена**, чтобы не затереть хорошие данные.

**Важно при добавлении новых мутаций стора**: любая новая изменяемая сущность
должна помечать соответствующий dirty-set, иначе она не сохранится.
Экспорт/импорт строк — в `ChatContextStore+Persistence.swift`.

Апсерты чанкуются; при `SUPABASE_ANON_KEY` (вместо `SUPABASE_SERVICE_KEY`) —
предупреждение (нужен service key + RLS).

---

## 11. Надёжность и масштабирование

- **Интейк** (`UpdateIntake`): единая точка для webhook и polling. Дедуп по
  `update_id` (кольцевой буфер), склейка альбомов с holdback-таймером (сам тикает
  флаш — при webhook больше некому).
- **Per-chat сериализация** (`ChatUpdateDispatcher`): порядок в чате гарантирован,
  чаты параллельны, очередь ограничена (16) → защита от флуда.
- **Глобальный кап стримов** (`GenerationLimiter`): FIFO-семафор
  (`MAX_CONCURRENT_GENERATIONS`, дефолт 64). Лишние ждут (typing уже идёт),
  не выедая сокеты/память.
- **Rate limiter Telegram** (`TelegramRateLimiter`): token-bucket. Глобально
  ~18 msg/s (реальные сообщения) + отдельные бюджеты для draft'ов (8/s,
  droppable) и косметики/typing (3/s) → суммарно <30/s. Per-chat: личка ~1/s,
  группа 20/min. Авто-retry по `retry_after` (429). Прунинг «прогретых» бакетов.
- **Дедупликация платежей**: charge_id (Stars/карта), tx-хеши (крипта).
- **Graceful shutdown** (SIGTERM/SIGINT): `draining=true`, webhook отдаёт 503 →
  Telegram передержит и передоставит апдейты; ждём завершения стримов (до 8с);
  отменяем фоновые таски; финальный flush состояния. **Редеплой без потерь.**
- **Health-эндпоинты** (`AppHTTPServer`): `/health` (liveness), `/ready` (503 пока
  restore не завершён и при draining — Railway healthcheck), `/metrics` (JSON:
  uptime, активные генерации, глубина очередей, dirty-сущности, статус
  персистентности, счётчики, `funnel`).
- **Метрики** (`RuntimeMetrics`/`MetricName`): updates received/deduplicated/dropped,
  generations, telegram_429, send errors, persistence flushes/errors, payments
  processed/deduplicated, reminder sweeps/sent/winbacks/send errors. Легко мапится
  на Prometheus.
- **Воронка-аналитика** (`FunnelEvent`/`funnelCounters`, персистится в `bot_config`):
  события start → addedToGroup (вирусный рост, §шаг4) → firstMessage → capHit →
  openPurchase → invoiceSent → paid/renewed + creditTopup, плюс удержание:
  expiryReminder → winbackSent → winbackRedeemed (§7). Отдаётся в `/metrics`
  (`funnel`: счётчики + живой подсчёт спонсоров
  active/expired/unlimited/expiring_soon и активных winback-скидок) и на странице
  супер-меню «📊 Воронка» (`renderSuperFunnel`)
  с пошаговой конверсией. Счётчики — событийные (не уникальные юзеры), переживают
  рестарт. Ретеншн D1/D7 требует когортных таймстемпов — отложен.
- **Режим апдейтов** (`UpdateMode`): `auto` (webhook если есть публичный URL —
  Railway; иначе polling), `webhook`, `polling`. Webhook защищён secret-заголовком.

---

## 12. Команды (`BotCommandName` / `BotCommandHandler`)

Парсинг: `/cmd`, `/cmd@botusername`, суффикс тест-режима (`/model3` при
`suffix=3`). До access-gate разрешены только `/start` и `/buy`.

**Пользовательские / настройки чата**: `/setrole`, `/clear_history`, `/settemp`,
`/model`, `/historylength`, `/show_model`, `/show_cost`, `/show_tokens`,
`/provider`, `/testmode`, `/reasoning`, `/help`, `/menu`, `/reset`, `/history`,
`/reset_stats`, `/backup_notify`, `/chatid`, `/start`, `/buy`, `/balance`.

**Админские / тенант**: `/default_role`, `/defaults`, `/whitelist`, `/chats`,
`/users`, `/presets`, `/tenant` (assign/release/adduser/register/remove/freemodels/
crypto/…), `/inspect`, `/ads`, `/invite` (через меню).

**Суперадминские**: `/superadmin` (add/remove), `/simulate`, `/reminders`
(on/off/days/winback/discount/hours/interval/chats/run/test/clear — §7/§14),
глобальные free-модели, цены, наценка, балансы (в основном через супер-меню).

Неизвестная команда/упоминание → `.mention`/`.unknown` (игнор или обычная генерация).

---

## 13. Inline-меню (`BotMenuHandler`)

Страницы (`MenuPage`, callback_data `menu:<action>`): главная (`help`), страница
покупки (`pay` — подписка + пакеты кредитов), admin-панель (`admin`, `adminhelp`,
`adminchats`, `adminusers`, `adminwl`, `admindef`, `admininvite`), супер-панель
(`superadmin`, `superadminhelp`, `superstars`, `supercrypto`, `supercard`,
`superfreemodels`, `supertenants`, `superadmins`, `supersim`, `superchats`,
`superads`, `superbal`, `superfunnel` — воронка-аналитика, `superreminders` —
напоминания/winback: расписание, ручная проверка, предпросмотр, список подписок
под наблюдением).

- `sendMenu` / `showPage` / `renderPage` — рендер клавиатур под роль/контекст.
- **Pending-input flow**: кнопка вроде «✏️ Изменить цену» кладёт «ожидание ввода»
  (`AdminPendingInput`/`PendingInput`/специализированные `_pending*Inputs` в сторе)
  с ID меню-сообщения; следующий текст юзера ловит `processTextInput` (шаг 6
  роутинга), применяет и обновляет меню. Так реализованы все «введите значение»
  сценарии (цена, адреса, пресеты, наценка, топ-ап баланса, симуляция и т.д.).
- Всё управление ценами/оплатой/рекламой/наценкой — из меню, без передеплоя.

---

## 14. Фоновые процессы (запускаются в `run`)

- **`ModelPriceMonitor`** (каждые 5 мин + initial): тянет `openrouter.ai/api/v1/models`,
  кэширует цены (`openRouterModelPrices`) и множество бесплатных моделей
  (`openRouterFreeModelIDs`). Если модель, используемая в системе, стала платной —
  уведомляет затронутые чаты (или суперадмина, если модель «закреплена» в free).
- **`CryptoPaymentMonitor`**: поллит эксплореры, матчит входящие переводы к
  открытым инвойсам, засчитывает частичные оплаты, экспайрит просроченные.
- **`runPersistenceNotifyLoop`** (каждые 60с): чатам с `backupNotify=true` шлёт
  строку статуса хранилища (замена старого 60-секундного бэкап-отчёта).
- **`SubscriptionReminderService.run`** (первый проход через 60с после старта,
  дальше — каждые `sweepIntervalMinutes`, дефолт 60): свип подписок → напоминания
  перед истечением и winback-офферы со скидкой (§7). Свип сериализован (флаг
  `sweeping`), поэтому кнопка «🔄 Проверить сейчас» / `/reminders run` не пересекается
  с циклом. Результат последнего свипа (`SweepResult`) — на странице супер-меню.
  Работает и в memory-only режиме: подписка не должна тихо истечь.

Бесплатные модели: эффективное множество = закреплённые суперадмином
(`_freeModelIDs`) ∪ бесплатные с OpenRouter. Если множество пустое (не настроено)
— `isFreeModel` возвращает true для всех (fail-open).

---

## 15. Переменные окружения (`AppConfig` / `EnvironmentKey`)

**Обязательные**: `TG_BOT_TOKEN`, `DEEPSEEK_API_KEY`, `ROUTER_API_KEY`
(OpenRouter), `COMPANY_CHAT_ID` (Int).

**Опциональные**:
- Хранилище: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` (предпочтительно) или
  `SUPABASE_ANON_KEY` (fallback). Без них — memory-only.
- Сеть/режим: `PORT` (дефолт 8000), `UPDATE_MODE` (auto/webhook/polling),
  `WEBHOOK_PUBLIC_URL` или `RAILWAY_PUBLIC_DOMAIN`, `TELEGRAM_WEBHOOK_SECRET`.
- Крипто-эксплореры: `TONAPI_KEY`, `ETHERSCAN_API_KEY` (V2 multichain: покрывает
  ETH и BSC), `BSCSCAN_API_KEY` (legacy fallback для BSC), `TRONGRID_API_KEY`.
- Прочее: `LOG_LEVEL`, `MAX_CONCURRENT_GENERATIONS` (дефолт 64).

Цены/токены оплаты (Stars, карта, крипто-адреса, наценка) в env **не хранятся** —
настраиваются из супер-меню и лежат в `bot_config`.

---

## 16. Деплой

- **Dockerfile**: multi-stage (`swift:6.2-bookworm` build → `-slim` runtime),
  бинарь `/usr/local/bin/app`.
- **Railway** (`railway.toml`): builder Dockerfile, healthcheck `/ready`
  (timeout 300с), restart ON_FAILURE. `/ready`=503 до окончания restore → новый
  деплой берёт трафик (а старый отдаёт) только когда реально готов → zero-loss
  редеплой в связке с очередью webhook.
- **Supabase**: SQL из `DEPLOY.md` (создание таблиц). Подробности оплаты —
  `PAYMENTS_SETUP.md`.

---

## 17. Конвенции и подводные камни

- **Всё состояние — через актор `ChatContextStore`**. Новая изменяемая сущность
  обязана: (а) помечать dirty-set при мутации, (б) экспортироваться/импортироваться
  в `ChatContextStore+Persistence.swift`, (в) при необходимости получить
  `GlobalConfigKey`/DTO.
- **Цены пользователю — всегда через `priceMultiplier()`** (`billedCost`,
  футер, списания). Не показывай сырой `totalCost`.
- **Цена подписки — всегда через `subscriptionPricing(username:)`** (меню, `/buy`,
  крипто-инвойс, `pre_checkout_query`). Прямое чтение `starsPrice()`/`cardConfig()`
  для выставления счёта разъедет показанную и списанную цену, когда у юзера есть
  winback-скидка.
- **Платежи — `flushNow()`**, не полагайся на 2-секундный debounce.
- **Идемпотентность**: любой платёжный путь дедуплицируется (charge_id / tx-хеш) —
  Telegram и блокчейн-поллинг доставляют события повторно.
- **Роли**: `isSuperAdmin` учитывает симуляцию, `isActuallySuperAdmin` — нет.
  Для гейтов, которые должны работать при симуляции, используй второй.
- **Callback'и вне per-chat очереди** — не ломай это (Стоп должен прерывать).
- **Draft — только личка**; в группах и на старых Bot API — edit-стриминг.
  Draft эфемерен → финальный текст обязательно `sendMessage`, не только draft.
- **Telegram-вывод — HTML** (`TelegramHTMLFormatter`), не Markdown. В system prompt
  боту сказано не тегать участников (`@` перед именами).
- **`ChatKey` = chatID + threadID** (топики форумов — отдельные контексты;
  threadID=0 = основной).
- Русский — основной язык пользовательских сообщений и документации.

---

## 18. Продуктовая спецификация (исходное ТЗ)

Ниже — исходная бизнес-логика, на которой строился бот (для контекста намерений).

### Базовое
Telegram-чат-бот на Swift-сервере в Docker. Принимает апдейты, отвечает через LLM
по API. Память на каждый чат (история, настройки модели, reasoning, длина истории).
Параметры меняются командами или через UI-меню. Состояние бэкапится в Supabase.

### Тенант-система
Free-план даёт только бесплатные модели. Платные — за подписку (Stars/крипта/карта).
- **Суперадмины** (`@maythe4th`) — реальные владельцы, могут всё.
- **Обычные пользователи** — только free-модели, если владелец лицензии не открыл
  платный доступ их чату/личке. Могут заводить per-chat пресеты.
- **Админы** (владельцы лицензий) — оплатившие; своя виртуальная копия бота,
  управляют доступом своих чатов/юзеров к платным моделям, редактируют глобальные
  и per-chat пресеты. Не могут суперадминских вещей (цена, дефолтные on-start
  пресеты). Суперадмин ⊇ админ. Только `@maythe4th` добавляет/снимает суперадминов.
- Админ может в чате открыть свою панель и одной кнопкой добавить/убрать чат из
  своей лицензии.

### Лицензирование
Оплатившие становятся **админами** (не суперадминами). Добавление бота в группу
авто-привязывает чат к лицензии → доступ к платным моделям. Либо ручная привязка
по chatID (группа) / `@username` (личка). Админ управляет списком своих чатов.
Суперадмины видят всех админов и их чаты + статистику (токены, стоимость в $).

### Прайсинг
Подписка на платные модели. Суперадмин задаёт цену и методы оплаты.
