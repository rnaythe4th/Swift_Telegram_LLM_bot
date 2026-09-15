# LLM Telegram Bot — архитектура

Telegram-бот на Swift (server-side, без Vapor): LLM-чат с памятью, потоковой
генерацией и мультитенантным биллингом. Одна кодовая база = много «виртуальных
копий» (тенантов) со своими настройками, лицензиями и деньгами. Состояние
переживает рестарты (write-behind в Postgres; деньги — в транзакциях).

> Источник правды по архитектуре. Меняешь код — держи файл в актуальном виде.

---

## 1. Стек, сборка, деплой

- Swift 6.2, strict concurrency (акторы + `Sendable`), executable target.
- Зависимости: `async-http-client`, `swift-nio` (NIOPosix/NIOHTTP1/
  NIOFoundationCompat), `swift-crypto` (MD5/HMAC подписей кассы), `postgres-nio`.
  **Vapor нет** — HTTP-сервер и клиент собраны на NIO напрямую.
- Платформа `.macOS(.v13)`; прод — Linux в Docker (`swift:6.2-bookworm`).
- Сборка: `swift build -c release --product LLM_chat_bot`. Тесты: `swift test`
  (`Tests/LLM_chat_botTests/`, см. §14).
- Деплой: Docker → Railway (`DEPLOY.md`), healthcheck `/ready` (503 до конца
  restore и при draining) → редеплой без потери апдейтов.
- Схему БД бот мигрирует сам на старте.

---

## 2. Слои (Ports & Adapters)

Зависимости внутрь: Infrastructure → Application → Domain. Application ходит
наружу только через порты (`Application/Ports/`).

### App/
- `LLM_chat_bot.swift` — `@main`, только последовательность старта: `AppAssembly.build`
  → HTTP-сервер → restore → SIGTERM/SIGINT → оркестратор.
- `AppAssembly.swift` — composition root (весь граф вручную: `makeTelegram`,
  `makeStore`+сев пресетов, `makePersistence`, `makeOrchestrator`,
  `makeCryptoMonitor`, `resolveMode`, `makeHTTPServer`, `registerSecrets`).
  Константы: владелец по умолчанию `maythe4th`, дефолтный system prompt.
- `AppConfig.swift` — env (§13).

### Application/
- `BotOrchestrator.swift` — координатор (зависимости + init). Тело по темам:
  `+Lifecycle` (boot с миграцией, run-loop webhook/polling, фоновые циклы,
  graceful shutdown, `/metrics`-отчёт), `+Routing` (`dispatch`/`route`,
  `my_chat_member`, тап по примеру), `+Payments` (`pre_checkout_query`,
  `successful_payment`).
- `ChatUpdateDispatcher.swift` — актор, сериализует сообщения **per-chat**
  (очередь 16, переполнение → дроп с одним предупреждением).
- `Telegram/`: `MessageRouting` (`MessageRoutingPolicy` — реагировать ли:
  личка всегда, группа только reply/@-упоминание; нормализация текста),
  `TelegramPhotoAlbumBuffer` (склейка `media_group`), `OnboardingPresenter`,
  `ReferralPresenter`, `GroupWelcomePresenter`, `TranscriptCapture` (сообщение
  Telegram → строка стенограммы, §5.7).
- `Generation/`: `GenerationCoordinator` (весь пайплайн ответа, §7) +
  `+Streaming` (draft/edit-раннеры, разбивка длинных ответов) +
  `+Monetization` (`resolveDailyPremium`, `resolveBillingMode`, реклама, офферы,
  реферальная выплата, футер); `DraftStreamer` (`sendMessageDraft`);
  `StreamWatchdog` (стрим без событий 75 с → обрыв; общий потолок 600 с —
  молчащий провайдер иначе держит слот генерации и ломает shutdown-окно;
  считается **тишина**, а не медленность: keep-alive и нерасшифрованный чанк
  приходят как `ProviderStreamEvent.keepAlive` и продлевают жизнь потоку).
- `Commands/`: `CommandParser` (`/cmd@bot`+суффикс), `BotCommandHandler`
  (обвязка, гейты, `handleIfCommand`) + `+Dispatch` (только switch) +
  `+Listen` (`/listen`, §5.7) +
  `+ChatSettings/Start/Referral/Info/Onboarding/Balance/Reminders/Ads/Admin/
  Tenant/SuperAdmin/Buy`.
- `Callbacks/`: `BotCallbackAction` (`stop`, `menu`, `faq`, `ex:<id>`),
  `BotCallbackHandler`.
- `Menu/` (§11): `MenuRoute` (`MenuCommand` + разбор/сборка `callback_data`),
  `MenuScreen` (текст+клавиатура, инвариант «влезает в одно сообщение»;
  `Keyboard`), `MenuPage` (каталог страниц + `backLabel`, `isPersonal`,
  `access`/`MenuAccess`), `SuperHelpSection`,
  `BotMenuHandler+Guards` (`requireSuperAdmin/requireRootSuperAdmin/
  requireAdmin/requireOperator` — сами отвечают тостом), `BotMenuHandler`
  (диспетчер `processAction`, `showPage`/`renderPage`) + страницы по файлам:
  `MainPage`, `ChatSettings`(+`ChatSettingsPages`), `Modes`, `Purchase`,
  `Presets`, `Admin`, `Tenants`, `SuperAdmin`, `PaymentSettings`, `ExternalPay`,
  `Retention`, `Onboarding`, `Referral`, `Growth`, `Spend`, `Help`, `Listen`,
  `TextInput`, `AdminInput`.
- `Texts.swift` — каталог повторяющихся строк. **Только литералы**: всё, что
  называет человека/чат, собирается на месте через `displayLabel`/`sanitizeName`.
- `Formatting/ResponseFooterFormatter.swift` — футер (токены, стоимость ×markup,
  модель, остаток баланса).
- `Payments/`: `PaymentFulfillmentService` (**единственный** post-payment путь,
  §5), `CryptoPaymentService`, `CryptoPaymentMonitor`, `ExternalPaymentService`,
  `SubscriptionWriter`/`WalletWriter` (единственные пути изменения `paid_until`
  и кошелька вне платежа), `InMemoryLedger` (тот же контракт без durability).
- `Lifecycle/`: `SubscriptionReminderService` (свип подписок: напоминания,
  winback, возврат по балансу; `SendBudget` — потолок рассылки на свип),
  `RetentionService` (суточный прунинг переписок и бакетов воронки),
  `OwnerAlerter` (`OwnerAlert`: databaseDown, volatileMode, notWriter,
  ledgerMismatch, modelCatalogueDown, spendCapReached).
- `Persistence/PersistenceCoordinator.swift` — write-behind (§8.1).
- `Providers/ProviderGatewayRegistry.swift` — `ServiceProvider → адаптер`.
- `Runtime/`: `UpdateIntake` (дедуп + альбомы), `GenerationLimiter` (глобальный
  FIFO-семафор), `TelegramRateLimiter` (token-bucket), `RuntimeMetrics`,
  `StateDurability`, `AnnouncementThrottle` (сказать один раз на интервал —
  общий дроссель фоновых уведомлений), `Concurrency` (`LockedValue`,
  `RuntimeFlags`).
- `SessionRegistry.swift` — активные генерации (стоп, graceful shutdown).
- `ModelPriceMonitor.swift` — цены/бесплатность моделей OpenRouter
  (+`ModelCatalogueReading` — чистое чтение каталога, пустой = авария).
- `UserFacingError.swift` — ошибки → русский текст пользователю.
- `Ports/`: `TelegramGatewayPort`, `ProviderGatewayPort`, `StatePersistencePort`,
  `LedgerPort`, `MediaResolverPort`, `LoggerPort` (+`LogContext`: чат/тема/юзер/
  генерация), `ConfigRegistry` (`ConfigName`, `ConfigKey<Value>`, `Config`,
  `StoredConfig`, `ConfigDocuments`), `ExternalCheckoutPort`.

### Domain/
- `Chat/ChatContextStore.swift` — актор, **единственный владелец состояния**
  (§3). Логика в расширениях `ChatContextStore+*`: `Identity`, `Tenants`,
  `Subscriptions`, `Auth`, `Presets`, `ChatContext`, `Chats`, `PendingInput`,
  `Payments`, `ExternalPayments`, `Models`, `Premium`, `Modes`, `Analytics`,
  `Onboarding`, `Referral`, `Balances`, `Ads`, `Spend`, `Listen`, `Ledger`
  (`applyCommitted*` — обновление кэша после коммита), `Persistence`
  (экспорт/импорт строк).
- `Chat/ChatContextTypes.swift` — `TenantState`, `ChatContext`,
  `GenerationSnapshot`, `HelpData`, `TenantStatsRow`, `SimulatedRole`.
- `Chat/`: `ChatMessageTypes` (`ChatMessage`/`ChatMessageContent`: text|parts),
  `ChatSessionTypes` (`ChatKey` = chatID+threadID, `GenerationID`),
  `Identifiers` (`ChatID`/`UserID`), `UserDirectory` (`UserKey`, `UserIdentity`),
  `UserBalance` (+`ChatAccessStatus`), `ChatMetaInfo` (+`InviteRecord`),
  `PresetTypes` (`Preset` + `id`, `PresetList` — кап 12, `PresetCategory`),
  `PendingRequest` (`PendingKind` + владелец + TTL),
  `ChatTranscript` (`TranscriptEntry`/`TranscriptAuthor`/`TranscriptReply`,
  `ChatListening` — прослушка беседы, §5.7),
  `ModePreset`, `Onboarding`, `Referral`, `TrafficSource`, `AdCampaign`,
  `SubscriptionLifecycle`, `SpendPolicy`, `CreditPack`, `FunnelMetrics`,
  `MediaTypes`, `UserInputContent`, `PersistedSnapshots` (DTO строк/конфигов).
- `Money.swift` — USD в **наноданных долларах** (`Int64`, приватный init,
  только именованные фабрики). Целочисленность нужна для граничных сравнений
  (`> .zero`) и сходимости с журналом; насыщение вместо переполнения, `NaN` → 0.
- `Providers/ProviderTypes.swift` — `ServiceProvider`, `ProviderCapabilities`,
  `StreamUsageSummary` (санирует числа провайдера на границе: не финитное →
  nil, отрицательное → 0, потолок `maxPlausibleTokens`), `StreamMeta`
  (+`StreamFinishReason`), `ProviderStreamEvent` (`text`/`meta`/`keepAlive`),
  `GenerationOptions`, `ReasoningEffort`.
- `Payments/`: `PurchasePurpose` (`subscription | credit(cents:)`),
  `CryptoPayment`, `CardPayment` (`FiatCurrency` + minor units),
  `ExternalPayment` (вендор, способы, конфиг, счета, эндпоинт, ошибки).

### Infrastructure/
- `Telegram/TelegramHTTPGateway.swift` — `TelegramGatewayPort`: все вызовы Bot
  API (sendMessage/editMessage/sendMessageDraft/sendInvoice/
  answerPreCheckoutQuery/getFile/download/…), маппинг DTO, ретрай 429, rate
  limiter, `chunkFittingHTML`.
- `Telegram/TelegramApiModels.swift` — сырые DTO.
- `Telegram/TelegramHTMLFormatter*.swift` — три стадии: `+Tokenizer` (чтение
  тега/сущности), `+Sanitizer` (политика: какие теги/атрибуты выживают),
  головной (`render`, стек тегов, белый список схем `href`, экранирование
  значений атрибутов).
- `Telegram/TelegramMediaResolver.swift` — медиа → base64/data-URL; бюджет
  `turnByteBudget` (20 МиБ на ход) резервируется по `file_size` **до** скачивания
  и досчитывается по факту.
- `Providers/`: `OpenRouterProviderAdapter`, `DeepSeekProviderAdapter` (+
  `*APIModels`), `OpenAIStreamDecoding` (`OpenAICompatibleStreamChunk` +
  `OpenAIStreamAccumulator` — общая машина потока), `ProviderStreamErrorPayload`
  (§6).
- `Persistence/`: `PostgresStatePersistence` (построчная загрузка, батч одной
  транзакцией, миграции), `PostgresLedger` (деньги в транзакциях),
  `WriterLock` (advisory lock единственного писателя), `PostgresSchema`,
  `DatabaseEndpoint` (разбор `DATABASE_URL`).
- `Networking/`: `NetworkClient` (AsyncHTTPClient: `send`, `ssePayloads`,
  лимиты тела), `ServerSentEventParser` (кадрирование SSE: `Event.payload` /
  `Event.keepAlive`, потолок на незавершённые байты), `AppHTTPServer` (NIO:
  `/health`, `/ready`, `/metrics`, webhook, `/payments/<vendor>`; тело ≤1 МиБ,
  `HEAD` без тела, простой 120 с → закрытие), `SecretBox` (шифрование секретов
  в БД, `SealedSecret`), `SecretGuard` (`constantTimeEquals`), `URLForm`.
- `Payments/`: `CryptoExplorers` (`TonExplorer`, `EvmExplorer` — Etherscan V2 по
  chainID, `TronExplorer`), `FreeKassaCheckoutAdapter`,
  `ExternalCheckoutRegistry` (vendor → адаптер исчерпывающим switch),
  `PaymentSignature` (MD5 — схема вендора).
- `Logging/ConsoleLogger.swift` — `LOG_LEVEL`, `LOG_FORMAT=json`, `LogContext`.

---

## 3. Жизненный цикл апдейта

```
Telegram → webhook POST /telegram/webhook | long polling getUpdates
  → AppHTTPServer / runPollingLoop     (secret-заголовок; 503 пока не ready / draining)
  → UpdateIntake.enqueue               (дедуп update_id, кольцевой буфер 2048; альбомы holdback 750мс)
  → BotOrchestrator.dispatch
     ├─ callback `ex:`      → handleOnboardingExample → per-chat очередь (запускает генерацию)
     ├─ callback_query      → BotCallbackHandler  (МИМО очереди: «Стоп» обязан прерывать)
     ├─ pre_checkout_query  → handlePreCheckoutQuery (валидация цены, durability-гейт)
     ├─ my_chat_member      → вход в группу (присутствие, autoAssign, funnel, приветствие)
     │                        / выход (botRemoved) / личка (блок-разблок)
     └─ message             → ChatUpdateDispatcher.submit(chatKey) { route(message) }
            route: 1 identifyUser → 2 migrate_to_chat_id (переезд, стоп)
                   → 3 recordChatMeta → 4 successful_payment → 5 /start|/buy до гейта
                   → 6 autoAssignIfNeeded → 7 BotCommandHandler.handleIfCommand
                   → 8 BotMenuHandler.processTextInput → 9 запись в стенограмму
                     (прослушка, §5.7) → 10 GenerationCoordinator.handleIfNeeded
```

Вход в группу приходит **дважды** (`my_chat_member` + `/start <payload>` от
`?startgroup=`), пути разные и порядок не гарантирован → оба зовут
`claimGroupGreeting(chatID:)` (окно 10 мин, in-memory). `/start` в группе никогда
не шлёт личное приветствие.

Апгрейд группы в супергруппу приходит **один раз**, служебным сообщением в
старом чате (`migrate_to_chat_id`), и меняет `chat_id`, которым ключуется всё
состояние чата → `migrateChat(from:to:)` переносит переписки, владение, мету,
ожидание ввода и in-memory таймеры (старая строка помечается удалённой),
`flushNow()`. Состояние, уже лежащее под новым id, не перезаписывается.

---

## 4. Состояние: `ChatContextStore`

Актор — единственный владелец изменяемого состояния; наружу только `async`-методы.

**Хранит**: `contexts: [ChatKey: ChatContext]`, `tenants: [UserKey-строка:
TenantState]`, `chatOwnership: [ChatID: tenant]`, `userTenantMap`, кошельки,
метаданные чатов, инвайты, крипто-инвойсы, счета кассы, журнал реферала,
атрибуции `src_`, счётчики воронки (общие + подневные), дневной расход премиума,
и глобальные конфиги (§8.3).

**Dirty-tracking**: `dirtyContexts`, `dirtyTenants`, `dirtyOwnership`,
`dirtyConfigs`, `dirtyWallets` + соответствующие `deleted*`. Любая мутация метит
грязным — это дренирует `PersistenceCoordinator`.

**In-memory без персиста**: `_groupGreetedAt` (антидубль приветствия),
`_sponsorCreditShownAt` (троттлинг строки спонсора, 1 ч на чат).

**`ChatContext`**: `role`, `history: [ChatMessage]`, `pendingTurns`, `model`
(+`modelProviderRouting`), `temp`, `maxHistory`, `showStats/showCost/showModel`,
`provider`, `suffix` (test-mode), `reasoningEffort`, `backupNotify`,
`cumulativeUsage`, per-chat пресеты, счётчики рекламы,
`funnelFirstMessageCounted`, `downgradedFromModel` (платная модель, отложенная
дневным лимитом), `activeModeID`, `listening` (прослушка беседы, §5.7).

**`pendingTurns`**: пока идёт генерация, user-сообщение висит в pending; на
`completed`/`cancelled` `flushResolvedTurns` дописывает пары user+assistant в
`history` **по порядку**. `visibleHistory` = `trimHistory(history)` + незакрытые
ходы, развёрнутые по состоянию: `pending` → вопрос, `completed` → вопрос и
ответ, `cancelled` → ничего.

**Память ограничена дважды**: числом сообщений (`ChatContext.historyRange`
1…50) и байтами (`historyByteBudget` 200 КБ UTF-8). Обе границы применяет
`trimHistory` — единственный путь и в запрос, и в сохраняемую переписку. Бюджет
набирается от новейшего назад; system вне бюджета, новейшее сообщение выживает.

**`TenantState`**: `ownerUsername`, дефолты (модель/роль/длина истории), 4 набора
глобальных пресетов, `whitelistedUserIDs`, `adminUsernames`, `licensedUsernames`,
`cumulativeUsage`, `createdAt`, `paidUntil` (nil = бессрочно;
`isActive = paidUntil == nil || paidUntil > now`), `noticeCycleUntil`,
`sentNotices`, `winbackDiscount`, `remindersOptOut`.

`tenantState(for: chatID)` = тенант из `chatOwnership` или дефолтный владелец;
мутации дефолтов/пресетов — через `mutateTenant(for:)`.

---

## 5. Идентичность, роли, монетизация

### 5.1 `UserKey`, а не @username
Ник арендуемый, поэтому всё про человека (кошелёк, подписка, лицензия, роль,
владение чатами, инвойсы) лежит под `UserKey`:
- `#<userID>` — человек попал боту на глаза;
- голый lowercase-ник — про человека только рассказали (`/tenant adduser`);
  при первом сообщении `identifyUser` переносит запись под `#<userID>`.
Ник не может содержать `#` → формы не пересекаются.

`UserDirectory` (таблица `bot_user` + конфиг `root_owner`): userID ↔ ник/имя,
`firstSeenAt`/`seenAt`, `rootKey` (пин владельца). `identifyUser(userID:
username:firstName:)` зовётся на **каждом** апдейте: обновляет директорию,
`adoptRecords` (переносит всё с ожидающего ника на `#<userID>`; кошельки
**складываются** целиком, включая `toppedUpUsd` и максимумы отметок), освежает
денормализованные ники, прунит директорию не трогая тех, за кем что-то числится.
`seenAt` персистится с троттлингом 15 мин (новый человек и смена ника — сразу).

API стора принимает **ключ**, не текст (`UserKey` без публичного
`init(String)`). Границы: `userKey(forHandle:)` / `userKeyOrRaw(_:)` (только там,
где человек набрал имя; санитайз до `[a-z0-9_]`), `resolved(_:)` (pending →
идентифицированный; для `#<id>` тождественна), `storageValue` (только колонка/
JSON). Наружу — `displayLabel(forKey:)` (`@ник` / имя / `id 12345`); списочные
методы отдают пары `(key, label)`. `UserKey.description` печатает `UserKey(#42)`.
`ChatID`/`UserID` — тоже типы; «id лички = userID» живёт только в
`ChatID.privateChat(with:)` / `UserID.privateChat`; вместо `chatID < 0` —
`isGroup`/`isPrivate`. Целочисленные литералы id разрешены только в тестах.
@username пользователю **не нужен** нигде: резолв идёт по `userKeys(username:
userID:)`, userID первичен.

### 5.2 Роли
- **Суперадмины** (root по умолчанию `@maythe4th`, пин `OWNER_USER_ID`): цены,
  методы оплаты, дефолтные пресеты, free-модели, наценка, реклама, режимы,
  балансы, лимиты расходов, статистика. `rootSuperAdmin` — единственный, кто
  добавляет/удаляет суперадминов.
- **Админы** (владельцы лицензий = оплатившие): свои дефолты, глобальные
  пресеты, выдача платного доступа своим чатам/юзерам.
- **Обычные** — только бесплатные модели + per-chat пресеты.

`hasSubscriptionCoverage`: (1) сам активный тенант, (2) в `licensedUsernames`
активного тенанта, (3) чат в `chatOwnership` активного тенанта, (4) userID в
`whitelistedUserIDs`. `chatAccessStatus(chatID:username:userID:)` →
`ownSubscription | sponsored(@X) | guest(@X) | balance | free` (тот же порядок +
имя плательщика). `hasFullModelAccess` = подписка ИЛИ положительный баланс.
`autoAssignIfNeeded` — непривязанный чат закрепляется за тенантом отправителя.
Инвайты: `InviteRecord` (токен → owner), диплинк `/start <token>`, один активный
токен на владельца. `/simulate`: `isSuperAdmin` учитывает симуляцию,
`isActuallySuperAdmin` — нет; снятие роли суперадмина снимает и симуляцию
(иначе она вернётся вместе с ролью).

### 5.3 Оплата
Подписка 30 дней: активация продлевает от `max(now, paidUntil)`.
`activatePaidSubscription` создаёт тенанта при первой оплате. Истёкший тенант
сохраняет админ-панель, но его чаты откатываются на бесплатные модели.
**Бессрочный остаётся бессрочным** на всех трёх путях: оплата →
`.alreadyUnlimited`, SQL `extendSubscription` → `case when paid_until is null
then null`, ручное «+N дней» (`extendTenantSubscription` →
`SubscriptionExtensionOutcome.alreadyUnlimited`) ничего не пишет.

Способы (всё настраивается из супер-меню, не в env; см. `PAYMENTS_SETUP.md`):
- **Stars** — `sendInvoice`(XTR) → `pre_checkout_query` → `successful_payment`.
- **Карта** — Telegram Payments, `CardPaymentConfig` (токен BotFather, валюта,
  цена в minor units) в состоянии бота.
- **Крипта** — TON/BSC/ETH/TRON, нативный TON + USDT. `CryptoMatchMode`:
  `amountDelta` (один адрес, уникальная дельта суммы по слотам; слотов нет →
  `slotsExhausted`, тихий откат на слот 0 запрещён) или `uniqueAddress` (пул).
  `CryptoPaymentService` — инвойсы/курсы/матчинг, `CryptoPaymentMonitor` — поллинг
  эксплореров (30 с). Курс TON санируется на границе (`plausibleTonUsdRate`,
  `tonAtomicPerUsdCentMicro` на `Int64(exactly:)`) — 0/`NaN`/абсурд не кэшируется
  и не конвертируется; курс фиксируется на выставлении и лежит в инвойсе.
  Курсоры сканирования персистятся
  (`CryptoConfigSnapshot.explorerCursors`, ключ `"<asset>:<address>"`); адрес без
  курсора сканируется на 45 мин назад; курсор двигается **после** зачисления
  пачки, только вперёд и **включительно** (пограничная секунда пересматривается —
  однократность держит хеш, а не часы: `isCryptoTxCredited` спрашивает все
  инвойсы). Срок инвойса судится по времени **перевода**, а не по часам поллера
  (`CryptoInvoice.acceptsFunds(sentAt:)`). `applyMatch` зовёт `fulfil` первым,
  `.paid` пишет только
  на успехе, иначе `.deferred` (инвойс остаётся `open`, курсор не двигается).
  «Деньги в полёте» — `CryptoInvoiceStatus.isAwaitingFunds` (`open`|`partial`),
  такой инвойс не прунится никогда; закрытые режет `pruneCryptoInvoices`
  (кап 200, как у счетов кассы), кроме того, который пишут прямо сейчас.
- **Внешняя касса** (`ExternalPaymentConfig`, вендор FreeKassa SCI): бот
  подписывает ссылку словом 1, касса шлёт уведомление, подписанное словом 2, на
  `/payments/<vendor>`, бот отвечает `YES`. `credentials` возвращает тройку или
  nil (полунастроенный магазин не выдаёт ссылку). Счёт живёт час, повторный тап
  переиспользует открытый (`openExternalOrders` — детерминированный список,
  новые первыми; сменилась цена → старые счета закрываются, живая ссылка одна);
  дедуп `ext:<vendor>:<paymentID>`. `fulfil` вернул
  `.failed` → `reopenExternalOrder` и **не** `YES`. Уведомление судит
  `settleExternalOrder` → `ExternalOrderSettlement`: дубль — только **тот же**
  `vendorPaymentID`, а счёт, закрытый нами (`expired`/`cancelled`), — это
  деньги, пришедшие поздно, и он зачисляется (`closedAs` идёт в лог).
  Страница кассы живёт дольше нашего часа, и «не открыт» ≠ «уже оплачено».
  Подпись — единственная
  аутентификация: сравнение константное (`SecretGuard`), нет подписи = неверная,
  неподписанный POST → 400. Сумма уведомления парсится целочисленно
  (`FiatCurrency.minorUnits`, переполнение и знак → `malformedCallback`).

**`PaymentFulfillmentService.fulfil(_:)` — единственный post-payment путь** для
всех рельсов: дедуп → активация/зачисление → `claimChatForPayment` → съедание
winback-скидки → счётчики воронки → реферальный бонус за конверсию →
`recordTrafficSourcePayment` → `flushNow()`. Путь строит `PaymentReceipt`,
получает `PaymentFulfillmentOutcome` и рисует **только текст** своего канала.
Идемпотентность: charge_id (Stars/карта), tx-хеш (крипта), `ext:…` (касса).
`claimChatForPayment` не отбирает группу у активного спонсора
(`ChatClaimOutcome.keptSponsor`); ручная привязка — `assignChat`.

**Кредиты** (`CreditPack`, $2/$5/$10): payload `credits_<центы>`, зачисление
`credit(purchased: true)` (только этот флаг = реальная оплата, `toppedUpUsd`).
Цену пакета на любой рельсе считает **одна** `CreditPack.price(cents:perUsd:)` —
целочисленно, с `multipliedReportingOverflow`; `nil` = «этой рельсой пакет не
продать» (`starsForCents` и `creditMinorUnits` возвращают `Int?`, вызывающий
обязан это проговорить). `Int(Double)` трапает, а курс персистится.
Свои выключатели у каждого способа: Stars `starsPerUsd`, карта
`usdRateMinorUnits`, крипта — адреса. Пакеты не зависят от продажи подписки.

**Наценка** `markupPercentValue` (дефолт 30%): `priceMultiplier() = 1 + %/100` —
через неё идут **все** видимые цены и списания (`billedCost`, футер,
`chargeBalance`).

**Цена подписки — только `subscriptionPricing(username:)`** (Stars/крипта/карта/
касса), чтобы winback-скидка была показана и списана одинаково. Параметр
`applying:` даёт гипотетическую скидку (предпросмотр). В группу цена берётся с
`username: nil` (прайс-лист, не персональная скидка).

### 5.4 Режимы (`ModePreset` / `ModePresetConfig`)
Эталонные связки настроек от суперадмина: модель (+пин сервиса), стиль, память,
обдумывание, опционально роль. `ModeTier`: `free` 🆓 / `premium` ⭐ (неизвестное
значение декодится как `premium`). ⭐ видны всем; тап без доступа открывает
страницу покупки (`PurchaseSource.mode`) и считает `funnel(.capHit)`. Модель
🆓-режима автоматически попадает в `allowedFreeModelIDs()`. `defaultModeID` —
«рабочий режим», первый кандидат в `fallbackFreeModel()`. `applyMode` пишет весь
бандл или ничего; счётчик тапов ставит обработчик кнопки, не `applyMode`. Любая
ручная правка модели/стиля/памяти/обдумывания снимает `activeModeID`. Формат
ввода: `Название | Подпись | модель | стиль | память | обдумывание`, модель `-` =
любая бесплатная, `id@сервис` = пин апстрима. Новый режим создаётся с ⭐. Конфиг
глобальный (`Config.modes`).

### 5.5 Дневной премиум-вкус, лимиты расходов
`consumeDailyPremium` — бесплатная порция платных ответов в сутки (группа: на
чат, личка: на userID; UTC-сутки; лимит `dailyPremiumLimitValue`, дефолт 5, 0 =
выключено). Счётчик **персистится** (`bot_premium_usage`). Порция возвращается
(`refundDailyPremium`) везде, где зовётся `cancelPendingTurn`.
`paidModelAccess(username:userID:chatID:)` → `.full/.dailyTaste/.none` — единый
гейт пикеров модели.

`SpendPolicy` (`Config.spendPolicy`): дневной потолок расходов у провайдеров
глобально и на тенанта + `CapResponse` при достижении; дефолт «без лимита».
Достигнут → платные модели выключаются до полуночи, владельцу — `OwnerAlert
.spendCapReached`. Расход считает `DailySpendLedger` (в памяти, перекат суток по
UTC на первой записи), пополняет `recordProviderSpend` из `appendAssistant`.
Потолок проверяется **первым** в `resolveDailyPremium`, до дневной порции, и
возвращает `SpendCapOutcome`: `clear` / `capped` / `abandon`. Пока потолок
держит (`capped`), `restoreDowngradedModel` **не зовётся** ни по одной из двух
причин (полный доступ, новые сутки с остатком порции) — иначе гейт снимает сам
себя на том же ходу. Бесплатные модели не гейтятся никогда.

### 5.6 Удержание и рост
- `SubscriptionReminderService` (§12): волны до истечения (`expiryReminderDays`,
  до 3, ключ дедупа `expiring<N>`, берётся ближайшая наступившая) и winback после
  (`winbackDays`) со срочной скидкой (`SubscriptionDiscount`, дефолт −30%/48 ч).
  Дедуп: `noticeCycleUntil` + `sentNotices`, отметка **после** доставки;
  продление сбрасывает набор. `grantWinbackDiscount` возвращает уже живую скидку,
  не выдаёт новую. Каналы: личка спонсора + опционально его группы
  (`ownedGroupChatIDs`, ≤10). 403/«chat not found» → `setBotPresence(isMember:
  false)`; 429/5xx — ретрай. Суперадмины исключены.
- **Возврат по балансу** (`walletWinbackDays`, дефолт 7): только `toppedUpUsd >
  0`, баланс ≈ 0, нет подписки, тишина ≥ N дней. `lapsedNoticeAt` — раз на цикл,
  сбрасывается пополнением.
- **Онбординг** (`OnboardingConfig`/`OnboardingExample`): кнопки-примеры в
  приветствии, `callback_data` `ex:<id>` → тап = обычный запрос через per-chat
  очередь (`runReadyPrompt`, синтетический `GenerationOrigin`), эхо запроса в
  чат `<blockquote>`. `OnboardingPlacement`: `everywhere/privateOnly/groupsOnly`
  (неизвестное → `everywhere`). Максимум 6 примеров, счётчик тапов персистится,
  правка текста сохраняет id.
- **Реферал** (`Domain/Chat/Referral.swift`): ссылка `?start=ref_<userID>`.
  Фазы: `bindReferral` (только привязка) → первый реальный ответ →
  `redeemReferralIfDue` (кредит обоим, уведомления в личку) → первая оплата друга
  → `redeemReferralPaymentBonus` (бонус пригласившему, идемпотентность
  `paidBonusAt`, антифрод-лимит не действует). Антифрод: самоприглашение, одна
  привязка навсегда, только «новый» (`hasPriorBotActivity`), лимит
  `maxRewardsPerInviter` (дефолт 20) — при исчерпании `.boundWithoutReward`.
  Хранение: `bot_referral` + `bot_referral_tally` + `Config.referralTotals`;
  агрегаты живут дольше записей; у `ReferralRecord`/`ReferralTally` рукописные
  `init(from:)` (новые поля опциональны).
- **Источники трафика** (`?start=src_<метка>`): `joined → activated → payers`
  (+`payments`). First touch wins, известный пользователь в `joined` не попадает.
  Метка санитайзится до `[a-z0-9_-]`, ≤32 симв., ≤200 кампаний (сверх — `other`).
  Привязки — `bot_traffic_attribution`, агрегаты — `Config.trafficTotals`
  (restore берёт документ; `rebuildTalliesFromAttributions` — фолбэк).
- **Реклама** (`AdCampaign`): только во free-tier чатах, два дросселя (частота +
  пейсинг), `nextAdToShow` атомарно считает показ и ротирует (least-shown first).
  Нет кампании → синтетический само-оффер из `SelfPromoConfig` (`Config
  .selfPromo`) с кнопкой «⚡ Открыть премиум» (источник `promo`).
- **Спонсор-герой**: строка под ответом в спонсируемой группе (не чаще 1 ч на
  чат), благодарность в меню и на странице покупки, поздравление при оплате.

### 5.7 Прослушка беседы (`ChatTranscript` / `ChatListening`)

Вторая память чата, **только для групп**: обычная `history` — это диалог с
ботом, а в группе большая часть сказанного сказана между людьми, и одна строка
«@bot а он прав?» без двадцати предыдущих не значит ничего.

Живёт в `ChatContext.listening` → значит, ключуется `ChatKey` (**у каждого
топика буфер свой**), едет в `bot_chat_context.data`, переезжает вместе с чатом
в супергруппу, чистится `/forget` и прунингом (§8.5). Всё, что чат никогда не
включал, пишется как `nil` — строка не растёт.

- **Захват** — в `route()` **последней строкой** перед генерацией: всё, что туда
  дошло, — это разговор (команды и ответы на приглашение ввести текст уже
  вернулись выше). `TranscriptCapture` даёт текст (текст ∪ подпись ∪ теги
  `[фото]`/`[голосовое]`/`[видео]`; **картинки не сохраняются**) и цель ответа.
  Пишется в **каждой** группе: слушающей — в её буфер, остальным — в
  пред-буфер (ниже). Ответ бота пишет `appendAssistant` (с id доставленного
  сообщения) — ответ бота это то, на что чаще всего отвечают.
- **«Старт не с нуля» — пред-буфер** (`_overheardPreroll`, **только память**,
  никогда не персистится). Bot API **не умеет отдавать историю чата**: метода
  нет, сообщения до вступления бота недоступны в принципе. Единственное «что
  было раньше», которое существует, — то, что процесс уже видел и раньше
  выбрасывал. Включение забирает его (`seed`) — **только в пустой буфер**, чтобы
  повторное включение не воскрешало только что стёртое; забранное из
  пред-буфера удаляется. Границы: `seedLimit` = 100 сообщ. на чат,
  `seedLifetime` 12 ч (вчерашний разговор — не контекст сегодняшнего вопроса и
  не повод держать его в памяти чата, который ни о чём не просил),
  `prerollChatCap` 256 чатов (реже всего говорившие уходят первыми).
  `ListenSwitchOutcome{changed, seeded}` — сколько подхвачено, и это
  **проговаривается в чат**: сообщения, написанные до согласия, теперь в буфере.
  Обещание и поставка считаются одним `seed` с одним размером — кнопка не
  говорит «подхвачу 100», если чат держит 30. Пред-буфер — это переписка чата,
  поэтому его стирает **и** `/forget`, **и** «Забыть услышанное» (иначе стёртое
  возвращается следующим включением), и он **переезжает** в супергруппу вместе с
  контекстами.
- **Режим приватности Telegram решает всё.** По умолчанию бот получает в группе
  только обращения к себе → прослушка запишет только их. `getMe
  .can_read_all_group_messages` едет из `AppAssembly` в `BotMenuHandler
  .canReadAllGroupMessages`; страница, статус `/listen` и объявление при
  включении говорят об этом прямо (@BotFather → `/setprivacy` → Disable, затем
  удалить бота из чата и добавить заново). Молчать об этом нельзя: чат включает
  прослушку, слышит «читаю вас» и не записывает ничего — со стороны это тот же
  баг.
- **Хронология** — `TranscriptEntry.seq`, сквозной номер, а не индекс: буфер
  теряет старейшее на каждом append, и ссылка-индекс каждый раз указывала бы на
  другое сообщение. Автор хранится `UserKey`, метка резолвится при рендере
  (переименование не переписывает сотню строк).
- **Ответы**: `TranscriptReply` (id + автор + цитата ≤80). Цель в буфере →
  `(в ответ на #N)`; цель уже выпала → `(в ответ @bob: «…»)` — иначе вопрос
  теряет предмет. Тот же маркер уезжает в префикс вопроса
  (`questionPrefix`), чтобы модель знала, о какой из ста строк спрашивают.
- **Промпт**: `[system(роль + ChatTranscript.systemAddendum), user(стенограмма),
  user(вопрос)]`. Адресующее сообщение **исключается** из стенограммы по
  messageID и уезжает отдельно — оно задание, а не фон. Вне прослушки
  `questionPrefix` — ровно прежнее «Тебе пишет @x: », включая «ничего, если ника
  нет».
- **Одна битая строка стоит одну строку**: `ChatTranscript` разбирает `entries`
  поэлементно (нечитаемый элемент пропускается, `nextSeq` восстанавливается по
  последней уцелевшей), автор кодируется одной строкой (`!bot` / `storageValue`
  — `!` вне алфавита ника, поэтому «bot» как ник не столкнётся). Иначе один
  сломанный элемент уносил бы весь `bot_chat_context.data` чата — роль, модель,
  память.
- **Цитата реплая — чужой текст**: экранируется там же, где тело строки
  (`lines(escapeText:)`). Неэкранированный `<` в процитированном сообщении
  роняет весь `sendMessage` дампа.
- **Границы в типе** (§14): `sizeRange` 10…300 (дефолт 100), `entryTextLimit`
  400 симв. на сообщение, `byteBudget` 60 КБ на весь буфер — набирается от
  новейшего назад, как `trimHistory`. Это единственное, что реально держит счёт:
  стенограмма уходит в **каждый** ответ. Уменьшение размера режет буфер сразу
  (`resize`), а не со следующего сообщения. Переводы строк схлопываются: строка
  — на сообщение, иначе участник подделает `#99 🤖 бот: …`.
- **Гейт** — `MenuAccess.paidAccess` и на странице (`MenuPage.listen`), и на
  тапе (`MenuCommand.listen`), и в команде (`/listen on|off`,
  `requireFullAccessForTuning`): это самый большой множитель цены, какой есть.
  **Размер буфера** строже — оператор (`requireOperator`), как длина памяти.
  Стереть услышанное может тот же, кто может выключить: быть труднее стереть,
  чем записать, — неверная сторона для приватности.
- **Включение и выключение проговаривается в чат** (`listenAnnouncement`):
  люди, чьи сообщения сохраняются, — не тот, кто нажал кнопку, и меню они не
  видят. `resetChat` прослушку **не трогает** (ни флаг, ни буфер): это режим, о
  котором чат объявили вслух, а не настройка ответа.
- Кнопка «🎧 Прослушка беседы» на главной странице меню — **только в группе**;
  `/listen` без аргумента показывает статус и цену буфера, `dump`/`clear` —
  прочитать и забыть.
- **Просмотр буфера — это диагностика, а не украшение.** «📜 Что бот слышал»
  на странице **всегда**, в том числе при пустом буфере: прятать её, когда
  пусто, значит убирать инструмент ровно в том случае, ради которого его
  открывают. `transcriptView` показывает буфер чата, а при выключенной
  прослушке — пред-буфер (`isPreview`), потому что «видит ли бот наши
  сообщения» надо уметь ответить **до** включения. Пустой отчёт называет
  причину: приватность / выключено / ещё никто не писал — три разные причины с
  тремя разными действиями. Заметка про приватность печатается и над полным
  буфером (три строки из двухсот — тот же диагноз, что и ноль) и обязана
  выжить в одном сообщении → `MessageSplitter.withTrailer`, тело уступает ей.

---

## 6. LLM-провайдеры

`ProviderGatewayPort`: `capabilities`, `makeRequest(plan)`, `stream(request) ->
AsyncThrowingStream<ProviderStreamEvent>`, `fallbackModel(for:)`.

- **OpenRouter** (`.openrouter`, `.yandex` мапится сюда) — image/audio/video/
  reasoning, `OpenRouterReasoning(effort, enabled)`, provider routing
  (`order`/`only`, `allow_fallbacks:false`), стоимость из usage (`cost` или
  `cost_details.upstream_inference_cost`). SSE
  `openrouter.ai/api/v1/chat/completions`.
- **DeepSeek** (`.deepseek`) — только текст, модель `deepseek-chat`, стоимость не
  отдаёт.

Оба парсят SSE через `NetworkClient.ssePayloads` и складывают чанки одним и тем
же `OpenAIStreamAccumulator<Chunk>` (**один декод на пейлоад**: usage, ошибка и
дельта живут в одном объекте, и три `try?`-декода теряли два ответа из трёх;
поля usage опциональны — отсутствующий счётчик не должен ронять чанк целиком).
Эмитят `.text(chunk)`, `.keepAlive` (жив, но показать нечего) и в конце
`.meta(StreamMeta)` — с `finishReason` (`length` → строка «✂️ Ответ обрезан» в
футере, **независимо** от тумблеров статистики). Обрабатывают отмену и `[DONE]`.
Новый провайдер = конформанс `OpenAICompatibleStreamChunk`, а не копия цикла. **Ошибка внутри потока —
ошибка**: OpenAI-совместимые провайдеры отдают отказ в SSE с HTTP 200
(`{"error":{...}}`) → декод `ProviderStreamErrorPayload` (код читается числом и
строкой) → `ProviderAdapterError.upstream(provider:code:message:)`. Наружу —
`UserFacingError.httpStatusReason`, оригинал в логах, ход не списывается.

`ProviderCapabilities` проверяются **до** генерации (медиа не поддержано →
подсказка). Дефолтная модель `google/gemini-3-flash-preview`.

---

## 7. Генерация (`GenerationCoordinator.processContent`)

1. `markFirstMessageIfNeeded` (воронка) → free-model гейт: нет полного доступа и
   модель платная → `consumeDailyPremium`; остаток есть → отвечаем платной;
   исчерпан → `downgradeModelToFree` (помнит модель в `downgradedFromModel`) +
   оффер (`sendDailyLimitOffer`) + `funnel(.capHit)`. Последняя порция
   проговаривается (`sendLastPremiumCallNotice`, ≤1/сутки). Появился полный
   доступ → `restoreDowngradedModel` с сообщением; новые сутки с остатком →
   молча, до входа в гейт (иначе механика умирает после первого исчерпания).
   **«Бесплатна ли модель» спрашивают только у `allowedFreeModelIDs()`**
   (пины суперадмина ∪ бесплатные OpenRouter ∪ модели 🆓-режимов); **nil = всё
   платное**. Фолбэк — `fallbackFreeModel()` (модель рабочего режима → первая
   закреплённая → `sorted().first`; `Set.first` недетерминирован).
2. Режим биллинга: `covered` → бесплатно; `billedTo` (положительный баланс) →
   списание per-message; иначе free-tier → `adEligible`. Списание, обнулившее
   кошелёк, возвращает `true` из `appendAssistant` → один оффер `balanceEmpty`.
3. `SessionRegistry` + typing (живёт до старта стрима, гасится `defer`).
4. `generationLimiter.acquire()` (`MAX_CONCURRENT_GENERATIONS`, дефолт 64).
5. Текст оборачивается `questionPrefix` — `"Тебе пишет @username: "`, а в
   слушающем чате ещё и `(в ответ на #N)` (§5.7); вложения в историю не
   пишутся, в запрос идут.
6. `snapshotAndAppend` — атомарный снапшот + pending turn. Слушающий чат
   получает `[system+формат, стенограмма, вопрос]` вместо `visibleHistory`;
   адресующее сообщение из стенограммы исключается (§5.7).
7. Стрим: **draft** (`runDraftStreaming`, только личка, Bot API 9.3+;
   финальный текст всегда `sendMessage`, draft эфемерен) или **edit**
   (`runEditStreaming`, группы; правка раз в 3 с или +300 симв.).
8. Разбивка: `MessageSplitter.splitRendered` — бюджет в **экранированных
   UTF-16** единицах, как считает Telegram (`charLimit` 3896 = 4096 минус
   резерв на футер), не режет внутри `<…>`/`&…;`, переоткрывает открытые теги
   (`openTagMarkup`; `script`/`style` никогда) и закрывает их
   (`closingTagMarkup`) перед маркером продолжения, стоп-нотисом и футером.
   Одно сообщение, в которое надо уместить и хвост, собирает
   `MessageSplitter.withTrailer` — **тело уступает хвосту**, а не наоборот.
   Финальную проверку делает `TelegramHTTPGateway.chunkFittingHTML` (бюджет —
   все 4096, ужимается пропорционально).
9. Футер `makeFooter` → `ResponseFooterFormatter`.
10. `appendAssistant` (история + usage + списание) → офферы → реклама; либо
    `cancelPendingTurn` + `refundDailyPremium`.

Отмена: кнопка Стоп → callback → `SessionRegistry.cancel` → `cancelled` →
«⏹ Остановлено». Слот освобождается ровно один раз через `finishGeneration`.

---

## 8. Персистентность: Postgres напрямую

Транспорт — PostgresNIO. Даёт транзакции, БД-ограничения (`check (balance_nanos
>= 0)`, PK ключа идемпотентности, unique платёжного id), `pg_try_advisory_lock`
и параметризацию по построению (`PostgresQuery` —
`ExpressibleByStringInterpolation`, интерполяция → bind-параметр; SQL нельзя
собрать конкатенацией). Подключение — `DATABASE_URL`, **session-режим пула
(порт 5432)**: на 6543 (transaction) advisory lock молча не держится — бот пишет
об этом ошибкой на старте.

### 8.1 Write-behind — всё, кроме денег
`PersistenceCoordinator` (актор) каждые **2 с** дренирует и апсертит только
изменившиеся строки, весь батч одной транзакцией (O(changed)).
- Провал → весь дренаж в `retryCarry` и сливается со следующим
  (`PendingFlush.merged` / `PersistenceBatch.merged`, newer wins; delete
  отменяет upsert и наоборот).
- Дренаж = две неразделимые половины: строки (`drainDirtyBatch`) и кошельки,
  изменившиеся вне транзакции (`drainDirtyWallets`). `PendingFlush` носит обе.
- `flushOnce` сериализован цепочкой тасков (не флагом с опросом); начатый флаш
  доводится до конца даже при отмене вызвавшего таска.
- `flushNow()` — для платежей. `stop()` — финальный flush + один ретрай.
  `abandon()` — остановка **без** флаша (потеря блокировки писателя).

### 8.2 Write-through — деньги (`LedgerPort`)
Кошельки, журнал, ключи идемпотентности и срок подписки пишутся **в транзакции**
и durable до того, как кому-то сказали «оплачено». Метода «двинуть баланс» вне
транзакции не существует.
- `claimPayment` — `insert … on conflict do nothing returning` (проверка+захват
  одним запросом).
- `debit` — блокировка строки, затем `greatest(balance - x, 0)`. (`select … for
  update` внутри того же statement, что и `UPDATE`, возвращает ноль строк.)
- `extendSubscription` — `greatest(now(), paid_until) + N days` считает база.
- Начисление вне платежа — `WalletWriter` (`grant` = `credit(kind:.grant)`,
  `set` = `setBalance`); подписка/winback вне платежа — `SubscriptionWriter`
  (`paid_until` и `winback_*` write-behind не пишет **никогда**).
- Память — кэш: стор мутируется **после** коммита (`applyCommitted*`).
- Идемпотентность не-платежей — `claim(_:)` (`bot_claim`), ключи
  `refsignup:<id>` / `refbonus:<id>`, в той же транзакции, что и кредит.
- Удаление кошелька пишет закрывающую строку `correction` (`reconcile()`
  суммирует журнал с начала).
- `bot_ledger` — журнал каждого движения; инвариант `sum(amount_nanos) =
  balance_nanos` проверяет `reconcile()`, расхождение → `OwnerAlert
  .ledgerMismatch`.
- `InMemoryLedger` — тот же контракт без durability (разработка, тесты,
  деградированный режим).

### 8.3 Схема
Принцип: **jsonb — для документов, колонки — для данных**.
```
bot_user(user_key PK, user_id unique, username, first_name, first_seen_at, seen_at)
bot_wallet(user_key PK, balance_nanos check >= 0, topped_up_nanos, spent_*_nanos, …)
bot_ledger(id, user_key, kind, amount_nanos, balance_after_nanos, ref, created_at)
bot_payment(idempotency_key PK, user_key, purpose, amount_cents, chat_id, method)
bot_tenant(user_key PK, paid_until, default_*, presets jsonb, licences jsonb, …)
bot_chat(chat_id PK, type, title, username, owner_key, bot_removed)
bot_chat_context(chat_id, thread_id, data jsonb)  PK (chat_id, thread_id)
bot_invite(token PK, owner_key)
bot_premium_usage(subject PK, day, used)
bot_referral(invited_user_id PK, inviter_user_id, rewarded_at, paid_bonus_at, data)
bot_referral_tally(inviter_user_id PK, data jsonb)
bot_traffic_attribution(user_id PK, tag, joined_at, activated_at, paid_at, payments)
bot_funnel_daily(day, event, count)  PK (day, event)
bot_crypto_invoice(id PK, owner_key, status, expires_at, data jsonb)
bot_external_order(id PK, payer_key, status, vendor_payment_id unique, data jsonb)
bot_claim(key PK)
bot_config(key PK, data jsonb)
bot_schema_meta(id PK, version)
```
`bot_config` (21 ключ `ConfigName`, значения обёрнуты в `{"value": …}`):
stars_price, stars_per_usd, free_models, crypto, card, super_admins, root_owner,
polling_offset, ads, markup, funnel, funnel_daily, daily_premium_limit,
self_promo, modes, reminders, onboarding, referrals, referral_totals,
traffic_totals, external_payments, spend_policy. Ничто из них не растёт с числом
пользователей. `root_owner` восстанавливается **до** `ensureDefaultOwnerTenant`
и сборки `superAdminKeys`.

**Миграции в бинаре** (`PostgresSchema`), на старте: версия базы > бинаря → **не
стартуем** (единственная ошибка хранилища, роняющая процесс; `bootstrapState`
её пробрасывает); версия меньше → встроенные шаги по порядку, все
`create … if not exists`.

**Одна битая строка не роняет restore только там, где потеря самолечится**:
`bot_chat_context` читается через `mapSkippingUnreadable`; тенанты, кошельки,
счета, реферал — строго. Legacy-путь (`bot_state`, `BotStateSnapshot`) удалён.

### 8.4 Единственный писатель
`WriterLock` берёт `pg_try_advisory_lock` на выделенном соединении на всё время
жизни процесса. Порядок в `bootstrapState`: **миграция → блокировка → чтение**.
- Не взяли → процесс сразу `ready` (иначе healthcheck-gated деплой встаёт в
  дедлок), но **не принимает апдейты** (`StateDurability.acceptsUpdates` →
  webhook 503) и раз в 2 с пробует блокировку → `claimWriterAndRestore`.
  Ожидание >10 мин = `OwnerAlert.notWriter`.
- Потеряли на ходу → `stepDownAsWriter`: `abandon()` + выключение. `onLost`
  значит «отняли то, что держали», и только это (неудачная попытка молчит).
- `shutdown()` освобождает блокировку **последним действием**, после флаша.

### 8.5 Ретеншн и `/forget`
`RetentionService` — суточный свип: `pruneChatContexts` удаляет переписки старше
180 дней, кроме чатов, за которые кто-то платит; `pruneFunnelDays` режет бакеты
`bot_funnel_daily` вне окна. Горизонт окна один на загрузку и на чистку —
`FunnelDailyLog.oldestLoadedDay()` (две рукописные границы разъезжаются).
Половины свипа независимы: падение одной не отменяет другую. Запускает только
писатель. `/forget` стирает переписку своего чата (в группе — только у
оператора); кошелёк, подписка и `bot_ledger` не трогаются.

### 8.6 Durability как условие продажи
`StateDurability` (`durable/readOnly/volatile`) в `RuntimeFlags`, стартует
закрытым (`volatile("starting")`). Не durable → не продаём. Пять входов:
`/buy`, рендер страницы `pay`, `pre_checkout_query` (`answerPreCheckoutQuery(ok:
false)`, деньги не списываются), `handleBuyAction` (все `menu:buy:*` — кнопка в
старом сообщении переживает рестарт), `PaymentFulfillmentService.fulfil` (крипта
и касса не проходят через первые четыре) и `ExternalPaymentService
.handleCallback` **до** поиска счёта. `/ready` при этом 200, `/metrics` отдаёт
`durability` и `degraded`.

---

## 9. Надёжность и масштабирование

- `UpdateIntake` — единая точка для webhook и polling: дедуп по `update_id`
  (кольцевой буфер 2048), склейка альбомов (holdback 750 мс, тик 300 мс).
  `shutdown()` **сливает** буфер (за эти апдейты Telegram уже получил 200).
- `TelegramPhotoAlbumBuffer` ограничен со всех сторон: частей на альбом 16,
  жизнь альбома 10 с, апдейтов в очереди за чатом 64, альбомов 256; по
  превышению альбом отдаётся как есть, лишнее уходит вне очереди.
- `ChatUpdateDispatcher` — порядок в чате, параллельность чатов, очередь 16.
- `GenerationLimiter` — FIFO-семафор, `MAX_CONCURRENT_GENERATIONS` (64).
- `TelegramRateLimiter` — token-bucket: глобально ~18 msg/s + draft 8/s
  (droppable) + косметика/typing 3/s; per-chat личка ~1/s, группа 20/min;
  авто-retry по `retry_after`. **`editMessage` идёт мимо per-chat ведра**
  (`waitForEditSlot`, только глобальное): иначе edit-стриминг съедает бюджет
  группы и блокирует чтение SSE.
- Graceful shutdown (SIGTERM/SIGINT): `draining=true` (webhook 503) → слив
  интейка → ждём до 8 с опустошения **и** per-chat очередей
  (`totalQueuedOperations`), **и** активных стримов (`activeCount`) → отмена
  фоновых тасков → финальный flush. «Стоп» не обнуляет `activeCount` заранее.
- `/payments/<vendor>` — POST/GET, форма (не JSON), аутентификация подписью
  вендора; принятое-но-непригодное (неизвестный счёт, недоплата) подтверждается
  и логируется; 400 — только неподписанному.
- Health: `/health`, `/ready`, `/metrics` (**закрыт токеном**: `Authorization:
  Bearer <METRICS_TOKEN>`, при незаданном — вебхук-секрет, сверка
  `SecretGuard.constantTimeEquals`; `Accept: text/plain` → Prometheus, включая
  `bot_state_degraded` и `bot_alert_firing`).
- `RuntimeMetrics`/`MetricName`: updates received/deduplicated/dropped,
  generations, telegram_429, send errors, persistence flushes/errors, payments
  processed/deduplicated, reminder sweeps/sent/winbacks/errors.
- **Воронка** (`FunnelEvent`): start → addedToGroup → onboardingShown →
  exampleTapped → firstMessage → capHit/capWarned → promoShown/balanceEmpty →
  openPurchase → invoiceSent → paid/renewed + creditTopup; удержание
  expiryReminder → winbackSent → winbackRedeemed → walletWinbackSent; рост
  referralJoined → referralRewarded → referralPaidBonus. Каждое событие пишется
  дважды: общий счётчик + подневный бакет (`FunnelDailyLog`, окно 35 суток).
  `openPurchase` считается с поверхностью: ключ `openPurchase.<PurchaseSource>`.
  Возвращаемость — `UserDirectory.retention` (firstSeenAt + seenAt, D1/D7).
- **Режим апдейтов** (`UpdateMode`): `auto` (webhook при публичном URL, иначе
  polling), `webhook`, `polling`. Подписка на типы — одна на оба транспорта
  (`TelegramUpdateSubscription.allowedUpdates`: message, callback_query,
  pre_checkout_query, my_chat_member): без явного списка `getUpdates` молча
  выкидывает `my_chat_member`. `setWebhook` упал → сначала `deleteWebhook()`.

---

## 10. Команды (`BotCommandName` / `BotCommandHandler`)

Парсинг `CommandParser`: `/cmd`, `/cmd@botusername`, суффикс тест-режима
(`/model3` при `suffix=3`). До access-gate разрешены только `/start` и `/buy` —
через парсер, не по префиксу строки.

- **Чат/настройки**: `/setrole`, `/clear_history`, `/settemp`, `/model`,
  `/historylength`, `/show_model`, `/show_cost`, `/show_tokens`, `/provider`,
  `/testmode`, `/reasoning`, `/help`, `/menu`, `/reset`, `/history`,
  `/reset_stats`, `/backup_notify`, `/chatid`, `/forget`, `/start`, `/buy`,
  `/balance`, `/examples`, `/ref`, `/listen` (только группа, §5.7).
  Гейты те же, что у страниц меню: `/settemp` и `/reasoning` — полный доступ
  (`requireFullAccessForTuning`), `/historylength` и `/provider` — оператор
  (`requireOperatorForTuning`).
- **Админ/тенант**: `/default_role`, `/defaults`, `/whitelist`, `/chats`,
  `/users`, `/presets`, `/tenant` (assign/release/adduser/register/remove/
  freemodels/crypto/…), `/inspect`, `/ads` (+`/ads promo`), `/invite`.
- **Суперадмин**: `/superadmin`, `/simulate`, `/reminders`, `/examples`, `/ref`,
  free-модели, цены, наценка, балансы (в основном через супер-меню).

Аудитория подкоманд `/tenant` — на типе, не в списке имён: `TenantSubcommand`
(`String`-enum) + `audience` исчерпывающим switch без `default`, как
`MenuCommand.access` у кнопок. Новая подкоманда не собирается, пока не назовёт
аудиторию. Списочные команды капнуты `BotCommandHandler.listCap`.

Неизвестная команда → `.mention`/`.unknown` (игнор или обычная генерация).

---

## 11. Inline-меню (`BotMenuHandler`)

Страницы (`MenuPage`, `callback_data` `menu:<action>`): `main` (режимы, роль,
сброс, тонкая настройка), `tuning`, `listen` (§5.7, только группа), `pay`, `ref`, админ-панель (`admin`,
`adminhelp`, `adminchats`, `adminusers`, `adminwl`, `admindef`, `admininvite`),
супер-панель (`superadmin`, `superadminhelp`, `superstars`, `supercrypto`,
`supercard`, `superextpay`, `superfreemodels`, `supertenants`, `superadmins`,
`supersim`, `superchats`, `superads`, `superbal`, `superfunnel`,
`superreminders`, `superonboarding`, `supermodes`, `superspend`, `superref`,
`supersrc`).

- **Гейт — данные, а не список имён**: `MenuAccess` (`everyone`/`paidAccess`/
  `chatOperator`/`superAdmin`) висит на `MenuPage.access` и `MenuCommand.access`,
  оба switch'а **исчерпывающие без `default`** — новая страница и новая команда
  не собираются, пока не назовут аудиторию (рукописный перечень `super*` в
  `nav:` открывал всё, что забыли дописать). Предикат один —
  `satisfies(_:chatKey:invoker:userID:)`, и его спрашивают **трижды**: тап
  (`processAction`, до всякого обработчика), показ (`showPage`/`nav:`) и
  перерисовка (`renderPage`, идёт без callback после введённого текста —
  минуты спустя, когда роль могли снять). Отказ `paidAccess` ведёт на страницу
  покупки (`PurchaseSource.tuning`), отказ роли — тост. Хаб `tuning` открыт.
  Частные `require…` внутри обработчиков остаются: это более тонкое правило
  (чья заготовка, чей чат), а не дубль.
- **Клавиатура живёт дольше прав**: сообщение с кнопками остаётся в чате после
  истечения подписки и в группе общее для всех, поэтому настройка, множащая
  цену ответа (`temp`, `reasoning`, `provider`, длина памяти), закрыта на
  **тапе**, а не только на отрисовке страницы.
- **`MenuScreen`** — текст + клавиатура + `fitsInOneMessage` (`length` —
  UTF-16, как считает Telegram); `warnIfOversized`
  логирует переросшую страницу. Ряды копит `Keyboard` (`row`, `row(if:)`,
  `insertBeforeLast`, `extendLastRow`). Списки на `super*`-страницах режутся с
  явной строкой «показаны первые N» (editMessage обрезает после ~3900).
- **`backLabel`** живёт у страницы-назначения (`backButton(to:)`,
  `cancelButton(to:)`).
- **`isPersonal`** (`ref`, `admininvite`, `superbal`) — в группе не рендерятся
  вообще (`showPage` отвечает тостом, `renderPage` дублирует гейт). `renderPay`
  и `renderMain` в группе не печатают личных чисел (баланс, срок, персональная
  скидка, метка «Продлить»).
- **`MenuRoute`** — `callback_data` разбирается один раз: `command`
  (`MenuCommand`, enum), `arg(i)`/`int(i)`/`page(i)`/`sub`; пустой аргумент =
  отсутствующий. Наружу payload собирают только `MenuRoute.link(_:_:)`/
  `navigation(to:)`/`purchase(from:)` и `menuButton(_:page:)`/
  `menuButton(_:command:)`/`menuButton(_:_:_:)`/`buyButton(_:source:)`;
  строковый `menuButton(_:action:)` — `private`. Аргументы payload — значения,
  а не строки: `CallbackArgument` (`UserKey` → `storageValue`, `ChatID`/`UserID`
  → число, enum → `rawValue`). Интерполяция id в payload запрещена:
  `"\(userKey)"` — это отладочное `description` (`UserKey(#42)`), обратно оно
  адресует никого.
- **Лимит `callback_data` — 64 байта** (`MenuRoute.maxCallbackDataBytes`);
  превышение отклоняет **всё сообщение**. Пресеты моделей ездят позицией в
  списке (`presetTarget` принимает и позицию, и значение — ради старых кнопок).
  `menuButton` при превышении рисует мёртвую кнопку с записью в лог.
- **Pending-input**: кнопка кладёт `setPending(kind, menuMessageID:chatKey:)`,
  следующий текст ловит `processTextInput` (шаг 6 роутинга). Ожидание **одно на
  чат** (`PendingRequest {owner, menuMessageID, kind, armedAt}`, `PendingKind` —
  все виды). У ожидания есть **владелец** (`notePendingInputOwner(invokerKey)`);
  чужое сообщение → `processTextInput` возвращает `false` и оно идёт в LLM.
  Невалидное значение перевзводит то же ожидание, владелец проставляется заново.
  TTL `PendingRequest.lifetime` = 30 мин; все чтения через `livePending` (он же
  удаляет протухшее); `setPending` подметает карту выше 256 записей.
- Необратимое действие (удаление тенанта `stenant:rm→rmyes`, кошелька
  `sbal:rm→rmyes`, очистка журналов) спрашивает подтверждение.
- Справка суперадмина разбита на `SuperHelpSection` (`sahelp:<раздел>`).

---

## 12. Фоновые процессы (в `run`)

- `ModelPriceMonitor` — каждые 5 мин + initial: `openrouter.ai/api/v1/models` →
  `openRouterModelPrices` + `openRouterFreeModelIDs`; модель стала платной →
  уведомление затронутым чатам либо суперадминам (`superAdminPrivateChats()`,
  личка каждого, не чаты root-тенанта). Каталог судится на границе
  (`ModelCatalogueReading`): **пустой `data` — авария апстрима, а не новость,
  что всё стало платным**, прошлый набор переживает её; решение «кто стал
  платным» — `modelsThatBecamePaid` (отсортировано). Рассылка про модель —
  раз в сутки на модель (`AnnouncementThrottle`), сама смена доступа не
  троттлится; он-деманд фетч цены — раз в минуту на модель.
- `CryptoPaymentMonitor` — каждые 30 с: эксплореры, матчинг, частичные оплаты,
  экспирация. Позицию сканирования держит стор.
- `runPersistenceNotifyLoop` — каждые 60 с: статус хранилища чатам с
  `backupNotify=true`.
- `SubscriptionReminderService.run` — первый проход через 60 с, дальше каждые
  `sweepIntervalMinutes` (дефолт 60), сон минутными кусками с перечитыванием
  конфига; свип сериализован флагом `sweeping` (кнопка «Проверить сейчас» не
  пересекается). Работает и в memory-only. Рассылка капнута на свип
  (`maxNoticesPerSweep` 200, `SendBudget` — один потолок на обе половины);
  непоместившееся видно в `SweepResult.deferred` и уезжает в следующий свип
  (отметка ставится только после доставки, порядок детерминирован).
- `RetentionService` — суточный прунинг переписок и бакетов воронки (§8.5,
  только писатель).
- `OwnerAlerter` — алерты владельцу: одно сообщение на возгорание, одно на
  погасание, не чаще раза в час на вид (`AnnouncementThrottle`).
  **Восстановление отправляется только для объявленного инцидента** — иначе
  мигающее условие молчит на входе и говорит на каждом выходе. Недоставленный
  алерт остаётся необъявленным (следующая попытка через час), `detail`
  экранируется и обрезается (чужой текст в HTML роняет `sendMessage`).

Бесплатные модели: `effectiveFreeModelIDs()` = пины суперадмина ∪ бесплатные
OpenRouter; `allowedFreeModelIDs()` = оно же ∪ модели 🆓-режимов — **гейты
спрашивают только его**, nil = «всё платное».

---

## 13. Переменные окружения (`AppConfig` / `EnvironmentKey`)

**Обязательные**: `TG_BOT_TOKEN`, `DEEPSEEK_API_KEY`, `ROUTER_API_KEY`.

**Опциональные**:
- `DATABASE_URL` — `postgres://user:pass@host:5432/db?sslmode=require`,
  **session-режим (5432)**. Без неё — memory-only и касса закрыта.
- `STATE_ENCRYPTION_KEY` — 32 байта base64. Шифрует платёжные секреты (токен
  карты, оба слова кассы). Кривой ключ = отказ стартовать. Чужой шифротекст
  читается как «не задан», но **не перезаписывается** (`SealedSecret` хранит
  форму хранения); в UI у этого состояния свой текст `Texts.secretUnreadable`.
- `TELEGRAM_WEBHOOK_SECRET` — 1–256 симв. `A-Za-z0-9_-`
  (`AppConfig.isValidWebhookSecret`), иначе отказ стартовать.
- `OWNER_USERNAME` (дефолт `maythe4th`), `OWNER_USER_ID` (без него root
  опознаётся только по арендуемому нику — warning на старте).
- `PORT` (8000), `UPDATE_MODE` (auto/webhook/polling), `WEBHOOK_PUBLIC_URL` или
  `RAILWAY_PUBLIC_DOMAIN`, `METRICS_TOKEN`, `MAX_CONCURRENT_GENERATIONS` (64),
  `LOG_LEVEL`, `LOG_FORMAT` (`json`), `COMPANY_CHAT_ID`.
- Эксплореры: `TONAPI_KEY`, `ETHERSCAN_API_KEY` (V2 multichain: ETH+BSC),
  `BSCSCAN_API_KEY` (legacy), `TRONGRID_API_KEY`.
- `TELEGRAM_API_BASE` — **только для сквозных тестов** (локальный дублёр Bot
  API); в проде не задавать.

Цены/токены оплаты в env не хранятся — только в `bot_config`.
`SecretRedactor` (регистрируется в `main` до первой строки лога) вычищает токен
бота и ключи из `ConsoleLogger` и `UserFacingError.message`.

---

## 14. Конвенции и инварианты

**Структура кода**
- Крупный тип разбит на `Тип+Тема.swift`; головной файл — зависимости,
  хранилище, диспетчеры. Файл >~700 строк пора делить. Члены, видные соседнему
  `+файлу`, — `internal` без `private`.
- Switch — диспетчер: функция >~120 строк режется, внешний switch по строке на
  ветку, тело в метод со своим switch (+`default: break`).

**Состояние**
- Всё изменяемое — через актор `ChatContextStore`. Новая сущность обязана:
  (а) метить dirty-set, (б) экспортироваться/импортироваться в
  `ChatContextStore+Persistence.swift`, (в) при надобности получить `ConfigKey`.
- Новая настройка `bot_config` = строка в `ConfigRegistry` + поле в сторе +
  ветка в `currentConfig(for:)` (реестр читается рефлексией, экспорт —
  исчерпывающий switch по `ConfigName`).
- Новая сущность «на пользователя» ключуется `UserKey` и переносится в
  `adoptRecords`.
- Границы настроек чата — только в домене (`ChatContext.historyRange`,
  `tempRange`, `ClosedRange.clamping`), стор клампит сам.
- Коллекция, которую растит **пользователь**, носит кап в типе, а не в
  вызывающем: `PresetList` (12 записей, `add` отвечает `.full`, `normalized`
  режет длины и чинит id), `ChatTranscript` (`sizeRange`/`entryTextLimit`/
  `byteBudget`, §5.7) — `append` в такую коллекцию не должен
  компилироваться. Переполнение проговаривается человеку, а не глотается.
- Состояние чата ключуется `chatID`, поэтому смена id (апгрейд в супергруппу)
  обязана быть переездом: новая строка грязная, старая — удалённая (§3).
- `resetChat` возвращает **настройки**, но переносит накопленное (usage,
  пресеты, `funnelFirstMessageCounted`, счётчики рекламы, `listening` целиком —
  §5.7). Новое поле `ChatContext` обязано ответить, настройка оно или
  накопленное.
- jsonb-колонка с дефолтом `'{}'` требует **рукописного `init(from:)`**:
  синтезированный декодер игнорирует значения по умолчанию и бросает на
  отсутствующем ключе — одна строка кладёт весь restore.

**Деньги**
- Все видимые цены и списания — через `priceMultiplier()`; цена подписки — через
  `subscriptionPricing(username:)`.
- Деньги пишутся только через `LedgerPort.inTransaction`; кошелёк вне платежа —
  `WalletWriter`, подписка/winback вне платежа — `SubscriptionWriter`; кэш
  двигают только `applyCommitted*`.
- Начисление и отметка «выплачено» — разные места: однократность держит
  `claim(_:)`, а не отметка.
- Платежи — `flushNow()`. Исключение: реферальные выплаты (кредит и `rewardedAt`
  в одном шаге актора, теряются вместе).
- Пакет кредитов — `credit(purchased: true)`; бонусы и гранты — `false`.
- Новый платёжный путь не пишет свой post-payment код — только
  `PaymentFulfillmentService.fulfil` (§5.3), и обязан обработать
  `.keptSponsor`.
- `.failed` из `fulfil` обязан оставить дверь открытой: Telegram передоставит,
  крипта держит инвойс `open` и курсор (`.deferred`), касса возвращает счёт в
  `pending` и не отвечает `YES`.
- Курсор блокчейна двигается последним и только вперёд; дефолт — «сейчас минус
  45 минут».
- Подпись уведомления кассы проверяется первой, в постоянном времени; нет
  подписи = неверная; имена полей сверяются регистронезависимо.
- Адрес токена сравнивается точно: TON — `TonAddress.equal` (обе записи), Tron —
  побайтово (base58 регистрозависим), EVM — lowercase hex. Тем же сверяется
  получатель.
- В `amountDelta` усыновление непривязанного инвойса требует ≥
  `minimumAdoptableShare` остатка и берёт ближайший по сумме; точное совпадение
  сверяется с `remainingAtomic`.
- Новый вход в кассу проверяет `StateDurability`.
- Идемпотентность обязательна на каждом пути (charge_id / tx-хеш / `ext:…`).
- Счёт, закрытый **нами** (истёк, отменён), — не повод не зачислить пришедшие
  по нему деньги: дублем считается только повтор того же платежа вендора.
- Сумма, пришедшая снаружи, парсится целыми числами и с проверкой переполнения:
  негодное значение — ошибка разбора, а не трап (`Int(Double)` роняет процесс, и
  вендор будет доставлять то же уведомление в цикле).

**Доступ и роли**
- «Можно ли модель без оплаты» — только `allowedFreeModelIDs()`, **nil =
  платная**; фолбэк — `fallbackFreeModel()`.
- Дневная порция премиума — ресурс: взял `consumeDailyPremium` — верни
  `refundDailyPremium`. Счётчик персистится.
- Настройка, множащая стоимость ответа, закрывается **и** в меню, **и** в
  команде.
- Гейты ролей идут через `invokerKey(callback)` / `actorKey(fromUser)` /
  `ownerKey(for:)`, не через сырой `username`. Своя принадлежность —
  `userKeys(key:userID:).contains(owner)`. Для гейтов, работающих при симуляции,
  — `isActuallySuperAdmin`.
- Ключ наружу не показывать: `displayLabel(forKey:)` или поле `label` (метки уже
  содержат `@`).

**Telegram**
- `callback_data` не пишется строкой (§11); новая команда = новый `case
  MenuCommand`. В payload едут id и индексы, не чужой текст.
- Кнопка, которая **что-то меняет**, несёт стабильный id записи, а не её
  позицию: клавиатура описывает список на момент отрисовки, а живёт дольше
  (`Preset.id`, `OnboardingExample.id`, `ModePreset.id`, `UserKey` для гостей и
  кошельков). Промах отвечает «не найдено», а не попадает в соседа. Особенно
  там, где список сортируется по данным, которые меняются сами: `licensedUsers`
  — по метке, а метка обновляется, когда бот впервые видит человека. Чтение
  позиции остаётся только ради кнопок из сообщений старого билда
  (`presetTarget`).
- Кнопка «купить» несёт `PurchaseSource` (`menu`, `cap`, `promo`, `welcome`,
  `command`, `reminder`, `balance`, `referral`, `model`, `mode`, `tuning`);
  неизвестный суффикс читается как `menu`.
- Callback'и — вне per-chat очереди (Стоп обязан прерывать); исключение —
  кнопка, **запускающая** генерацию (`ex:`), идёт через очередь.
- Приветствие группы — только через `claimGroupGreeting` и
  `GroupWelcomePresenter`.
- Рассылки в группы — через `ownedGroupChatIDs` (отсекает `botRemoved`), в личку
  — через `privateChatID(forKey:)` (отсекает заблокировавших). 403 и «chat not
  found» → `setBotPresence(isMember:false)`, не ретрай; 429/5xx — ретрай.
- Персональная цена не уходит в общий чат; `isPersonal`-страницы в группе не
  рендерятся. Это же правило держат **команды**: `/buy` в группе берёт
  `subscriptionPricing(key: nil)` и молчит про срок подписки и скидку, а
  `sendCryptoAssetChoice` роняет `invoker` внутри себя — оба входа одной строкой.
- Отчёт, у которого две двери (кнопка и команда), имеет **одну** реализацию:
  `/history` зовёт `sendHistoryDump`, `/ads` режет тем же `htmlPreview`. Копия
  расходится с оригиналом ровно на его починки.
- Draft — только личка; финальный текст обязательно `sendMessage`.
- `editMessage` — через `waitForEditSlot()`, не `waitForMessageSlot`. «Ошибка»
  `message is not modified` — успех (`TelegramAPIError
  .isEditWithNothingToChange`): постусловие выполнено, а раннер стрима роняет
  ход на всём, что не 429. Остальные отказы остаются ошибками.
- Длина сообщения меряется в UTF-16 **везде**, включая развилку «слать одним или
  резать» (`sendMessage`) — она стоит до `chunkFittingHTML` и до
  `MessageSplitter`.
- Вложения качаются в пределах `TelegramMediaResolver.turnByteBudget`: альбом —
  16 файлов, медиа резолвится **до** `generationLimiter.acquire()`, поэтому
  больше ничто в пайплайне их не считает.
- Имя пользователя — чужой текст: экранирование живёт в источнике меток
  (`UserIdentity.displayLabel`, `sanitizeName`, `ChatMetaInfo.displayLabel`).
  То же для текста, который человек ввёл сам и который печатается в сообщение:
  хранится сырым (значение уезжает в модель), экранируется в точке, где
  становится разметкой (одна реализация — `MessageText.escaped`; поверх неё
  `Preset.escapedDisplay`/`escapedValue`, `HelpData.escapedModel`/`escapedRole`,
  `ModePreset.escapedTitle`/`escapedSubtitle`/`escapedRole`,
  `OnboardingExample.escapedLabel`/`escapedPrompt`, `ExternalPaymentMethod
  .escapedTitle`/`escapedCode`, `ExternalPaymentConfig.escapedMerchantID`).
  Модель и роль чата задаёт **любой участник** — страница, печатающая их сырыми,
  перестаёт открываться у всего чата.
  Подпись кнопки — не разметка, там сырой текст. Настройка, набранная
  суперадмином, тоже чужой текст: `<` в ней роняет **весь** `sendMessage`.
- Значения атрибутов экранируются целиком, включая кавычки
  (`escapeAttributeValue`); `href` — только `allowedURLSchemes` (http, https, tg,
  mailto, tel), иначе тег `<a>` отбрасывается вместе со схемой.
- Резать длинный текст — только `MessageSplitter.splitRendered`; служебная
  строка после ответа — после `closingTagMarkup(in:)`, а если она обязана
  выжить в одном сообщении — через `withTrailer` (правка сообщения обрезает
  **хвост**, то есть ровно её). Длина считается в UTF-16: эмодзи — два, а не
  один. `renderedTags` держать в согласии с allow-list форматтера.
- Вывод — HTML, не Markdown. `/help` (`BotCallbackHandler.faqText`) держать под
  ~3800 символов; супер-админские команды — в `superAdminHelpText`.

**Провайдеры**
- Ошибка внутри SSE обязана ронять поток (`ProviderStreamErrorPayload` →
  `ProviderAdapterError.upstream`), тихий `continue` запрещён.
- `UserFacingError` не выпускает наружу английский текст провайдера и тело
  ответа апстрима — только `httpStatusReason(code)`; итог проходит
  `SecretRedactor`.

**Тексты**
- Русский, обращение на «вы». Внутренние термины наружу не выходят: `tenant` →
  «премиум-доступ · спонсор», `whitelist` → «гости чата», `preset` →
  «заготовки», `provider` → «сервис ИИ», `reasoning` → «обдумывание»
  (`ReasoningEffort.displayName`, ввод `ReasoningEffort(userInput:)`),
  температура → «стиль ответа», длина истории → «память», футер → «под ответом».
  Жаргон допустим на `super*`-страницах и в супер-админских ветках.
- Повторяющийся литерал — в `Texts`; строка, называющая человека/чат, собирается
  на месте.

---

## 15. Тесты

`swift test` — цель `LLM_chat_botTests`, 587 тестов в 60 классах; 566 без сети
(`Fixtures.makeStore()`), 21 `PostgresIntegrationTests` сам себя пропускает без
`TEST_DATABASE_URL` — и пропущенный набор **не** зелёный прогон:

```
docker run -d --rm --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=botdb \
  -p 55432:5432 postgres:16-alpine
TEST_DATABASE_URL='postgres://postgres:test@127.0.0.1:55432/botdb?sslmode=disable' swift test
```

Наборы: `DurabilityTests` (разбор `DATABASE_URL`, гейты durability, `Money`,
`PublicOriginTests`, `SecretBoxTests`), `LedgerTests`, `ConfigRoundTripTests`
(каждая строка `bot_config` пишется **и читается обратно** — иначе молчаливый
откат на дефолт при рестарте), `PostgresIntegrationTests` (миграции, БД-
ограничения, конкурентный `claimPayment`, writer lock, round-trip состояния),
`PersistenceCoordinatorTests`, `MessageSplitterTests` (включая хвост, который
обязан выжить, и длину в UTF-16), `ServerSentEventParserTests`/`URLFormTests`
(кадрирование SSE и форма кассы), `ProviderStreamTests` (разбор потока
провайдера: ошибка в 200 OK, обрыв до usage, частичный usage, `finish_reason`,
числа-мусор, вотчдог),
`TelegramHTMLFormatterTests` + `…GoldenTests`/`HTMLCorpus` (69 входов),
`CommandParserTests`, `MessageRoutingPolicyTests`, `UserIdentityTests`,
`StoreRootOwnerTests`, `SubscriptionScheduleTests`, `Store*Tests`
(доступ/подписки/кошельки/реферал/источники/реклама/free-модели/онбординг/
воронка/dirty+restore), `StoreModePresetTests`, `StoreListenModeTests` (прослушка беседы: захват,
хронология, ответы, форма промпта, границы буфера, свой буфер у топика,
переезд/reset/forget, round-trip строки и настоящий JSON, битая строка не
уносит контекст, экранирование цитаты; пред-буфер: подхват при включении,
не дважды, не поверх стёртого, стирается `/forget` и «забыть», переезжает,
границы по времени и по числу чатов),
`StorePendingInputTests`,
`StoreChatContextTests`, `StorePresetTests` (границы, id вместо позиции,
экранирование), `StoreChatMigrationTests` (переезд в супергруппу),
`UpdateIntakeTests`/`ChatUpdateDispatcherTests`/`GenerationRuntimeTests`
(дедуп, границы альбома, порядок в чате, FIFO слотов, отмена до старта стрима),
`MenuRouteTests` (в т.ч. round-trip ключа через payload),
`MenuPageRenderTests` (рендер
**каждой** страницы личка/группа × владелец/юзер: маршруты существуют, `nav:`
ведёт на реальную страницу, влезает в одно сообщение, гейты, лимит 64 байта,
экранирование введённой модели/роли/заготовки, кнопки редакторов носят id),
`TelegramGatewayTests` (длина в UTF-16 на развилке «одним или резать»; какой
отказ Bot API — успех), `MediaResolverTests` (бюджет вложений на ход),
`PaymentTypeTests`, `ExternalPaymentTests`, `ExternalCallbackEndToEndTests`
(поздняя оплата закрытого счёта, одна живая ссылка на покупку, абсурдная сумма),
`CryptoSettlementTests` (срок по времени перевода, хеш зачтён один раз,
негодный курс TON), `BackgroundLoopTests` (фон: восстановление только для
объявленного инцидента, экранирование `detail`, пустой каталог моделей — авария,
потолок рассылки на свип, прунинг бакетов воронки),
`EndToEndTests` + `FakeTelegram.swift` (апдейт входит в
`dispatch`, проходит настоящие команды/меню/генерацию и настоящий
`TelegramHTTPGateway`, приземляется в локальный дублёр Bot API; подделаны только
модель и загрузчик медиа; цикл по `MenuPage.allCases` требует отказа обычному
юзеру на каждой `super*`; удаление кошелька проходит страница → 🗑 →
«Да, удалить» на реальных payload'ах).

**Правила**: тест формулирует правило продукта, а не текущий вывод функции;
новая денежная или доступная механика приезжает с тестом; хитрый SQL проверяется
на настоящем Postgres; `Tests/` копируется в Docker-образ (SwiftPM проверяет все
цели манифеста); ждать результат — только по условию (`waitUntil`,
`waitForCall`), не `sleep`.
