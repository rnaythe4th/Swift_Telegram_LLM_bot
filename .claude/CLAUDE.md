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
- **Режимы**: эталонные связки настроек от суперадмина — один тап меняет модель,
  стиль, память и обдумывание. 🆓 работают у всех, ⭐ видны всем, но требуют
  премиума/баланса; поштучная настройка — тоже часть премиума.
- **Стриминг ответов**: в личке — нативные анимированные draft'ы (Bot API 9.3+),
  в группах — редактирование сообщения по мере генерации. Кнопка «⏹ Остановить».
- **Мультимодальность**: текст, фото (в т.ч. альбомы), голос, видео — если
  провайдер поддерживает.
- **Мультитенантность и роли**: суперадмины, админы (владельцы лицензий),
  обычные пользователи. Каждый тенант — изолированная копия настроек.
- **Монетизация**: подписки (30 дней) через Telegram Stars / карту / крипту;
  pay-as-you-go балансы с наценкой; реклама во free-tier чатах.
- **Удержание**: напоминания спонсору перед концом подписки (несколько волн) и
  winback-офферы со срочной скидкой после истечения; отдельно — возврат тех, у
  кого закончился оплаченный баланс (расписание настраивается суперадмином).
- **Онбординг**: кнопки-примеры в приветствии — тап запускает готовый запрос и
  бот сразу отвечает (набор примеров правится суперадмином из меню).
- **Рост**: двусторонний реферал — по ссылке `?start=ref_<userID>` друг и
  пригласивший получают бонус на баланс после первого реального ответа, а когда
  друг впервые оплачивает — пригласившему приходит бонус за конверсию (награды и
  антифрод-лимит настраиваются суперадмином).
- **Управление**: слэш-команды + богатое inline-меню (`/menu`).
- **Надёжность**: webhook с очередью Telegram, дедупликация updates,
  идемпотентность платежей, graceful shutdown, rate limiting, health-эндпоинты.

---

## 2. Стек и сборка

- **Язык**: Swift 6.2, strict concurrency (акторы + `Sendable`). Executable target.
- **Зависимости** (`Package.swift`): `async-http-client`, `swift-nio`
  (`NIOPosix`, `NIOHTTP1`, `NIOFoundationCompat`), `swift-crypto` (`Crypto` —
  MD5/HMAC подписей внешней кассы, §7; пакет и так был в графе транзитивно).
  **Никакого Vapor** — HTTP-сервер и клиент собраны напрямую на
  NIO/AsyncHTTPClient.
- **Платформа**: `.macOS(.v13)`; в проде — Linux в Docker (`swift:6.2-bookworm`).
- **Сборка**: `swift build -c release --product LLM_chat_bot`.
- **Тесты**: `swift test` (цель `LLM_chat_botTests`, `Tests/LLM_chat_botTests/`). См. §19.
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
- `LLM_chat_bot.swift` — `@main`. Только **последовательность старта**: собрать
  граф (`AppAssembly.build`), поднять HTTP-сервер, восстановить состояние,
  поставить обработчики SIGTERM/SIGINT, запустить оркестратор.
- `AppAssembly.swift` — **composition root**: весь граф зависимостей собирается
  здесь вручную, фабриками (`makeTelegram`, `makeStore` + сев пресетов,
  `makePersistence`, `makeOrchestrator`, `makeCryptoMonitor`, `resolveMode`,
  `makeHTTPServer`), плюс `registerSecrets` (редакция секретов до первой строки
  лога, §15). Константы бота: владелец по умолчанию `maythe4th`, дефолтный
  system prompt, `formatOptions`.
- `AppConfig.swift` — загрузка и валидация переменных окружения (см. §15).

### Application/
- `BotOrchestrator.swift` — центральный координатор: только зависимости и `init`
  (сборка `BotMenuHandler`/`BotCallbackHandler`/`BotCommandHandler`/
  `GenerationCoordinator`). Тело — по темам:
  `+Lifecycle.swift` (boot с миграцией, run-loop webhook/polling, фоновые циклы,
  graceful shutdown, `/metrics`-отчёт), `+Routing.swift` (`dispatch` — вход для
  всех апдейтов, `route` — пайплайн сообщения, `my_chat_member`, тап по примеру
  онбординга), `+Payments.swift` (`pre_checkout_query`, `successful_payment` обе
  ветки, реферальный бонус за конверсию).
- `ChatUpdateDispatcher.swift` — актор, **сериализует сообщения per-chat**
  (в рамках одного чата обработка строго по очереди, разные чаты — параллельно).
  Очередь на чат ограничена (16); переполнение → дроп с одним предупреждением.
- `Telegram/MessageRouting.swift` — `MessageRoutingPolicy`: решает, реагировать ли
  на сообщение (личка — всегда; группа — только reply боту или @-упоминание),
  и нормализует текст (убирает @упоминание).
- `Telegram/TelegramPhotoAlbumBuffer.swift` — склейка `media_group` (альбомов) в
  один синтетический апдейт.
- `Telegram/OnboardingPresenter.swift` — рендер кнопок-примеров онбординга
  (клавиатура, приглашение, эхо запроса, HTML-escape). См. §7 «Онбординг».
- `Telegram/ReferralPresenter.swift` — текст и кнопка бонуса за оплату друга
  (§7 «Реферал»): его шлют оба платёжных пути, поэтому копия одна.
- `Telegram/GroupWelcomePresenter.swift` — единственное приветствие группы
  (§7 «Вирусный рост»). Два входа (`my_chat_member` и `/start <payload>` от
  `?startgroup=`) рендерят один и тот же текст; вариант зависит от того, покрыт
  ли чат чьей-то подпиской (спонсора благодарим, а не продаём ему).
- `Generation/GenerationCoordinator.swift` — весь пайплайн генерации ответа:
  проверка доступа к модели, выбор режима биллинга, snapshot истории, запуск
  стрима (draft или edit), сборка футера, показ рекламы. См. §9.
  Вход в пайплайн — `GenerationOrigin` (кто спросил, личка ли, на что отвечать):
  строится из `TelegramMessage` либо синтезируется для тапа по примеру
  (`runReadyPrompt`). Рядом — `+Streaming.swift` (draft/edit-раннеры, разбивка
  длинных ответов) и `+Monetization.swift` (гейт дневного премиума
  `resolveDailyPremium` и выбор режима биллинга `resolveBillingMode`, реклама,
  офферы при лимите и пустом балансе, реферальная выплата, футер).
- `Generation/DraftStreamer.swift` — «печатающая машинка» через `sendMessageDraft`.
- `Commands/` — `CommandParser.swift` (парсинг `/cmd@bot`+suffix) и
  `BotCommandHandler.swift` — обвязка, гейты ролей, `handleIfCommand`. Тела
  команд разнесены по `BotCommandHandler+*.swift`: `Dispatch` (**только** switch
  команда → обработчик), `ChatSettings` (тела команд настроек чата: роль, модель,
  стиль, память, тумблеры под ответом, сервис ИИ, обдумывание), `Start`
  (`/start`, диплинки, приветствия), `Referral`,
  `Info` (`/chatid`, `/inspect`, `/history`), `Onboarding`, `Balance`,
  `Reminders`, `Ads`, `Admin` (whitelist/defaults/chats/users/presets),
  `Tenant`, `SuperAdmin` (`/superadmin`, `/simulate`, крипта, free-модели),
  `Buy`. См. §12.
- `Callbacks/` — `BotCallbackAction.swift` (типы callback_data: `stop`, `menu`,
  `faq`, `ex:<id>` — пример онбординга) и `BotCallbackHandler.swift` (роутинг
  нажатий кнопок).
- `Menu/` — inline-меню (§13). `MenuRoute.swift` — `MenuCommand` (команды
  диспетчера) + `MenuRoute` (разбор и сборка `callback_data`),
  `MenuScreen.swift` — `MenuScreen` (текст + клавиатура страницы, инвариант
  «влезает в одно сообщение») и `Keyboard` (накопитель рядов кнопок),
  `MenuPage.swift` — каталог страниц (+ `backLabel`: подпись кнопки «назад»
  живёт у страницы-назначения, а не у каждой кнопки; + `requiresFullAccess` /
  `requiresOperator` — гейты страниц тонкой настройки, §13),
  `SuperHelpSection.swift` — справка суперадмина по разделам,
  `BotMenuHandler+Guards.swift` — гейты ролей (`requireSuperAdmin` /
  `requireRootSuperAdmin` / `requireAdmin` / `requireOperator`: сами отвечают
  тостом при отказе) + `hasFullAccess`,
  `BotMenuHandler.swift` — обвязка, диспетчер callback'ов
  (`processAction` → девять групповых обработчиков), `showPage`/`renderPage`.
  Страницы и действия — по `BotMenuHandler+*.swift`: `MainPage`, `ChatSettings`
  (действия) + `ChatSettingsPages` (их рендеры),
  `Modes` (режимы: выбор режима юзером, страница «⚙️ Тонкая настройка» и
  супер-страница «🎛 Режимы бота» — §«Режимы»), `Purchase`, `Presets`, `Admin`,
  `Tenants` (тенанты, кошельки, суперадмины, симуляция, inspect — страницы и
  кнопки), `SuperAdmin` (диспетчер `super*`-действий + наценка, премиум-лимит,
  сама панель), `PaymentSettings` (Stars/карта/крипта/free-модели), `Retention`,
  `Onboarding`, `Referral`, `Growth` (воронка, реклама, источники), `Help`,
  `TextInput` (значения, набранные после кнопки: владелец → `switch` по
  `PendingKind` → применить), `AdminInput`
  (`AdminPendingInputKind` → семь групп по теме).
- `Texts.swift` — каталог пользовательских строк, встречающихся больше одного
  раза (отказы гейтов, подписи кнопок, «не найдено»). **Только литералы**: всё,
  что называет человека или чат, собирается на месте через
  `displayLabel`/`sanitizeName` (§17) — каталог не должен стать вторым,
  неэкранированным путём чужого текста в HTML-сообщение бота.
- `Formatting/ResponseFooterFormatter.swift` — футер под ответом (токены, стоимость
  ×markup, модель, остаток баланса).
- `Payments/` — `PaymentFulfillmentService.swift` (**что происходит после
  прихода денег — один раз на все способы**: дедуп, активация/зачисление,
  claim чата, winback, воронка, реферальный бонус, атрибуция `src_`, `flushNow`;
  §7/§17), `CryptoPaymentService.swift` (инвойсы, курсы, матчинг),
  `CryptoPaymentMonitor.swift` (поллинг блокчейнов),
  `ExternalPaymentService.swift` (внешняя касса: открыть счёт, подписать ссылку,
  разобрать уведомление вендора; §7 «Внешняя касса»).
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
  `StatePersistencePort`, `MediaResolverPort`, `LoggerPort`,
  `ExternalCheckoutPort` (+ `ExternalCheckoutResolver`: подписать ссылку,
  проверить уведомление — обе операции чистые, сети нет) + модели портов.

### Domain/
- `Chat/ChatContextStore.swift` — **сердце системы**, актор: хранилище состояния,
  dirty-наборы и boot-обвязка. См. §5. Логика разнесена по
  `ChatContextStore+*.swift` (все — расширения того же актора, поэтому поля
  `internal`, но за пределами этих файлов их никто не трогает):
  `Identity` (UserKey ↔ ник, `adoptRecords`), `Tenants`, `Subscriptions`
  (активация, цены, расписание напоминаний), `Auth` (роли + резолв доступа),
  `Presets`, `ChatContext` (память чата и её мутации), `Chats` (списки, мета,
  инвайты), `PendingInput` (единственный слот ожидания + его владелец),
  `Payments` (Stars/карта/крипта/курсоры), `ExternalPayments` (внешняя касса:
  реквизиты, цены, способы, счета),
  `Models` (что разрешено без оплаты + фолбэк), `Premium` (дневная порция),
  `Modes` (эталонные режимы + их применение к чату), `Analytics`
  (воронка + `src_`), `Onboarding`, `Referral`, `Balances`, `Ads`.
- `Chat/ChatContextTypes.swift` — value-типы стора: `TenantState`, `ChatContext`,
  `GenerationSnapshot`, `HelpData`, `TenantStatsRow`, `SimulatedRole`.
- `Chat/ChatContextStore+Persistence.swift` — экспорт/импорт строк (dirty-дренаж,
  restore), изоляция кода персистентности от основного актора.
- `Chat/BotStateSnapshot.swift` — `CumulativeUsage`, снапшот-DTO (`*Snapshot`),
  legacy-блоб для одноразовой миграции.
- `Chat/ChatMessageTypes.swift` — `ChatMessage`/`ChatMessageContent` (text | parts),
  мультимодальные части (image/audio/video), сборка user-сообщения.
- `Chat/ChatSessionTypes.swift` — `ChatKey` (chatID+threadID), `GenerationID`.
- `Chat/PresetTypes.swift` — `Preset`, `PresetCategory`, `PresetInput`
  (что правит редактор заготовок), `AdminPendingInput(Kind)`.
- `Chat/PendingRequest.swift` — **одно ожидание ввода на чат**: `PendingKind`
  (все виды «ждём текст»: пресет, цены Stars, крипта, free-модель, админские) и
  `PendingRequest` (владелец + меню-сообщение + вид). См. §13.
- `Chat/ChatMetaInfo.swift` — человекочитаемая идентичность чата + `InviteRecord`.
- `Chat/UserDirectory.swift` — **идентичность пользователя**: `UserKey`
  (стабильный ключ хранения), `UserIdentity`, `UserDirectory` (userID ↔
  @username + `rootKey`). См. §6 «Идентичность».
- `Chat/UserBalance.swift` — кошелёк pay-as-you-go + `ChatAccessStatus`.
- `Chat/AdCampaign.swift` — рекламная кампания (частота + пейсинг).
- `Chat/SubscriptionLifecycle.swift` — `SubscriptionReminderConfig` (расписание
  напоминаний/winback + чистое решение «что слать» — `dueNotice`),
  `SubscriptionNotice`, `SubscriptionDiscount`, `SubscriptionPricing`,
  `SubscriptionLifecycleStats`.
- `Chat/ModePreset.swift` — **режимы** (§«Режимы»): `ModeTier` (🆓 `free` /
  ⭐ `premium`; неизвестное значение декодится как `premium` — fail-closed),
  `ModePreset` (id, название, подпись, модель + пин сервиса, стиль, память,
  обдумывание, опциональная роль, тариф, вкл/выкл, счётчик тапов) и
  `ModePresetConfig` (вкл/выкл, список, `defaultModeID` — «рабочий режим»,
  границы и нормализация, `freeTierModelIDs`).
- `Chat/Onboarding.swift` — `OnboardingExample` (id, подпись кнопки, готовый
  запрос, вкл/выкл, счётчик тапов) и `OnboardingConfig` (вкл/выкл, показывать ли
  в группах, список примеров + границы и нормализация). См. §7 «Онбординг».
- `Chat/TrafficSource.swift` — атрибуция платного трафика (§7 «Источники»):
  `TrafficSourceLink` (диплинк `src_<метка>`, санитайз метки до `[a-z0-9_-]`),
  `TrafficSourceAttribution` (кто пришёл, откуда, дошёл ли до ответа и до
  оплаты), `TrafficSourceTally`/`TrafficSourceLedger` (агрегаты по кампаниям +
  прунинг), `TrafficSourceBindOutcome`, `TrafficSourceOverview`.
- `Chat/Referral.swift` — двусторонний реферал (§7 «Реферал»): `ReferralLink`
  (диплинк `ref_<userID>`, share-URL), `ReferralConfig` (вкл/выкл, награды обеим
  сторонам, лимит наград на человека), `ReferralRecord`/`ReferralTally`/
  `ReferralLedger` (журнал привязок + агрегаты + прунинг), `ReferralBindOutcome`,
  `ReferralPayout`, `ReferralUserStats`, `ReferralOverview`.
- `Chat/MediaTypes.swift`, `UserInputContent.swift` — медиа-рефы и вход юзера.
- `Providers/ProviderTypes.swift` — `ServiceProvider`, `ProviderCapabilities`,
  `StreamUsageSummary`/`StreamMeta`, `ProviderStreamEvent`, `GenerationOptions`,
  `ReasoningEffort`.
- `Payments/PurchasePurpose.swift` — `subscription | credit(cents:)`: к этим
  двум случаям сводится любой платёж, поэтому fulfilment общий (§17).
- `Payments/CryptoPayment.swift` — сети/активы/инвойсы крипты + форматтер сумм.
- `Payments/CardPayment.swift` — `FiatCurrency` (RUB/USD/EUR + парсер и рендер
  сумм в minor units) и конфиг карточного эквайринга.
- `Payments/ExternalPayment.swift` — внешняя касса (§7): `ExternalPaymentVendor`
  (вендор → адаптер, подписи, дефолтные способы), `ExternalPaymentMethod`
  (рельс на странице кассы: код вендора + название), `ExternalPaymentConfig`
  (реквизиты, валюта, цены, список способов; `credentials` — единственный вход
  в адаптер), `ExternalPaymentOrder`/`ExternalPaymentSnapshot`,
  `ExternalPaymentEndpoint` (`/payments/<vendor>`), `ExternalPaymentError`.

### Infrastructure/
- `Telegram/TelegramHTTPGateway.swift` — реализация `TelegramGatewayPort`: все
  вызовы Bot API (sendMessage/editMessage/sendMessageDraft/sendInvoice/
  answerPreCheckoutQuery/getFile/download/…), маппинг API-DTO → доменных моделей,
  ретрай 429, применение rate limiter'а.
- `Telegram/TelegramApiModels.swift` — сырые DTO Bot API.
- `Telegram/TelegramHTMLFormatter.swift` — санитизация/конвертация в Telegram HTML,
  три стадии по файлам: `+Tokenizer.swift` (`tokenize` — чтение: где кончается
  тег, тег ли это вообще, сущность ли это `&…;`), `+Sanitizer.swift` (`sanitize` —
  политика: выживает ли тег и с какими атрибутами; разбор атрибутов),
  головной файл (`render` — сборка со стеком открытых тегов + белый список схем
  `href` и экранирование значений атрибутов).
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
- `Payments/FreeKassaCheckoutAdapter.swift` — внешняя касса FreeKassa (SCI):
  подписанная ссылка `pay.fk.money` и проверка уведомления;
  `ExternalCheckoutRegistry.swift` — `vendor → адаптер` **исчерпывающим
  switch'ем** (новый вендор не соберётся без адаптера);
  `PaymentSignature.swift` — MD5-подпись (схема вендора, не наш выбор).
- `Networking/URLForm.swift` — `application/x-www-form-urlencoded` в обе
  стороны: касса говорит формами, а не JSON.
- `Logging/ConsoleLogger.swift` — `LoggerPort`, уровень из `LOG_LEVEL`.

> Файл `Infrastructure/Networking/HealthCheckServer.swift` **удалён** — заменён
> на `AppHTTPServer.swift`.

---

## 4. Жизненный цикл апдейта

```
Telegram
  │  (webhook POST /telegram/webhook  ИЛИ  long polling getUpdates)
  ▼
AppHTTPServer / runPollingLoop
  │  проверка secret-заголовка, 503 пока не ready / при draining
  ▼
UpdateIntake.enqueue([updates])
  │  дедуп по update_id (кольцевой буфер 2048) + склейка альбомов (holdback 750мс)
  ▼
BotOrchestrator.dispatch(update:)
  ├─ callback_query `ex:` → handleOnboardingExample (тап по примеру = обычный запрос:
  │                        учёт тапа, эхо запроса в чат, затем per-chat очередь)
  ├─ callback_query      → BotCallbackHandler (в обход per-chat очереди: stop должен прерывать)
  ├─ pre_checkout_query  → handlePreCheckoutQuery (цена: полная или winback-скидочная
  │                        → answerPreCheckoutQuery)
  ├─ my_chat_member      → handleMyChatMemberUpdate (вход в группу → отметка
  │                        присутствия, autoAssign на добавившего, funnel,
  │                        разовое приветствие; выход → пометка «бот удалён»;
  │                        личка → блок/разблок бота, приветствия нет)
  └─ message             → ChatUpdateDispatcher.submit(chatKey) { route(message) }
                              │  (сериализация per-chat, очередь ≤16)
                              ▼
                          BotOrchestrator.route(message:)
                            1. recordChatMeta (title/@username для админ-тулинга)
                            2. successful_payment? → handleSuccessfulPayment (идемпотентно)
                            3. /buy или /start (через `CommandParser`, не по префиксу)? → пропустить до access-gate
                               (`/start ref_<userID>` → привязка реферала, §7)
                            4. autoAssignIfNeeded (привязать чат к тенанту отправителя)
                            5. BotCommandHandler.handleIfCommand → true? стоп
                            6. BotMenuHandler.processTextInput → true? стоп (ждали ввод)
                            7. GenerationCoordinator.handleIfNeeded → LLM-ответ
```

Ключевое: **callback'и минуют per-chat очередь** — иначе кнопка «Стоп» не смогла
бы отменить генерацию, которая эту очередь и держит. Исключение — `ex:` (пример
онбординга): он **запускает** генерацию, поэтому идёт через ту же очередь, что и
обычное сообщение (порядок в чате не ломается).

**Вход в группу приходит дважды.** Ссылка `?startgroup=<payload>` заставляет
Telegram и прислать `my_chat_member`, и запостить в чат `/start <payload>`. Пути
разные (первый — вне очереди, второй — через неё), порядок не гарантирован,
поэтому оба зовут `ChatContextStore.claimGroupGreeting(chatID:)` — кто первый,
тот и здоровается (окно 10 мин, `_groupGreetedAt`, in-memory). `/start` в группе
никогда не шлёт личное приветствие — только групповое.

---

## 5. Доменное состояние: `ChatContextStore`

Актор — единственный владелец всего изменяемого состояния. Всё наружу отдаётся
через `async`-методы; внешний код никогда не трогает поля напрямую.

**Что хранит:**
- `contexts: [ChatKey: ChatContext]` — память каждого чата (по chatID+threadID).
- `tenants: [String: TenantState]` — тенанты (ключ = `UserKey`, §6).
- `chatOwnership: [Int: String]` — какой чат какому тенанту принадлежит (`UserKey`).
- `userTenantMap: [Int: String]` — userID → тенант (`UserKey`, для автопривязки).
- Глобальные конфиги: суперадмины, цена Stars, крипто-конфиг, карта, free-модели,
  processed payments, polling offset, метаданные чатов, инвайты, реклама, markup%,
  балансы пользователей, счётчики воронки (`funnelCounters` + подневные бакеты
  `funnelDailyValue`, §11), дневной премиум-лимит
  (`dailyPremiumLimitValue`, §7/§9) и израсходованные дневные порции
  (`premiumDailyUsage`, §9), настройки само-рекламы (`selfPromoConfigValue`, §7),
  расписание напоминаний/winback
  (`reminderConfigValue`, §7/§14), примеры онбординга + их тапы
  (`onboardingConfigValue`, §7 «Онбординг»), эталонные режимы
  (`modeConfigValue`, §7 «Режимы»), настройки реферала
  (`referralConfigValue`) и журнал привязок (`referralLedgerValue`, §7 «Реферал»).
- **In-memory без персиста** (сброс при рестарте некритичен): `_groupGreetedAt` —
  антидубль группового приветствия (§4); `_sponsorCreditShownAt` — троттлинг
  строки спонсора под ответами (§7). Дневной счётчик премиум-вкуса
  (`premiumDailyUsage`) раньше был здесь же — теперь **персистится** (§9):
  редеплой не должен раздавать всем новую порцию, это главный драйвер конверсии.
  Строка остаётся маленькой: записи прошлых суток прунятся при каждой записи и
  при restore.
- **Dirty-tracking**: `dirtyContexts`, `dirtyTenants`, `deletedTenants`,
  `dirtyOwnership`, `deletedOwnership`, `dirtyConfigs` (+ `deleted*`). Любая
  мутация помечает грязным — это то, что дренирует `PersistenceCoordinator`.

**`ChatContext`** (память одного чата): `role`, `history: [ChatMessage]`,
`pendingTurns`, `model` (+`modelProviderRouting`), `temp`, `maxHistory`,
`showStats`/`showCost`/`showModel`, `provider`, `suffix` (test-mode),
`reasoningEffort`, `backupNotify`, `cumulativeUsage`, per-chat пресеты, счётчики
рекламы, `funnelFirstMessageCounted` (флаг воронки: первое сообщение чата
засчитано), `downgradedFromModel` (платная модель, отложенная дневным лимитом —
возвращается сама, когда доступ появился; см. §9), `activeModeID` (в каком
эталонном режиме чат сейчас — сбрасывается любой ручной правкой настройки,
которой владеет режим, §7 «Режимы»).

**Кто платит за чат**: `chatAccessStatus(chatID:username:userID:)` →
`ChatAccessStatus` (`ownSubscription` / `sponsored(@X)` / `guest(@X)` / `balance`
/ `free`). Тот же порядок приоритетов, что у `hasSubscriptionCoverage`, но с
именем плательщика — меню и страница покупки благодарят спонсора вместо того,
чтобы продавать уже открытый доступ (§7 «Спонсор-герой»).

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

### Идентичность: `UserKey`, а не @username

Telegram-ник **арендуемый**: его меняют, освобождают, и его может занять другой
человек. Поэтому всё, что бот хранит про человека — кошелёк, подписка, лицензия,
роль суперадмина, владение чатами, крипто-инвойсы — лежит под `UserKey`:

- `#<userID>` — как только человек хоть раз попал боту на глаза (обычный случай);
- голый lowercase-ник — пока про человека только **рассказали**
  (`/tenant adduser @кто-то`, кого бот не видел). Такая запись «ждёт»: при первом
  же сообщении `identifyUser` переносит её под `#<userID>`.

Ник не может содержать `#`, поэтому две формы ключа не пересекаются.

**`UserDirectory`** (`bot_config` → `user_directory`) — переводчик между ключами и
никами: `identities` (userID → ник/имя/когда виделись), производный индекс
`byUsername` (перестраивается на декоде — один ник не может указывать на двоих) и
`rootKey` (ключ владельца бота, закрепляется при первой же встрече — иначе root
терялся бы при смене ника, которым бот сконфигурирован).

**`ChatContextStore.identifyUser(userID:username:firstName:)`** вызывается на
**каждом** апдейте (сообщение, callback, pre_checkout, `my_chat_member`). Он:
1. обновляет директорию;
2. `adoptRecords` — переносит всё, что лежало под ожидающим ником (тенант,
   кошелёк, владение чатами, `userTenantMap`, суперадминство, списки гостей и
   админов, инвайты, симуляция роли, крипто-инвойсы) на `#<userID>`. Если
   кошелёк есть под обоими ключами, они **складываются целиком** — включая
   `toppedUpUsd` (признак «платил реальные деньги», §7) и `lapsedNoticeAt`/
   `updatedAt` по максимуму: потерянный `toppedUpUsd` превратил бы клиента
   обратно в незнакомца, а потерянная отметка — послала бы второй оффер;
3. освежает денормализованные ники (`TenantState.ownerUsername`, журнал
   реферала) — списки показывают текущий ник;
4. прунит директорию (`maxIdentities` 10 000), **никогда** не выбрасывая тех, за
   кем что-то числится (`keysHoldingState`: тенанты, кошельки, владение чатами,
   суперадмины, инвайты, лицензии и админы тенантов, пригласившие из журнала
   реферала **и его агрегаты** (`tallies` живут дольше записей), владельцы
   открытых крипто-инвойсов, симуляция роли, `userTenantMap`).

**Когда директория попадает в базу.** Строка `user_directory` — одна на всех (до
10 000 записей), писать её на каждое сообщение нельзя. Поэтому `record` отдельно
сообщает, что сдвинулся `seenAt` (`seenAtAdvanced`, троттлинг
`UserDirectory.seenAtPersistInterval` = 15 мин; новый человек и смена ника пишутся
сразу). Без этого «когда виделись» жило бы только в памяти и на рестарте
откатывалось: возврат по балансу (§7) писал бы «давно вас не было» активному
человеку, а D1/D7 (§11) систематически занижались.

**API стора не менялось**: методы по-прежнему принимают `username: String`, а
внутри резолвят ключ (`userKey(username:)` / `userKeyOrRaw(_:)`). Ключ,
переданный в такой метод, проходит резолв **без изменений** — поэтому вызывающий
код может свободно передавать `#<userID>`, и это предпочтительно (кнопки меню,
платежи, инвайты так и делают).

> Round-trip ключа обязаны делать **оба** резолвера. `UserKey.pending` отвергает
> `#` — этим типизированный текст (`/tenant adduser`) не может подделать
> идентифицированный ключ. Но `userKey(username:)` строился только на нём, и
> `#<userID>` в нём превращался в nil: `isSuperAdmin`/`isAdmin`/`isTenantOwner`/
> `isRootSuperAdmin`/`simulatedRole`/`balance` молча отвечали «нет» **всем**, кто
> уже опознан, — а меню и команды передают туда именно ключ (`invokerKey`,
> `actorKey`). Проверка «ключ резолвится сам в себя» закреплена тестом (§19).

**В интерфейсе всегда ник.** Ключ наружу не показывается никогда: всё идёт через
`displayLabel(forKey:)` → `@ник` / имя / `id 12345`. Списочные методы отдают пары
`(key, label)` (`listSuperAdmins`, `listAdmins`, `licensedUsers`, `allBalances`,
`listTenants`), у строк-снимков есть поле `label` (`TenantStatsRow`,
`SubscriptionNoticeTarget`, `SubscriptionLifecycleStats.Row`), а `chatSponsor` и
`ChatAccessStatus` сразу возвращают готовую подпись.

**Следствие для пользователя: @username больше не нужен.** Оплата, кошелёк,
подписка, реферал и инвайты работают у человека вообще без ника — раньше это были
тупики («задайте @username, иначе доступ не включится»). Резолв доступа
(`hasSubscriptionCoverage`, `chatAccessStatus`, `hasFullModelAccess`,
`billingKey`) идёт по списку кандидатов `userKeys(username:userID:)`, где userID
первичен.


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
создаёт тенанта при первой оплате. Истёкший тенант сохраняет админ-панель
(в UI — «⚡ Мой премиум», чтобы продлить), но его чаты/юзеры откатываются на
бесплатные модели.

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
  - **Курсоры сканирования персистятся** (`CryptoConfigSnapshot.explorerCursors`,
    ключ `"<asset>:<address>"`, unix-секунды): курсор, засеянный «сейчас» на
    старте процесса, прятал бы каждый перевод, пришедший во время редеплоя —
    деньги получены, инвойс протух, в логах пусто, а повторной доставки у
    блокчейна (в отличие от Telegram) нет. Адрес без сохранённого курсора
    сканируется **на 45 минут назад** (жизнь инвойса + запас); повторный скан
    безопасен — дедуп по `creditedTxHashes`. Курсор двигается **после** зачисления
    всей пачки (`advanceExplorerCursor`, только вперёд), иначе краш между записью
    курсора и кредитом теряет платёж навсегда. Мёртвые ключи чистит
    `pruneExplorerCursors` по списку опрашиваемых адресов.
  - **Слоты `amountDelta` не переиспользуются молча**: если свободного слота нет,
    `createOrRefreshInvoice` бросает `CryptoPaymentError.slotsExhausted` (как
    `poolExhausted` в режиме `uniqueAddress`). Прежний тихий откат на слот 0 давал
    двум инвойсам одинаковую `exactAmountAtomic` — платёж одного закрывал подписку
    другого. Тексты `CryptoPaymentError` идут пользователю как есть
    (`UserFacingError` их не заворачивает).

- **🏦 Внешняя касса** (`ExternalPaymentConfig`, `Domain/Payments/ExternalPayment.swift`)
  — сторонний агрегатор держит платёжную страницу, и одна интеграция закрывает
  то, чего нет ни в Telegram Payments (нужен провайдер и юрлицо), ни в голом
  крипто-адресе: **Сбербанк Онлайн, СБП, карты РФ и зарубежные, крипта**.
  Первый вендор — FreeKassa (SCI): бот подписывает ссылку секретным словом 1,
  касса шлёт уведомление, подписанное словом 2, на `/payments/freekassa`
  (§11), бот отвечает `YES` — иначе касса повторяет доставку.
  - **Всё настраивается из бота** (страница «🏦 Внешняя касса», §13): ID
    магазина, оба секретных слова, валюта, цена подписки, курс пополнений и
    **список способов оплаты** (`код | название`, где код — ID платёжной
    системы вендора). Набор рельсов — данные, а не релиз: агрегаторы заводят и
    закрывают способы постоянно. Пустой список = покупатель выбирает на
    странице кассы. Кнопка «↺ Стандартные» заполняет набор вендора.
  - **Порог включения — реквизиты целиком**: `credentials` возвращает тройку
    или nil, поэтому наполовину настроенный магазин не может выдать ссылку,
    которая упадёт на стороне кассы с непонятной покупателю ошибкой.
    Выключатель отдельно от реквизитов — выключить на день не значит идти в
    кабинет за секретами заново.
  - **Счёт живёт час и оплачивается один раз**: повторный тап «оплатить»
    переиспользует открытый счёт (два живых счёта на одну покупку — это два
    возможных платежа), а повторное уведомление ничего не начисляет
    (`markExternalOrderPaid` + дедуп по `ext:<vendor>:<paymentID>`).
    Недоплата не включает доступ: в чат уходит номер счёта, чтобы разобрались
    руками.
  - **Подпись — единственная аутентификация публичного эндпоинта**, поэтому
    сравнение константное (`SecretGuard`), отсутствующая подпись = неверная, а
    неподписанный POST получает 400 и ничего больше. Секретные слова
    регистрируются в `SecretRedactor` в момент ввода (§15).
  - Цена подписки идёт через `subscriptionPricing(username:)`
    (`externalMinorUnits`), поэтому winback-скидка показана и списана одна и та
    же; пакеты кредитов — через свой курс (`usdRateMinorUnits`), независимо от
    цены подписки.

Идемпотентность: `successful_payment` дедуплицируется по
`telegram_payment_charge_id` (`processedPaymentChargeIDs`), крипта — по хешам
транзакций (`creditedTxHashes`). Платежи всегда `flushNow()` — durability без
ожидания debounce; у крипты координатор персистентности прокинут в
`CryptoPaymentService` (`applyMatch` флашит после всех мутаций и **до**
уведомлений, включая частичную оплату — накопитель тоже реальные деньги).

**Pay-as-you-go балансы** (`UserBalance`, `userBalances`): альтернатива подписке.
Пользователь с положительным балансом платит за каждое сообщение по marked-up
цене. `spentRealUsd` (реальная стоимость провайдера) хранится рядом с
`spentBilledUsd` → суперадмин видит маржу. `hasFullModelAccess` = подписка ИЛИ
положительный баланс.

**Кредиты / самостоятельное пополнение** (`CreditPack`, низкий порог первой
оплаты): любой юзер покупает пакет ($2/$5/$10) через **Stars, крипту или карту**
на странице покупки и в `/buy`. Инвойс с payload `credits_<центы>`;
`handleSuccessfulPayment` по этому префиксу зачисляет номинал на баланс
(`creditBalance`), а не активирует подписку. `pre_checkout_query` проверяет
credit-payload по живому курсу (Stars — `starsForCents`, карта —
`CardPaymentConfig.creditMinorUnits`). Идемпотентность — по charge_id, как у
подписок.

- **Пакеты не зависят от цен подписки.** У каждого способа свой выключатель:
  Stars — `starsPerUsd` (0 = не продавать; `starsCreditsEnabled`), крипта —
  адреса, карта — `usdRateMinorUnits` (курс «сколько валюты за $1»,
  «💱 Курс пополнений» на странице карты; 0 = выключено, `creditsEnabled`).
  Раньше пакеты исчезали вместе с выключенной подпиской — это убивало самый
  дешёвый вход. Пакет в валюте карты не опускается ниже минимума валюты.
- Номинал пакета = сумма на балансе (маржа берётся при списании, §«Наценка»);
  курс должен покрывать комиссию платёжного метода.

**Наценка** (`markupPercentValue`, дефолт 30%): `priceMultiplier() = 1 + %/100`.
**Все** видимые пользователю цены и списания идут через этот множитель
(`billedCost`, футер, `chargeBalance`). Настраивается суперадмином (0–500%).

**Спонсор-герой**: снимает проблему «безбилетника» — тот, кто платит за всех,
получает публичный статус.

- **Под ответами** в группе, покрытой чужой подпиской: `⚡ премиум для чата открыл
  @{sponsor}` (`chatSponsorForCredit` → `sponsorCreditLine`; только группы, не сам
  спонсор). Троттлинг — **не чаще раза в час на чат** (`sponsorCreditCooldown`,
  in-memory): под каждым ответом строка превращается в шум.
- **В меню и на странице покупки** — `ChatAccessStatus` (§5): «⚡ Премиум для чата
  открыл @X — спасибо!». На странице покупки покрытому участнику не продают то,
  что у него уже есть: оффер переписывается на «своя подписка нужна для лички и
  ваших чатов».
- **В приветствии группы** — если бота добавил действующий спонсор, чат сразу
  привязывается к его подписке (`autoAssignIfNeeded` в `handleMyChatMemberUpdate`)
  и приветствие благодарит, а не продаёт.
- **При оплате**, открывшей чат, в чат летит публичное поздравление.
- **Оплата не отбирает чужой чат.** Платёж привязывает чат через
  `claimChatForPayment(chatID:payerKey:)`, а не через `assignChat`: группа,
  которую уже оплачивает **активная** подписка другого человека, остаётся за ним
  (`ChatClaimOutcome.keptSponsor`), а покупателю приходит «премиум активирован
  для вас — в личке и ваших чатах; здесь премиум уже открыл @A». Иначе участник,
  купивший себе подписку в чужой группе, молча уносил чат из `ownedGroupChatIDs`
  спонсора — из его списка чатов, из напоминаний и из строки «премиум открыл @A»,
  хотя платит по-прежнему спонсор. Личка покупателя (`chatID > 0`) всегда следует
  за ним. Ручная привязка (`/tenant claim`, кнопки меню, `/simulate buy`) —
  по-прежнему `assignChat`, она осознанная.

**Дневной премиум-вкус** free-tier: см. §9 (гейт генерации) — `consumeDailyPremium`.
Дневной лимит настраивается суперадмином (`setDailyPremiumLimit`, кнопка
«🎁 Премиум-лимит/день» в супер-меню; 0 = премиум-вкус выключен). Остаток на
сегодня видно в шапке `/menu` («умных ответов сегодня осталось · N из M») —
счётчик, который убывает на глазах, и есть механика; статичное «5 в день» никому
ничего не говорит.

**Режимы** (`ModePreset`/`ModePresetConfig`, `Domain/Chat/ModePreset.swift`) —
эталонные связки настроек, которые задаёт **суперадмин**: один тап меняет модель,
стиль ответа, память, обдумывание и (по желанию) роль. Пользователь выбирает
«🧠 Умный», а не «temperature 0.7 и reasoning=medium»: продать можно результат,
а не поле формы.

- **Тариф режима** — `ModeTier`: 🆓 (доступен всем) или ⭐ (нужен премиум, баланс
  или дневная порция). ⭐-режимы **видны бесплатным всегда** — это и есть витрина
  платного: потолок, которого не видно, никто не платит снимать (GROWTH.md §1).
  Тап по ⭐ без доступа не отвечает тостом, а **открывает страницу покупки**
  (`PurchaseSource.mode`) и считает `funnel(.capHit)`; с непотраченной дневной
  порцией — применяется и называет остаток.
- **🆓-режим расширяет бесплатный доступ**: его модель автоматически попадает в
  `allowedFreeModelIDs()` (§9), даже если она платная. Так владелец покупает
  приличное первое впечатление вместо мусорной бесплатной модели — расход его, и
  цена модели поэтому напечатана прямо под режимом на супер-странице.
- **Рабочий режим** (`defaultModeID`, 🎯): к нему ведут кнопка «↺ Рабочий режим»
  (на главной и на странице модели, показывается только когда чат с него ушёл) и
  «↺ Сбросить»; его модель — первый кандидат в `fallbackFreeModel()`. Бесплатные
  модели действительно плохи, и выход из них обязан быть в один тап.
- **`activeModeID`** на чате даёт ✓ у активного режима; любая ручная правка
  модели/стиля/памяти/обдумывания его снимает, и шапка честно пишет «изменён
  вручную». Повторный выбор того же режима **не чистит переписку** (модель не
  сменилась).
- **Тонкая настройка** (`MenuPage.tuning`) — те же настройки по отдельности.
  Страница открывается всем (закрытая дверь, в которую видно, продаёт; наглухо
  запертая — раздражает), но `🌡 Стиль ответа` и `🧠 Обдумывание` помечены ⭐ и
  ведут на покупку (`MenuPage.requiresFullAccess`, `PurchaseSource.tuning`).
  `📝 Память` и `🔌 Сервис ИИ` — только оператору (`requiresOperator`): память
  переотправляется на каждом ходу и множит стоимость каждого ответа, сервис молча
  решает, какие модели и какое обдумывание вообще доступны.
- **Правится целиком из супер-меню** («🎛 Режимы бота», `MenuPage.superModes`):
  тексты, модель, стиль, память, обдумывание, роль, тариф, порядок, рабочий режим,
  вкл/выкл + счётчик тапов на каждом. Формат ввода —
  `Название | Подпись | модель | стиль | память | обдумывание`; модель `-` =
  «любая бесплатная» (резолвится в `fallbackFreeModel()` на применении, поэтому
  режим переживает смену каталога), `id@сервис` — пин апстрима. Тариф и роль
  правятся кнопками, не текстом: перенабирать их при каждой правке формулировки —
  верный способ молча уронить тариф в 🆓.
- **Новый режим создаётся с тарифом ⭐.** Режим, добавленный по ошибке, не должен
  раздать самую дорогую модель всем бесплатным до того, как кто-нибудь заметит.
- Хранение — одна строка `bot_config` (`GlobalConfigKey.modes`), конфиг
  **глобальный**, не тенант-скоуп: это настройки, за которые ручается владелец
  бота, а не то, что переопределяет каждый купивший подписку.

**Напоминания и winback** (`SubscriptionReminderService`, §14): фоновый свип
сравнивает `paidUntil` с now и шлёт спонсору по одному сообщению на каждую волну
за срок подписки: до конца — напоминания продлить (`expiryReminderDays`, дефолт
за 3 дня и за 1 день), после истечения — winback-волны (`winbackDays`, дефолт +1 и
+7 дней) с **срочной скидкой** (`SubscriptionDiscount`, дефолт −30% на 48 ч). Всё
расписание — `SubscriptionReminderConfig` в `bot_config`
(`GlobalConfigKey.reminders`): вкл/выкл, дни до конца, дни winback, процент и срок
скидки, интервал свипа, уведомлять ли чаты спонсора. Правится в супер-меню
(«⏳ Напоминания и winback») и командой `/reminders`, без передеплоя.

- **Волны до истечения** (`expiryReminderDays`, до 3 шт., дни 1–30): `dueNotice`
  берёт **ближайшую** волну, чей срок наступил — «завтра» перебивает «за три дня»,
  а пропущенная во время даунтайма волна не отправляется задним числом. Ключ
  дедупа — `expiring<N>`; цикл, отмеченный старым однопоточным билдом (ключ
  `expiring`), считается уже получившим самую широкую волну, поэтому апгрейд не
  шлёт повтор. `daysBeforeExpiry` осталось как вычисляемый максимум (горизонт
  «скоро истекут»). Публично в чаты уходит только самая широкая волна.
- **Дедуп**: `noticeCycleUntil` + `sentNotices` на тенанте; отметка ставится только
  после успешной доставки (иначе ретрай на следующем свипе, ограниченный окном
  волны). Продление меняет `paidUntil` → набор отметок сбрасывается.
- **Скидка** применяется ко всем способам оплаты через **единый источник цен**
  `subscriptionPricing(username:)` (Stars / крипта / карта; карта не опускается ниже
  минимума валюты). `pre_checkout_query` принимает и полную, и скидочную цену
  (grace 1 ч — инвойс, открытый на границе срока). Покупка «съедает» скидку
  (`consumeWinbackDiscount`) и считает `funnel(.winbackRedeemed)`.
  Параметр `applying:` подставляет **гипотетическую** скидку, ничего не выдавая —
  на нём построен предпросмотр, поэтому в нём честны и карта, и крипта.
  **Выдаётся один раз на окно**: `grantWinbackDiscount` возвращает уже живую
  скидку вместо новой (свип выдаёт её до отправки, и transient-ошибка иначе
  двигала бы 48-часовой дедлайн вперёд на каждом проходе). Если ни один канал не
  дожил до отправки, скидка снимается — оффер, которого человек не видел, не ждёт
  его на кассе.
- **Каналы**: личка спонсора (если он писал боту и **не заблокировал** бота) и —
  опционально (`notifyChats`) — его группы (продлить может любой участник; не
  более 10 чатов на волну, публично только первая winback-волна). Нет ни одного
  канала → отметка ставится, счётчик «недоступны» растёт (видно суперадмину).
  Отправка, упавшая с 403 (заблокировали/выгнали) или «chat not found», помечает
  чат мёртвым (`setBotPresence(isMember:false)`) — следующий свип его уже не
  увидит; транзиентные ошибки по-прежнему ретраятся.
- **Цена в групповом сообщении — прайс-лист**, а не персональная скидка спонсора:
  тапнуть «Продлить» там может любой участник, и он будет платить полную цену.
- Суперадмины из свипа и из страницы мониторинга исключены — владельцу бота не
  продают его же продукт.

**Возврат по балансу** (`walletWinbackDays`, дефолт 7 дней; вторая половина того
же свипа, §14): подписка истекает громко и получает winback, а pay-as-you-go
баланс просто заканчивается — человек тихо уходит, и об этом ничего не говорит.

- **Аудитория узкая намеренно**: только те, у кого `UserBalance.toppedUpUsd > 0`
  (реальная оплата пакета, **не** реферальный бонус и не начисление суперадмина),
  баланс ≈ 0, нет активной подписки, тишина ≥ N дней (`UserDirectory.seenAt`), не
  суперадмин, не заблокировали бота и не отписались. Всем остальным оффер и так прилетает в
  момент боли (пустой баланс, дневной лимит) — рассылка бесплатным покупает
  только блокировки.
- **Один раз на цикл**: `UserBalance.lapsedNoticeAt` ставится после успешной
  доставки; **пополнение сбрасывает отметку** (`creditPurchasedBalance`) — вернулся
  и снова ушёл = новый цикл. Мёртвая личка (403) отмечается и закрывается как
  «недоступен», а не ретраится.
- Событие воронки `walletWinbackSent`; строка состояния (платили / готовы к
  отправке / уже написали) — на странице «⏳ Напоминания и winback», ручка —
  кнопка «💰 Возврат по балансу» и `/reminders wallet <дней>`.
- **Контроль у спонсора**: кнопка «🔔 Напоминания о продлении» в его админ-панели
  («⚡ Мой премиум») (`remindersOptOut`) + строка с датой ближайшего напоминания и
  активной скидкой.

**Вирусный рост** (роадмап шаг 4): кнопка «➕ Добавить в свой чат»
(`t.me/<bot>?startgroup=add`) в `/start` и в меню; вход в группу ловится через
`my_chat_member`.

- Приветствие группы — одно на вход, через `GroupWelcomePresenter` (см. §4 про
  двойную доставку и `claimGroupGreeting`).
- **Удаление бота из группы** (`my_chat_member` → left/kicked) помечается в
  `ChatMetaInfo.botRemoved` (персистится в `chat_meta`). Лицензия и история чата
  сохраняются (вернут бота — всё на месте), но чат перестаёт быть каналом
  доставки: `ownedGroupChatIDs` его не отдаёт, поэтому напоминания и winback
  (§«Напоминания») не тратят отправки на мёртвые чаты. Флаг снимается сам при
  повторном входе или при первом же сообщении из чата (`recordChatMeta`).
- Воронка: `.start` считается **только в личке** — группа, доехавшая до `/start`,
  это replay `?startgroup=`, и он уже учтён как `.addedToGroup`.

**Реклама** (`AdCampaign`): показывается только во free-tier чатах (нет подписки
и нет баланса). Два дросселя: частота (раз в N ответов + мин. интервал) и пейсинг
(равномерное распределение показов по времени кампании). `nextAdToShow` атомарно
решает, считает показ и ротирует кампании (least-shown first). Когда нет активной
кампании суперадмина, слот заполняет встроенный **само-оффер** — реклама продаёт
сам премиум.

- Само-оффер настраивается целиком: `SelfPromoConfig` (`bot_config` →
  `self_promo`) — вкл/выкл, текст, частота, пауза и счётчик показов. Кампания
  (`AdCampaign.selfPromo(config)`) остаётся синтетической, персистится только
  конфиг. Правится на странице «📣 Реклама» и командой `/ads promo`
  (`on|off|text|freq|reset`).
- Под текстом бот сам рисует кнопку **«⚡ Открыть премиум»** (в личке — плюс
  «🎁 Пригласить друга»): оффер, который заканчивается на «напишите /buy», теряет
  всех, кто не готов печатать. Тап помечен источником `promo` (§11).
- Показы считаются: `impressions` в конфиге + событие воронки `promoShown`.
  Страница «📣 Реклама» показывает состояние слота (🟢 показывается / 🟡 занят
  платной кампанией / ⚪ выключена), частоту, паузу, счётчик и сам текст.

**Онбординг с примерами** (`OnboardingConfig`/`OnboardingExample`, роадмап шаг 9):
пустой чат после `/start` — главная точка отвала, поэтому приветствие несёт
кнопки-примеры (`✍️ Написать пост`, `💡 Объяснить простыми словами`, `🌍 Перевести`).

- **Тап = обычный запрос**: `callback_data` = `ex:<id>` → `handleOnboardingExample`
  считает тап, шлёт эхо запроса в чат (`<blockquote>`, Telegram не умеет писать «от
  имени юзера») и ставит генерацию в **per-chat очередь** через
  `GenerationCoordinator.runReadyPrompt` c синтетическим `GenerationOrigin`.
  Обходится только `MessageRoutingPolicy` (тап и есть явное обращение); дневной
  лимит, биллинг, реклама, история и футер работают как для набранного текста.
  В **группе** эхо подписано тем, кто тапнул (`tapEcho(example:asker:)`) — иначе
  вопрос из ниоткуда и ответ на него читаются как разговор бота с самим собой.
  Callback сразу отвечает тостом: кнопка, которая «ничего не делает», тапается ещё раз.
- **Где показывается**: приветствие `/start`, приветствие при входе в группу
  (`showInGroups`; тап активирует весь чат сразу), кнопка «💡 Примеры-запросы» в
  главном меню и команда `/examples` (приветствие быстро уезжает вверх).
- **Размещение примера** (`OnboardingPlacement`: `everywhere` / `privateOnly` /
  `groupsOnly`) — личка и общий чат просят разного: `activeExamples(inGroup:)`
  фильтрует набор под комнату, `OnboardingPresenter.exampleRows(_:inGroup:)`
  рендерит только подходящие. Кнопка «📍» на странице супер-меню циклит значение.
  Неизвестное значение поля декодится как `everywhere` (через сырую строку) —
  чужой билд не должен уносить весь конфиг вместе с текстами и счётчиками.
- **Ничего не захардкожено**: набор, тексты, порядок, размещение и вкл/выкл
  каждого примера правятся суперадмином на странице «💡 Примеры-запросы»
  (`superonboarding`) или командой `/examples`; лежит в `bot_config`
  (`GlobalConfigKey.onboarding`), границы (`maxExamples` 6, длина подписи/запроса)
  нормализуются на set и на decode. Предпросмотр показывает набор **той комнаты**,
  где его открыли. Есть «↺ Стандартные».
- **Мониторинг**: счётчик тапов на каждом примере (персистится) + доля от всех
  тапов на странице; воронка `onboardingShown` → `exampleTapped` (вовлечение) в
  «📊 Воронка», `/metrics` и `/examples stats`.
- Изменение текста примера сохраняет его `id` и счётчик тапов — уже отправленные
  приветствия продолжают работать, статистика не обнуляется.

**Двусторонний реферал** (`Domain/Chat/Referral.swift`, роадмап шаг 10): у каждого
пользователя есть личная ссылка `t.me/<bot>?start=ref_<userID>` (userID, а не
@username — не ломается при смене ника). Друг переходит, пишет первый вопрос — и
**обе стороны** получают бонус на pay-as-you-go баланс (дефолт $1 + $1).

- **Две фазы**: `/start ref_<id>` → `bindReferral` (только привязка, деньги не
  платятся) → первый реальный ответ → `redeemReferralIfDue` в
  `GenerationCoordinator.processContent` (кредит обоим кошелькам + уведомления
  обеим сторонам). Награда сразу даёт «премиум по факту»: положительный баланс =
  `hasFullModelAccess`, поэтому тот же первый ответ уже идёт на платной модели.
  Ответ засчитывается **в любом чате** (друг, сразу ушедший в группу, сделал ровно
  то, чего мы хотели), но **оба уведомления уходят в личку**: награда личная, а
  «вас пригласил @X» в общем чате рассказывает то, чего человек не выбирал.
- **Третья фаза — бонус за конверсию** (`payingFriendBonusCents`, дефолт $2):
  когда приглашённый **впервые платит** (подписка или пакет, любым способом),
  пригласившему разово капает бонус — `redeemReferralPaymentBonus` зовётся из
  `handleSuccessfulPayment` (Stars/карта) и из `CryptoPaymentService.applyMatch`,
  до `flushNow`, так что бонус durable вместе с платежом. Идемпотентность —
  `ReferralRecord.paidBonusAt`. Награда за регистрацию покупает регистрации, эта —
  клиентов, поэтому **антифрод-лимит на неё не действует**: деньги уже пришли.
  `ReferralTally.paidConversions` — главное число программы (окупается ли она) и
  первый ключ сортировки топа пригласивших.
- **Антифрод** (всё в сторе, одна актор-транзакция): самоприглашение отклоняется
  (по userID и по username); одна привязка на человека **навсегда**
  (`records[invitedUserID]`); награда только «новому» — у кого нет личного чата с
  оборотом, кошелька, лицензии (`hasPriorBotActivity`); деньги — только после
  первого реального ответа (пустая ферма аккаунтов не окупается); лимит
  оплаченных приглашений на одного пригласившего (`maxRewardsPerInviter`, дефолт
  20; сверх — привязка есть, выплаты нет, счётчик «отклонено лимитом» растёт).
- **Лимит проговаривается заранее**: `bindReferral` проверяет тэлли пригласившего
  и при исчерпанном лимите возвращает `.boundWithoutReward` — приглашение
  засчитывается, но другу **не обещают** денег, которых он не получит (лимит
  перепроверяется на выплате, так что поднятие лимита оплатит зависшую пару).
  На своей странице `/ref` пригласивший тоже видит «бонусы исчерпаны».
- **Кошельки по userID**: @username не нужен ни одной из сторон (см. §6) —
  `.unknownInviter` означает только «автор ссылки боту ни разу не писал».
  Ники в журнале денормализованы и освежаются на выплате; в уведомлении друг
  называется через `invitedLabel` (`@ник` / имя / `id N`).
- **Идемпотентность/durability**: `rewardedAt` ставится в том же шаге актора, что
  и кредит балансов, поэтому повторные сообщения/рестарт не платят дважды; при
  потере флаша теряются обе записи разом (баланс и отметка) — пара просто снова
  становится pending и оплатится на следующем сообщении. Отдельный `flushNow()`
  не нужен (в отличие от платежей).
- **Хранение**: `ReferralLedger` = привязки + агрегаты по пригласившим +
  накопленный расход + счётчики отказов, одна строка `bot_config`
  (`GlobalConfigKey.referralLedger`); прунятся только **разрешённые** записи
  (pending не трогаются), агрегаты живут дольше записей, поэтому ни лимит наград,
  ни счётчик приведённых клиентов нельзя обнулить переполнением журнала.
  У `ReferralRecord` и `ReferralTally` **рукописные `init(from:)`**: поля,
  добавленные позже, читаются как опциональные — иначе одна старая запись роняет
  декод всей строки и разом забываются все привязки.
- **Отказы считаются** (`refusedSelf` / `refusedRepeat` / `refusedNotNew` /
  `refusedUnknown`): без них «ссылку никто не открывает» неотличимо от «открывают,
  но правила всех отсеивают» — а это разные проблемы с разными решениями. Видно на
  странице «🎁 Приглашения» и в `/ref stats`.
- **Где показывается**: кнопка «🎁 Пригласить друга» в главном меню (только личка),
  блок на странице покупки, третья кнопка в оффере при исчерпании дневного лимита
  (бесплатный способ снять лимит), команда `/ref`, страница меню `ref` (ссылка,
  «📤 Поделиться» — текст шаринга называет сумму бонуса друга, личная статистика:
  приглашено / с наградой / ждут / заработано / остаток лимита).
- **Контроль и мониторинг у суперадмина**: страница «🎁 Приглашения»
  (`superref`) — вкл/выкл, награды каждой стороне, лимит, счётчики
  (привязки / выплачено пар / ждут / отклонено лимитом / выплачено $ / пригласивших
  / **друзья, которые оплатили** + разбивка незасчитанных переходов), топ
  пригласивших, очистка журнала (с подтверждением); те же ручки командой
  `/ref on|off|reward|friend|bonus|cap|stats`. Воронка:
  `referralJoined → referralRewarded → referralPaidBonus` в «📊 Воронка» и
  `/metrics` (+ `referral_pending`, `referral_rewarded`, `referral_paid_cents`,
  `referral_conversions`).

**Источники трафика** (`Domain/Chat/TrafficSource.swift`): ссылка
`t.me/<bot>?start=src_<метка>` в рекламном объявлении помечает, из какого канала
пришёл человек. Без этого CAC (потрачено ÷ платящих) считается только «в целом»,
и бюджет уходит в канал, который *кажется* рабочим — самая дорогая ошибка из
`LAUNCH_ECONOMICS.md`.

- **Три числа на кампанию**: `joined` (привязок) → `activated` (дошли до первого
  реального ответа) → `payers` (оплатили хоть раз, знаменатель CAC) + `payments`
  (все оплаты, включая повторные). Активация считается в
  `GenerationCoordinator.processContent` рядом с реферальной выплатой, а не на
  `/start`: клик, не давший ни одного ответа, — не активация.
- **First touch wins**: повторный переход по чужой метке не переписывает
  привязку (`repeatOpens`), иначе канал присваивал бы клиента, за которого
  заплатил другой. Тот, кто уже пользовался ботом (`hasPriorBotActivity`), в
  `joined` не попадает вообще (`knownUserOpens`) — иначе CAC выглядел бы лучше,
  чем есть. Оба счётчика видны на странице: «рекламу никто не открывает» и
  «открывают, но это уже наши люди» — разные проблемы.
- **Молчит по определению**: `src_` ничего не выдаёт и ни о чём не сообщает,
  приветствие выглядит как обычное. В отличие от `inv_` (лицензия) и `ref_`
  (бонус), метка только помечает происхождение.
- **Оплата засчитывается на всех путях**: `handleSuccessfulPayment` (обе ветки —
  подписка и пакет) и `CryptoPaymentService.applyMatch`, до `flushNow` — рядом с
  реферальным бонусом за конверсию, чтобы атрибуция была durable вместе с
  платежом.
- **Хранение**: одна строка `bot_config` (`GlobalConfigKey.trafficSources`);
  метка санитайзится до `[a-z0-9_-]` (до 32 символов) — она уходит и в ключ JSON,
  и в HTML; число кампаний ограничено (`maxTags` 200, сверх — бакет `other`),
  привязки прунятся по возрасту, агрегаты живут дольше привязок.
- **Мониторинг**: страница супер-меню «📈 Источники» (`supersrc`) — кампании,
  отсортированные по платящим, конверсия, готовый шаблон ссылки, очистка с
  подтверждением; строка-сводка на странице «🛡 Супер-админ» и кнопка со
  страницы «📊 Воронка».

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

**Ошибка внутри потока — это ошибка, а не пустой ответ.** OpenAI-совместимые
провайдеры отдают отказ прямо в SSE с HTTP 200
(`{"error":{"code":429,"message":"rate limited"}}` — лимит, кончившийся баланс
у провайдера, модерация, «no endpoints found»). Такой payload не парсится ни как
usage, ни как delta, поэтому раньше молча игнорировался: поток заканчивался,
аккумулятор пустой, пользователь видел «Пустой ответ.» с футером, а причина не
доходила даже до логов. Теперь оба адаптера декодят поле `error`
(`ProviderStreamErrorPayload`, код читается и числом, и строкой) и завершают
поток `ProviderAdapterError.upstream(provider:code:message:)`. Наружу идёт
русский текст по коду (`UserFacingError` → `httpStatusReason`), английский
оригинал остаётся в логах (`stream failed: …`). Ход при этом не списывается:
`cancelPendingTurn` + `refundDailyPremium` отрабатывают как на любой ошибке.

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
   **Порция возвращается**, если ход не дал ответа (ошибка провайдера, «Стоп»,
   пустой ответ): `refundDailyPremium` зовётся везде, где зовётся
   `cancelPendingTurn` — у бесплатного юзера этих ответов 5, потерять один на
   ошибке нельзя. **Последняя порция** проговаривается вслух
   (`sendLastPremiumCallNotice`, событие `capWarned`, максимум раз в сутки):
   дефицит виден до стены, а не после. При `limit = 0` оффер не говорит «0 из 0» —
   там другой текст («умные модели доступны с премиумом»).
   **Откат модели обратим**: переключение идёт через `downgradeModelToFree`, которая
   запоминает платную модель в `ChatContext.downgradedFromModel` (персистится). Как
   только у спрашивающего появился полный доступ (подписка, спонсор, реферал или
   пополнение), `restoreDowngradedModel` возвращает её и сообщает об этом в чат —
   иначе оплата выглядела бы как «ничего не изменилось»: чат так и отвечал бы на
   бесплатной модели, пока кто-нибудь не залезет в меню. Явный выбор модели
   (`setModelAndResetHistory`/`setModelOnly`) отметку снимает.
   **Новые сутки тоже возвращают модель** — молча, до входа в гейт: если у
   спрашивающего есть остаток дневной порции (`remainingDailyPremium > 0`), а
   модель чата припаркована, `restoreDowngradedModel` зовётся без сообщения в
   чат. Без этого механика умирает после первого же исчерпания: гейт срабатывает
   только пока модель чата платная, а после отката она бесплатная — и
   `consumeDailyPremium` не вызывается больше никогда.
   **Платную модель можно выбрать и вручную**, пока порция есть:
   `paidModelAccess(username:userID:chatID:)` (`.full` / `.dailyTaste` / `.none`)
   — единый гейт пикеров (`/model`, меню `select`/`gsel`/`csel`). Иначе вкус
   премиума доступен только тем чатам, у кого платная модель была выставлена до
   отката, и записаться в него невозможно. При выборе на дневную порцию
   пользователю сразу называется остаток (`dailyTasteToastSuffix` в меню,
   строка «🚦 Умных ответов сегодня» в `/model`) — иначе откат в середине дня
   читается как поломка.
   **Что вообще считается бесплатным — `allowedFreeModelIDs()`**, а не
   `effectiveFreeModelIDs()`: это ноль-стоимостный каталог (пины суперадмина ∪
   бесплатные OpenRouter) **плюс модели 🆓-режимов** (§7 «Режимы»). Единственный
   ответ на вопрос «можно ли без оплаты» — его обязаны спрашивать все гейты:
   генерация, `/model`, кнопки пикера и ручной ввод ID. Фолбэк —
   `fallbackFreeModel()`: модель рабочего 🆓-режима → первая закреплённая →
   `sorted().first`.
2. **Режим биллинга**: `covered` (подписка/лицензия) → бесплатно для отправителя;
   иначе `billedTo` (положительный баланс) → списание per-message; иначе free-tier
   → `adEligible`. Списание, **обнулившее** кошелёк, возвращает `true` из
   `appendAssistant` → в чат уходит один оффер «💸 Баланс закончился» с кнопками
   пополнения (событие `balanceEmpty`). Повторов не будет: без положительного
   баланса `billingKey` больше не адресует кошелёк.
3. Регистрирует `GenerationID` в `SessionRegistry`, запускает **typing**-индикатор.
   Typing живёт ровно до старта стрима (ожидание слота лимитера и первого
   плейсхолдера) — дальше прогресс видно по draft-анимации или по правкам
   плейсхолдера, поэтому `defer` его гасит.
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
8. **Разбивка длинных ответов** (`MessageSplitter`): при переполнении —
   «↑ продолжение» / «↓ продолжение ниже», новое сообщение. Бюджет считается **в
   экранированных символах** (`renderedLength` / `splitRendered`, `charLimit`
   3896 из 4096): Telegram меряет то, что получил, а `&` → `&amp;` и `<` → `&lt;`
   растят текст — кусок кода, нарезанный по сырой длине, отдавал 400 «message is
   too long», и часть ответа пропадала. Оценка пессимистична (настоящий тег
   считается как экранированный), поэтому ошибается только в сторону «разрезали
   раньше». Финальную проверку делает шлюз настоящим форматтером
   (`TelegramHTTPGateway.chunkFittingHTML`), в том числе для `editMessage`,
   которую разбить на два сообщения нельзя.
   **Оформление переживает разрез**: `splitRendered` не режет внутри `<…>` и
   `&…;` (граница сдвигается перед висящей разметкой) и **переоткрывает** в
   начале продолжения всё, что осталось открытым (`openTagMarkup`, теги
   копируются сырыми — санитайзер всё равно перечистит их в следующем куске).
   Симметрично `closingTagMarkup` **закрывает** их перед «↓ продолжение ниже»,
   перед стоп-нотисом и перед футером — иначе служебная строка оказывается
   внутри блока (в `<pre>` она читается как часть кода). Модель стека зеркалит
   `TelegramHTMLFormatter` (закрывающий тег снимает верхний независимо от
   имени); `script`/`style` не переоткрываются никогда — форматтер съел бы всё
   продолжение как их содержимое.
9. **Футер** (`makeFooter` → `ResponseFooterFormatter`): токены, стоимость ×markup,
   модель, прогнозируемый остаток баланса (для billed-юзеров).
10. Итог: `appendAssistant` (запись в историю + учёт usage + списание баланса) →
    оффер при обнулённом балансе → нотис о последней дневной порции → при
    `adEligible` показ рекламы; либо `cancelPendingTurn` + `refundDailyPremium`
    при пустом/отменённом.

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
markup, balances, **funnel** (счётчики воронки, §7/§11), **funnel_daily**
(те же события по дням, окно 35 суток, §11), **daily_premium_limit**
(суперадмин-настройка дневного премиум-вкуса, §9), **daily_premium_usage**
(израсходованные сегодня порции, §9), **self_promo** (текст/частота/показы
само-рекламы, §7), **modes** (эталонные режимы: тексты, модели, тарифы, рабочий
режим и счётчики тапов, §7 «Режимы»), **reminders**
(расписание напоминаний/winback, §7/§14), **onboarding** (примеры-запросы и
счётчики их тапов, §7 «Онбординг»), **referrals** (награды/лимит реферала),
**referral_ledger** (журнал привязок + агрегаты, §7 «Реферал»),
**traffic_sources** (атрибуция рекламных меток `src_` + агрегаты по кампаниям,
§7 «Источники»), **external_payments** (внешняя касса: реквизиты магазина,
валюта, цены, способы оплаты + открытые счета, §7 «Внешняя касса») и
**user_directory** (userID ↔ @username + ключ владельца, §6 «Идентичность»).
Значения конфигов оборачиваются в `{"value": …}`.

Схема **не менялась** ни разу: `user_directory` — обычная строка `bot_config`,
миграция данных ленивая (записи под старым ником переносятся при первой встрече
с человеком), поэтому деплой на живую базу ничего не ломает. `balances` хранит
весь `UserBalance` (там появились `toppedUpUsd` и `lapsedNoticeAt`, §7 «Возврат по
балансу») — у него рукописный `init(from:)`, новые поля опциональные, старые
кошельки читаются как «деньгами не платил». Остальные новые
поля: `card` хранит весь
`CardPaymentConfig` (там появился `usdRateMinorUnits` — курс пакетов, §7),
`chat_meta` — весь `ChatMetaInfo` (там `botRemoved`, §7 «Вирусный рост»), строка
чата — весь `ChatContextSnapshot` (там `downgradedFrom`, §9, и `activeMode` —
режим чата, §7 «Режимы»), `crypto` — весь
`CryptoConfigSnapshot` (там `explorerCursors` — позиции сканирования блокчейна,
§7). Все новые поля опциональные → старые строки декодируются без миграции.

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
  `update_id` (кольцевой буфер), склейка альбомов с holdback-таймером (holdback
  750 мс, таймер тикает раз в 300 мс — при webhook флашить больше некому, поэтому
  альбом реально уезжает через ~0.75–1 с). На выключении `shutdown()` не гасит
  буфер, а **сливает** его (`flushAll`): за эти апдейты Telegram уже получил 200 и
  повторно их не пришлёт.
  - **Буфер альбомов ограничен со всех сторон** (`TelegramPhotoAlbumBuffer`):
    частей на альбом (16), время жизни альбома (10 с), апдейтов в очереди за
    чатом (64), альбомов всего (256). Это память, которую держит отправитель:
    каждая новая часть двигала `lastSeenAt` вперёд, поэтому непрерывный поток
    частей с одним `media_group_id` держал альбом открытым бесконечно, а за ним
    копились **все** остальные сообщения чата — OOM с телефона. По превышению
    лимитов альбом отдаётся как есть, а лишние апдейты уходят вне очереди:
    порядок — приятная мелочь, неограниченная память — нет.
- **Per-chat сериализация** (`ChatUpdateDispatcher`): порядок в чате гарантирован,
  чаты параллельны, очередь ограничена (16) → защита от флуда.
- **Глобальный кап стримов** (`GenerationLimiter`): FIFO-семафор
  (`MAX_CONCURRENT_GENERATIONS`, дефолт 64). Лишние ждут (typing уже идёт),
  не выедая сокеты/память.
- **Rate limiter Telegram** (`TelegramRateLimiter`): token-bucket. Глобально
  ~18 msg/s (реальные сообщения) + отдельные бюджеты для draft'ов (8/s,
  droppable) и косметики/typing (3/s) → суммарно <30/s. Per-chat: личка ~1/s,
  группа 20/min. Авто-retry по `retry_after` (429). Прунинг «прогретых» бакетов.
  **Правки (`editMessage`) идут мимо per-chat ведра** — только через глобальное
  (`waitForEditSlot`). Лимит «20 сообщений/мин на группу» относится к отправке,
  а не к `editMessageText`; edit-стриминг (правка раз в 3с) выедал ровно весь
  бюджет чата, и каждый следующий вызов спал ~3с **внутри** `for try await` по
  SSE — ответ в группе залипал, а непрочитанный поток провайдера копился в
  памяти.
- **Дедупликация платежей**: charge_id (Stars/карта), tx-хеши (крипта).
- **Graceful shutdown** (SIGTERM/SIGINT): `draining=true`, webhook отдаёт 503 →
  Telegram передержит и передоставит апдейты; сливаем интейк; ждём (до 8с), пока
  опустеют **и** per-chat очереди (`totalQueuedOperations`), **и** активные стримы
  (`activeCount`); отменяем фоновые таски; финальный flush состояния. Ждать только
  стримы было мало: принятый апдейт, ещё стоящий в очереди чата, — это вопрос
  пользователя, на который никто не ответит и следов не останется.
  Отмена генерации («Стоп») **не** обнуляет `activeCount` заранее: сессия живёт до
  `finish`, поэтому выключение дожидается записи ответа в историю. **Редеплой без
  потерь.**
- **Эндпоинт кассы** (`/payments/<vendor>`, §7 «Внешняя касса»): принимает
  уведомление агрегатора (POST или GET, форма — не JSON), аутентификация —
  подпись вендора внутри адаптера, ответ — ровно то слово, которого касса ждёт
  (`YES`), иначе доставка повторяется. Всё, что мы приняли, но не смогли
  использовать (неизвестный счёт, недоплата), **подтверждается и логируется**:
  иначе агрегатор долбит эндпоинт вечно. 400 — только неподписанному запросу.
- **Health-эндпоинты** (`AppHTTPServer`): `/health` (liveness), `/ready` (503 пока
  restore не завершён и при draining — Railway healthcheck), `/metrics`
  (**закрыт токеном**: `Authorization: Bearer <METRICS_TOKEN>`, при незаданном —
  вебхук-секрет; эндпоинт висит на публичном домене и отдаёт воронку и выручку,
  открытым он быть не может). Оба секрета сверяются
  `SecretGuard.constantTimeEquals`. JSON:
  uptime, активные генерации, глубина очередей, dirty-сущности, статус
  персистентности, счётчики, `funnel`).
- **Метрики** (`RuntimeMetrics`/`MetricName`): updates received/deduplicated/dropped,
  generations, telegram_429, send errors, persistence flushes/errors, payments
  processed/deduplicated, reminder sweeps/sent/winbacks/send errors. Легко мапится
  на Prometheus.
- **Воронка-аналитика** (`FunnelEvent`/`funnelCounters`, персистится в `bot_config`):
  события start → addedToGroup (вирусный рост, §шаг4) → onboardingShown →
  exampleTapped (онбординг, §шаг9) → firstMessage → capHit/capWarned →
  promoShown/balanceEmpty (точки боли, §шаг5) →
  openPurchase → invoiceSent → paid/renewed + creditTopup, плюс удержание:
  expiryReminder → winbackSent → winbackRedeemed → walletWinbackSent и рост:
  referralJoined → referralRewarded → referralPaidBonus (§7). Счётчики —
  событийные (не уникальные юзеры), переживают рестарт.
  - **Периоды.** Каждое событие пишется дважды: в общий счётчик и в подневный
    бакет (`FunnelDailyLog`, `bot_config` → `funnel_daily`, окно 35 суток,
    прунится относительно **реальных** текущих суток). Страница супер-меню
    «📊 Воронка» переключается кнопками сегодня / 7 дней / 30 дней / всё время
    (`funnel:p:<period>`), рядом с числом периода показан общий итог. Итог
    отвечает «сколько всего», окно — «стало ли лучше»; без второго измерять
    бессмысленно.
  - **Источник покупки.** `openPurchase` считается вместе с поверхностью, откуда
    пришли: кнопка несёт `menu:nav:pay:<source>` (`PurchaseSource`: menu, cap,
    promo, welcome, command, reminder, balance, referral), счётчик кладётся под
    ключ `openPurchase.<source>` (namespace не пересекается с именами событий).
    Так апселлы в точке боли сравнимы с обычной кнопкой меню.
  - **Возвращаемость** — прокси вместо когортного D1/D7: `UserIdentity.firstSeenAt`
    + `seenAt` дают «видели ли человека спустя сутки / спустя неделю после первой
    встречи» (`UserDirectory.retention`). Поле опциональное, старые записи
    backfill'ятся последним известным визитом и до тех пор в когорту не входят.
  - Отдаётся в `/metrics`: `funnel` (всё время: счётчики + живой подсчёт спонсоров
    active/expired/unlimited/expiring_soon, активных winback-скидок, реферала
    `referral_pending`/`referral_rewarded`/`referral_paid_cents` и
    `retention_*`), плюс `funnelToday` и `funnelWeek`.
- **Режим апдейтов** (`UpdateMode`): `auto` (webhook если есть публичный URL —
  Railway; иначе polling), `webhook`, `polling`. Webhook защищён secret-заголовком.
  **Подписка на типы апдейтов — одна на оба транспорта**:
  `TelegramUpdateSubscription.allowedUpdates` (`message`, `callback_query`,
  `pre_checkout_query`, `my_chat_member`) уходит и в `setWebhook`, и в
  `getUpdates` (percent-encoded JSON). Без явного списка `getUpdates` **молча
  выкидывает** `my_chat_member`, и в polling-режиме пропадают приветствие группы,
  событие `addedToGroup`, детект блокировки и флаг `botRemoved`. Если `setWebhook`
  упал и мы уходим в polling — сначала `deleteWebhook()`, иначе каждый
  `getUpdates` отвечает «webhook is active».

---

## 12. Команды (`BotCommandName` / `BotCommandHandler`)

Парсинг: `/cmd`, `/cmd@botusername`, суффикс тест-режима (`/model3` при
`suffix=3`). До access-gate разрешены только `/start` и `/buy` — распознаются тем
же `CommandParser`, а не по префиксу строки (иначе `/buying` и `/startsomething`
проходили бы гейт).

**Пользовательские / настройки чата**: `/setrole`, `/clear_history`, `/settemp`,
`/model`, `/historylength`, `/show_model`, `/show_cost`, `/show_tokens`,
`/provider`, `/testmode`, `/reasoning`, `/help`, `/menu`, `/reset`, `/history`,
`/reset_stats`, `/backup_notify`, `/chatid`, `/start`, `/buy`, `/balance`,
`/examples` (кнопки-примеры онбординга), `/ref` (личная реферальная ссылка).
Тонкая настройка закрыта теми же гейтами, что и её страницы меню (§13):
`/settemp` и `/reasoning` — полный доступ, `/historylength` и `/provider` —
оператор чата.

**Админские / тенант**: `/default_role`, `/defaults`, `/whitelist`, `/chats`,
`/users`, `/presets`, `/tenant` (assign/release/adduser/register/remove/freemodels/
crypto/…), `/inspect`, `/ads` (+ `/ads promo` — само-реклама, §7), `/invite` (через меню).

**Суперадминские**: `/superadmin` (add/remove), `/simulate`, `/reminders`
(on/off/days `3,1`/winback/discount/hours/interval/chats/wallet/run/test/clear —
§7/§14), `/examples` (stats/on/off/groups/reset/clearstats — §7 «Онбординг»;
размещение примера — кнопкой «📍» в меню),
`/ref` (on/off/reward/friend/bonus/cap/stats — §7 «Реферал»; очистка журнала —
только кнопкой в меню),
глобальные free-модели, цены, наценка, балансы (в основном через супер-меню).

Неизвестная команда/упоминание → `.mention`/`.unknown` (игнор или обычная генерация).

---

## 13. Inline-меню (`BotMenuHandler`)

Страницы (`MenuPage`, callback_data `menu:<action>`): главная (`main` — режимы,
роль, сброс, тонкая настройка), `tuning` («⚙️ Тонкая настройка» — модель, стиль,
обдумывание, что показывать под ответом, память и сервис ИИ оператору), страница
покупки (`pay` — подписка + пакеты кредитов), реферальная страница (`ref` — личная
ссылка, «Поделиться», личная статистика; только в личке), admin-панель (`admin`, `adminhelp`,
`adminchats`, `adminusers`, `adminwl`, `admindef`, `admininvite`), супер-панель
(`superadmin`, `superadminhelp`, `superstars`, `supercrypto`, `supercard`,
`superextpay` — внешняя касса: реквизиты, валюта, цены, способы оплаты, URL
оповещения для кабинета,
`superfreemodels`, `supertenants`, `superadmins`, `supersim`, `superchats`,
`superads` — кампании + само-реклама (текст/частота/пауза/показы),
`superbal`, `superfunnel` — воронка-аналитика с переключателем периода,
источниками открытий покупки и возвращаемостью, `superreminders` —
напоминания/winback: волны расписания, возврат по балансу, ручная проверка,
предпросмотр, список подписок под наблюдением, `superonboarding` —
примеры-запросы: тексты, порядок, размещение (личка/группы), вкл/выкл,
предпросмотр, тапы по каждому примеру, `supermodes` — режимы бота: тексты,
модель, стиль, память, обдумывание, роль, тариф 🆓/⭐, рабочий режим, порядок,
цены моделей и тапы, `superref` — приглашения: награды обеим
сторонам, бонус за оплату друга, антифрод-лимит, счётчики выплат и приведённых
клиентов, топ пригласивших, очистка журнала, `supersrc` — источники трафика:
кампании `src_` по платящим, конверсия, шаблон ссылки, очистка).

**Гейт `super*`-страниц перечисляет их поимённо** (`case .superAdmin, … :` в
обработчике `nav:`), а не через `default` — забытая в списке страница
проваливается в `default: break` и открывается кому угодно (кнопки внутри
по-прежнему проверяют роль, но конфиг и числа владельца утекают). Новая
`super*`-страница обязана быть дописана в этот список. Забыть больше нельзя
молча: `EndToEndTests` тапает `nav:<page>` **за каждую** страницу с префиксом
`super` от лица обычного юзера и требует отказа (§19).

**Гейты тонкой настройки живут на самой странице** (`MenuPage`), а не в
обработчиках: `requiresFullAccess` (`temp`, `reasoning`) — нужен премиум, баланс
или спонсор, отказ **ведёт на страницу покупки** (`PurchaseSource.tuning`), а не
в тупик; `requiresOperator` (`provider`) — только суперадмин или админ этого
чата. Оба проверяются **дважды**, как `isPersonal`: в `showPage` (тап) и в
`renderPage` (перерисовка меню после текстового ввода, где callback'а нет).
Страница-хаб `tuning` намеренно **не** закрыта: закрытая дверь, в которую видно
(⭐ на кнопках), продаёт, а наглухо запертая — раздражает. То же у команд:
`/settemp` и `/reasoning` требуют полного доступа, `/historylength` и `/provider`
— оператора (`requireFullAccessForTuning` / `requireOperatorForTuning`), иначе
команда была бы обходным путём мимо гейта и мимо контроля расходов.

- `sendMenu` / `showPage` / `renderPage` — рендер клавиатур под роль/контекст.
- **Страница — это `MenuScreen`** (`Menu/MenuScreen.swift`), не безымянный
  кортеж: текст + клавиатура + инвариант `fitsInOneMessage`. Рендеры возвращают
  его, `editOrAnswer(callback:message:screen:)` его шлёт, `refreshMenu` —
  перерисовывает меню-сообщение после текстового ввода. Страница, переросшая
  одно сообщение, теперь пишет warning с именем страницы (`warnIfOversized`), а
  не молча теряет хвост. Ряды кнопок копит `Keyboard` (`row(...)`,
  `row(if:...)`, `insertBeforeLast(...)`, `extendLastRow(with:)`).
- **Гейт роли — один вызов** (`BotMenuHandler+Guards.swift`):
  `requireSuperAdmin(callback)` / `requireRootSuperAdmin(callback)` /
  `requireAdmin(callback, chatKey:)`. Они сами отвечают тостом при отказе, так
  что вызывающему остаётся `guard await requireX(...) else { return }`. Раньше
  это были 26 копий по четыре строки — 26 шансов вставить не тот гейт или
  забыть `answerCallback` (кнопка, которая молчит, читается как сломанный бот).
- **Подпись кнопки «назад» живёт у страницы-назначения** (`MenuPage.backLabel`,
  кнопка — `backButton(to:)`; отмена ввода — `cancelButton(to:)`). Кнопка не
  может обещать «← К супер-админу» и вести в другое место, а у одной страницы не
  может быть двух разных названий; закреплено тестом (§19).
- **Личные страницы — только в личке** (`MenuPage.isPersonal`: `ref`,
  `admininvite`, `superbal`). В группе меню — одно сообщение на всех: страницу
  перерисовывает тот, кто тапнул, а читают её все. `showPage` отвечает тостом
  `privateOnlyNotice` и ничего не рендерит; `renderPage` дублирует гейт для пути
  «меню обновилось после текстового ввода». Раньше `admininvite` публиковал
  пригласительный токен админа прямо в чат (любой участник получал платный доступ
  за его счёт, отозвать — только регенерацией), а `superbal` — кошельки всех
  людей.
- **Страница покупки в группе — прайс-лист.** `renderPay` в общем чате
  (`chatID < 0`) берёт цены через `subscriptionPricing(username: nil)` и не
  печатает ничего личного: ни баланс, ни срок своей подписки, ни персональную
  winback-скидку. Публично остаётся только факт про сам чат («премиум открыл @X»,
  `chatSponsor`) и общий оффер. Тапнуть «купить» там может любой, и платить он
  будет по прайс-листу (§17).
- **Главная страница в группе — тоже без личных чисел.** `renderMain` при
  `chatID < 0` не читает кошелёк и берёт `chatAccessStatus(username: nil)`:
  иначе строка «💰 Баланс · $0.1234» и «⚡ Премиум · ваш, до …» тапнувшего
  публиковались всем участникам (меню — одно сообщение на чат). По той же
  причине там не появляется метка «🔄 Продлить премиум»: она выдаёт, что
  тапнувший платит.
- **Справка супер-админа разбита на разделы** (`SuperHelpSection`,
  `nav:superadminhelp` → `sahelp:<раздел>`). Целиком она ~8 000 символов, а
  `editMessage` молча обрезает всё после ~3 900 (разбить правку на два
  сообщения нельзя) — половина справки была невидима. Любая страница меню
  обязана помещаться в одно сообщение: списки на `super*`-страницах
  (тенанты, кошельки, кампании-источники, открытые счета) поэтому режутся с
  явной строкой «показаны первые N».
- **Необратимое действие спрашивает подтверждение.** Удаление тенанта
  (`stenant:rm` → `rmyes`) и кошелька (`sbal:rm` → `rmyes`) — это чужая
  подписка и чужие деньги, а кнопка стоит в строке списка, где легко
  промахнуться. Очистка журналов реферала и источников устроена так же.
- **Callback кнопки — типизированный маршрут** (`Menu/MenuRoute.swift`).
  `callback_data` разбирается **один раз** в `MenuRoute`: `command`
  (`MenuCommand`, enum — неизвестная команда не доходит до обработчика, тап
  получает тост), `arg(i)`/`int(i)`/`page(i)`/`sub`. Индексы те же, что были у
  `parts`, только без `guard parts.count >= N` (их было 77) и без
  `parts[i]` (98). Пустой аргумент считается отсутствующим: `stenant:rmyes:`
  — это кнопка, потерявшая payload, а не просьба удалить тенанта с пустым ником.
  - **Кнопка строится тем же типом.** Наружу payload собирают только
    `MenuRoute.link(_:_:)` / `navigation(to:)` / `purchase(from:)` и обёртки
    `menuButton(_:page:)`, `menuButton(_:command:)`, `menuButton(_:_:_:)`,
    `buyButton(_:source:)`. Строковый `menuButton(_:action:)` — `private`.
    Переход на страницу принимает `MenuPage`, кнопка покупки **обязана** назвать
    `PurchaseSource` (§17 — иначе поверхность сольётся с меню в воронке).
    Склеивать `"cmd:sub:arg"` руками больше негде.
  - **Тесты вместо грепа** (§19): `MenuPageRenderTests` рендерит **каждую**
    страницу (личка/группа × владелец/обычный юзер) и проверяет, что каждая
    кнопка парсится в `MenuRoute`, каждая `nav:` ведёт на существующую страницу,
    страница не пустая и влезает в одно сообщение. `MenuRouteTests` — round-trip
    ссылок. Раньше связь «кнопка → обработчик» держалась на двух строковых
    литералах, и опечатка давала кнопку, которая молча ничего не делает.
- **Pending-input flow**: кнопка вроде «✏️ Изменить цену» кладёт «ожидание ввода»
  (`state.setPending(kind, menuMessageID:chatKey:)`) с ID меню-сообщения;
  следующий текст юзера ловит `processTextInput` (шаг 6 роутинга), применяет и
  обновляет меню. Так реализованы все «введите значение» сценарии (цена, адреса,
  пресеты, наценка, топ-ап баланса, симуляция и т.д.).
  - **Ожидание одно на чат** — `PendingRequest` (`{owner, menuMessageID, kind}`),
    `kind` — `PendingKind` со всеми вариантами (в т.ч. `.preset(PresetInput)` и
    `.admin(AdminPendingInput)`). Было восемь параллельных словарей со своими
    `set/consume/has/clear` и восемь `if has*` подряд на разборе; их нельзя было
    держать в согласии — чат мог висеть сразу в двух ожиданиях, а «есть ли
    ожидание» приходилось перечислять поимённо. Новый вид ввода = новый `case` в
    `PendingKind` плюс ветка в `switch` — ни поля, ни аксессоров, ни правок в
    «очистить всё».
  - **У ожидания есть владелец.** Само ожидание ключуется по `ChatKey` (там живёт
    меню-сообщение), но после каждого действия меню `handle(action:)` зовёт
    `notePendingInputOwner(invokerKey(callback))`, а `processTextInput` первым
    делом сверяет `pending.owner` с отправителем и **возвращает `false` для
    чужого сообщения** (оно идёт дальше, в обычный ответ LLM). Иначе настройка из
    группы съедает следующее сообщение любого участника: ответа нет, в чат
    прилетает «🔒 Только суперадмин…», а ожидание потрачено. Владелец живёт
    внутри `PendingRequest`, поэтому исчезает вместе с ожиданием — застрять он не
    может. Значение, не прошедшее валидацию, **перевзводит** то же ожидание, и
    `processTextInput` заново проставляет владельца: перевзведённое без хозяина
    ожидание начало бы глотать сообщения группы (закреплено тестом, §19).
- Всё управление ценами/оплатой/рекламой/наценкой — из меню, без передеплоя.

---

## 14. Фоновые процессы (запускаются в `run`)

- **`ModelPriceMonitor`** (каждые 5 мин + initial): тянет `openrouter.ai/api/v1/models`,
  кэширует цены (`openRouterModelPrices`) и множество бесплатных моделей
  (`openRouterFreeModelIDs`). Если модель, используемая в системе, стала платной —
  уведомляет затронутые чаты (или суперадминов, если модель «закреплена» в free).
  Адреса суперадминов — `superAdminPrivateChats()`, то есть личка **каждого**
  суперадмина через `privateChatID` (а не чаты, привязанные к root-тенанту:
  личка попадает в `chatOwnership` только через `autoAssignIfNeeded`, поэтому
  часть владельцев не получала ничего). Текст для чатов не обещает автоматической
  подмены модели: она случится, только когда у чата кончится дневная порция
  премиума (§9).
- **`CryptoPaymentMonitor`** (каждые 30с): поллит эксплореры, матчит входящие
  переводы к открытым инвойсам, засчитывает частичные оплаты, экспайрит
  просроченные. Позицию сканирования держит **стор**, а не актор монитора (§7,
  «Курсоры сканирования персистятся»).
- **`runPersistenceNotifyLoop`** (каждые 60с): чатам с `backupNotify=true` шлёт
  строку статуса хранилища (замена старого 60-секундного бэкап-отчёта).
- **`SubscriptionReminderService.run`** (первый проход через 60с после старта,
  дальше — каждые `sweepIntervalMinutes`, дефолт 60): свип подписок → напоминания
  перед истечением и winback-офферы со скидкой (§7). Свип сериализован (флаг
  `sweeping`), поэтому кнопка «🔄 Проверить сейчас» / `/reminders run` не пересекается
  с циклом. Пауза между свипами спится **минутными кусками** с перечитыванием
  конфига: интервал — живая настройка, и её укорачивание должно срабатывать
  сразу, а не после старого (возможно, суточного) сна.
  Результат последнего свипа (`SweepResult`) — на странице супер-меню.
  Работает и в memory-only режиме: подписка не должна тихо истечь.

Бесплатные модели: ноль-стоимостное множество = закреплённые суперадмином
(`_freeModelIDs`) ∪ бесплатные с OpenRouter (`effectiveFreeModelIDs()`).
**Разрешённое без оплаты** = оно же ∪ модели 🆓-режимов
(`allowedFreeModelIDs()`, §7 «Режимы») — именно его спрашивают гейты.

**Неизвестное множество — это «всё платное», а не «всё бесплатное».** Каталог
OpenRouter кэшируется в памяти и на старте может не подняться (сервис лежит,
ключ протух), а закреплённых моделей и 🆓-режимов с явной моделью может не быть —
тогда `allowedFreeModelIDs()` возвращает nil. Раньше гейт в `processContent` в этом
случае **пропускался целиком**: дневная порция не тратилась, откат не делался, и
любой пользователь получал платные модели без ограничений за счёт владельца —
молча, всё время недоступности каталога. Теперь nil означает «модель считаем
платной»: дневной лимит применяется как обычно, а когда он исчерпан и запасной
бесплатной модели нет, ход честно отклоняется. **Запасная модель берётся
только через `fallbackFreeModel()`**: модель рабочего 🆓-режима, иначе первая
закреплённая суперадмином, иначе
`sorted().first` эффективного множества. `Set.first` недетерминирован — чат,
упавший на free-tier, получал бы разную модель на каждом откате, и качество
ответов скакало бы без причины.

---

## 15. Переменные окружения (`AppConfig` / `EnvironmentKey`)

**Обязательные**: `TG_BOT_TOKEN`, `DEEPSEEK_API_KEY`, `ROUTER_API_KEY`
(OpenRouter), `COMPANY_CHAT_ID` (Int).

**Опциональные**:
- Хранилище: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` (предпочтительно) или
  `SUPABASE_ANON_KEY` (fallback). Без них — memory-only.
- Сеть/режим: `PORT` (дефолт 8000), `UPDATE_MODE` (auto/webhook/polling),
  `WEBHOOK_PUBLIC_URL` или `RAILWAY_PUBLIC_DOMAIN`, `TELEGRAM_WEBHOOK_SECRET`,
  `METRICS_TOKEN` (доступ к `/metrics`; не задан → берётся вебхук-секрет).
- Крипто-эксплореры: `TONAPI_KEY`, `ETHERSCAN_API_KEY` (V2 multichain: покрывает
  ETH и BSC), `BSCSCAN_API_KEY` (legacy fallback для BSC), `TRONGRID_API_KEY`.
- **`OWNER_USER_ID`** — числовой userID владельца. Формально опционален, но без
  него root опознаётся только по @нику из конфигурации: ник арендуемый, и тот,
  кто займёт его после владельца, получит root первым же сообщением
  (`identifyUser` → `adoptRecords` перенесёт запись суперадмина на его userID).
  С ним `rootSuperAdminKey` возвращает `#<id>` и **перебивает** и директорию, и
  восстановленное состояние. На старте без него пишется warning.
- **`TELEGRAM_API_BASE`** — адрес Bot API. Задаётся **только** в сквозных тестах
  (локальный дублёр, §19); в проде не выставлять, дефолт `https://api.telegram.org`.
- Прочее: `LOG_LEVEL`, `MAX_CONCURRENT_GENERATIONS` (дефолт 64).

**Секреты не попадают в логи**: `SecretRedactor` (регистрируется в `main` до
первой строки лога) вычищает токен бота и все ключи из любого сообщения
`ConsoleLogger` и из `UserFacingError.message`. Ошибки транспорта цитируют
запрос, а в каждом URL Telegram лежит токен — утечка токена это полный угон бота.

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

- **Код живёт в файле своей темы.** Четыре крупных типа (`ChatContextStore`,
  `BotMenuHandler`, `BotCommandHandler`, `GenerationCoordinator`) разбиты на
  расширения `Тип+Тема.swift` (§3): в «головном» файле только зависимости,
  хранилище и диспетчеры, тело — в тематическом файле. Новый обработчик
  дописывается в существующий `+файл` своей темы, а не в головной; новая тема —
  новый `+файл` с шапкой-комментарием, что в нём. Файл, переваливший ~700 строк,
  пора делить: чтобы прочитать одну ветку логики, не должен грузиться весь тип.
  Члены, к которым обращается соседний `+файл`, — `internal` без `private`;
  за пределами файлов одного типа их всё равно никто не трогает.
- **Switch — это диспетчер, а не место для тел.** Функция длиннее ~120 строк
  режется тем же приёмом, которым разобраны `processAction`,
  `processSuperAdminAction`, `handleTenant`, `handleBuyAction` и
  `processAdminPendingInput`: внешний `switch` оставляет по одной строке на
  ветку, тело уезжает в метод **со своим** `switch` (+ `default: break`) —
  тогда голый `break`/`return` внутри тела значит ровно то же, что значил.
  Новая ветка дописывается в метод своей темы, а не в диспетчер. Если у ветки
  есть своя страница меню, её обработчик живёт в файле этой страницы
  (`sbal:*` — в `+Tenants.swift`, `stars:*` — в `+PaymentSettings.swift`).
- **Всё состояние — через актор `ChatContextStore`**. Новая изменяемая сущность
  обязана: (а) помечать dirty-set при мутации, (б) экспортироваться/импортироваться
  в `ChatContextStore+Persistence.swift`, (в) при необходимости получить
  `GlobalConfigKey`/DTO.
- **Цены пользователю — всегда через `priceMultiplier()`** (`billedCost`,
  футер, списания). Не показывай сырой `totalCost`.
- **Рекламная ссылка несёт метку**: `?start=src_<метка>` (§7 «Источники»).
  Атрибуция — first touch и только для нового человека; засчитанная оплата идёт
  через `recordTrafficSourcePayment` рядом с реферальным бонусом, то есть **до**
  `flushNow` на каждом платёжном пути. Новый платёжный путь, забывший её,
  обнуляет CAC того канала, который этого клиента привёл.
- **Callback_data не пишется строкой.** Кнопка строится через
  `menuButton(_:page:)` / `menuButton(_:command:)` / `menuButton(_:_:_:)` /
  `buyButton(_:source:)`, а вне меню — через `MenuRoute.link(...)`; разбирается
  через `MenuRoute` (§13). Новая команда — новый `case MenuCommand` (иначе
  `MenuRoute(action:)` вернёт nil и тап честно ответит «Неизвестное действие»,
  а не промолчит). Ручная склейка `"cmd:sub:\(arg)"` возвращает ровно ту
  ошибку, ради которой всё это делалось: кнопку, которая рендерится и ничего
  не делает.
- **Повторяющийся текст — в `Texts`** (`Application/Texts.swift`), гейт роли —
  в `require*` (§13). Отказ, скопированный в 43 места, — это 43 шанса разойтись
  в формулировке (уже разошлись: «🔒 Только админ» рядом с «🔒 Только
  администратор»). В каталог кладутся **только литералы**: строка, называющая
  человека, чат или модель, собирается на месте — иначе каталог станет вторым
  путём чужого текста в HTML в обход `displayLabel`/`sanitizeName`.
- **Кнопка «купить» несёт источник**: `menu:nav:pay:<PurchaseSource>`
  (`menu`, `cap`, `promo`, `welcome`, `command`, `reminder`, `balance`,
  `referral`, `model` — пикер моделей, где платная модель недоступна,
  `mode` — тап по ⭐-режиму, `tuning` — попытка открыть тонкую настройку). Новая
  поверхность, ведущая на страницу покупки, обязана добавить свой источник —
  иначе она сольётся с меню и её вклад будет не виден в «📊 Воронка» (§11).
  Неизвестный/отсутствующий суффикс безопасно читается как `menu`.
- **«Можно ли эту модель без оплаты» спрашивают только у `allowedFreeModelIDs()`**
  (§9), и **nil значит «платная»**. Пикеры раньше читали nil наоборот
  (`?? false`), и пока каталог OpenRouter лежал, они раздавали ровно то, что гейт
  генерации потом отклонял, — за счёт владельца. Фолбэк — `fallbackFreeModel()`.
- **Настройка, которая множит стоимость ответа, — не пользовательская.** Память
  (`maxHistory`) переотправляется на каждом ходу, обдумывание и стиль тоже стоят
  денег: они закрыты `MenuPage.requiresFullAccess`/`requiresOperator` **и теми же
  гейтами в командах** (§13). Новая настройка такого рода обязана закрыть оба
  входа — иначе команда становится обходным путём.
- **Режим применяется одной мутацией** (`applyMode`): модель, стиль, память,
  обдумывание и роль пишутся вместе или не пишутся вовсе (нерезолвимая модель →
  `nil`, ничего не тронуто). Полуприменённый режим — это ни то, что выбрали, ни
  то, что было. Счётчик тапов ставит **обработчик кнопки**, не `applyMode`:
  сброс настроек тоже применяет режим, и считать его тапом нельзя.
- **Дневная порция премиума — ресурс пользователя.** Взял (`consumeDailyPremium`)
  — верни, если ход не дал ответа (`refundDailyPremium` рядом с
  `cancelPendingTurn`). Счётчик персистится: не превращай его обратно в
  in-memory «упрощение», иначе каждый редеплой обнуляет главный гейт конверсии.
- **Цена подписки — всегда через `subscriptionPricing(username:)`** (меню, `/buy`,
  крипто-инвойс, `pre_checkout_query`). Прямое чтение `starsPrice()`/`cardConfig()`
  для выставления счёта разъедет показанную и списанную цену, когда у юзера есть
  winback-скидка.
- **Платежи — `flushNow()`**, не полагайся на 2-секундный debounce. Исключение —
  реферальные выплаты (§7): кредит балансов и отметка `rewardedAt` меняются в
  одном шаге актора, поэтому потеря флаша откатывает их **вместе** и пара просто
  оплатится позже. Любая новая начисляющая механика обязана держать это свойство
  (деньги и отметка «выплачено» — в одной мутации).
- **Курсор сканирования блокчейна двигается последним.** Сначала зачисление всей
  пачки переводов (с его `flushNow`), только потом `advanceExplorerCursor` — и
  только вперёд. Обратный порядок помечает диапазон просканированным, а падение
  между этим и кредитом уносит платёж навсегда: у блокчейна нет ретрая доставки.
  Курсор по умолчанию — не «сейчас», а «сейчас минус 45 минут» (§7).
- **Пакет кредитов зачисляется `creditPurchasedBalance`**, а не `creditBalance`:
  только он отмечает, что человек заплатил **реальные деньги**
  (`UserBalance.toppedUpUsd`) и открывает новый цикл возврата по балансу (§7).
  Бонусы и начисления суперадмина обязаны идти обычным `creditBalance` — иначе
  бесплатный кредит превратит кого угодно в «доказанного плательщика».
- **Новый платёжный путь не пишет свой post-payment код.** Всё, что следует за
  приходом денег, живёт в `PaymentFulfillmentService.fulfil(_:)`: дедуп,
  активация или зачисление, `claimChatForPayment`, съедание winback-скидки,
  счётчики воронки, реферальный бонус за конверсию, `recordTrafficSourcePayment`
  и `flushNow` — в этом порядке. Список длинный, каждый пункт невидим, если о
  нём забыть, и каждый — чьи-то деньги. Путь строит `PaymentReceipt`, получает
  `PaymentFulfillmentOutcome` и рисует **только текст** для своего канала.
- **Идемпотентность**: любой платёжный путь дедуплицируется (charge_id / tx-хеш /
  `ext:<vendor>:<paymentID>`) — Telegram, блокчейн-поллинг и касса доставляют
  события повторно.
- **Подпись уведомления кассы проверяется до всего остального** и в постоянном
  времени; отсутствующая подпись — это неверная подпись, а не «поля нет».
  Адаптер, который отвечает вендору `YES` без проверки, дарит подписку любому,
  кто знает URL. Тексты полей сверяются регистронезависимо: платёж, отклонённый
  из-за строчной буквы в имени поля, неотличим от неверного секрета.
- **Какой токен пришёл — решается точным сравнением адреса контракта.** Свой
  жетон может выпустить кто угодно за стоимость газа, поэтому приблизительное
  сравнение здесь = бесплатная подписка. У TON две записи одного адреса (сырая
  `0:hex` и дружественная `EQ…`), и сравнивать их можно только через
  `TonAddress.equal` (декодирует base64url в `<workchain>:<hex>`); прежняя
  эвристика «в одной есть `:`, вторая начинается на `eq` → совпало» пропускала
  **любой** жетон как USDT. Tron сравнивается побайтово (base58 регистрозависим),
  EVM — по lowercase hex. Тем же `TonAddress.equal` сверяется и получатель:
  адрес в конфиге вводит человек, а индексатор отвечает в другой записи.
- **Чужой перевод не должен уметь занять чужой счёт.** В режиме `amountDelta`
  «усыновление» непривязанного инвойса (`applyIncomingTransfer`, шаг 3) требует
  не меньше половины остатка (`minimumAdoptableShare`) и берёт **ближайший** по
  сумме, а не самый старый. Без порога один пылевой перевод переводил чужой
  инвойс в `.partial`, и последующая **точная** оплата владельца уже ни с чем не
  matchилась. Точное совпадение (шаг 1) сверяется с `remainingAtomic` и включает
  `.partial` — счёт говорит «осталось доплатить X», значит X и должен матчиться.
- **Ключ пользователя не может содержать ничего, кроме `[a-z0-9_]`**
  (`UserKey.pending`, `userKeyOrRaw` → `sanitizedPendingFallback`). Ключ не
  безобиден: он уходит в фильтр PostgREST и печатается в HTML. Раньше
  `userKeyOrRaw` возвращал сырую строку, и текст из `/tenant adduser` мог стать
  ключом с `#` (подделка идентифицированного ключа) или с `&` (лишний
  query-параметр в URL удаления). Значения в `SupabaseStatePersistence.delete`
  percent-кодируются строго — **DELETE, потерявший фильтр, чистит таблицу**.
- **Роли**: `isSuperAdmin` учитывает симуляцию, `isActuallySuperAdmin` — нет.
  Для гейтов, которые должны работать при симуляции, используй второй.
- **Никогда не сравнивай сохранённого владельца с сырым ником.** Сравнивать можно
  только ключи: `state.userKey(username:)` / `state.userKey(userID:)`. Сравнение
  вида `owner?.lowercased() == username` молча ломается, как только человек
  идентифицирован (`owner` = `#12345`).
- **Кто спрашивает — тоже ключ, и он берётся из userID.** У обработчиков есть
  готовые хелперы: `BotMenuHandler.invokerKey(callback)` (userID у callback есть
  всегда) и `BotCommandHandler.actorKey(fromUser)` / `ownerKey(for:)`. Через них
  идут **все** гейты ролей (`isSuperAdmin`/`isAdmin`/`isRootSuperAdmin`/
  `isActuallySuperAdmin`), фильтры «мои чаты/юзеры» (`groupChats(ownedBy:)`,
  `privateChats(ownedBy:)`), симуляция и владение крипто-инвойсом. Сырой
  `callback.from.username` / `fromUser?.username` в гейте = человек без ника
  теряет доступ, а `nil` не совпадает ни с чем. Свою же принадлежность
  («это моя ссылка?») проверяй через `userKeys(username:userID:).contains(owner)`.
- **Ключ наружу не показывать.** Любая строка, называющая сохранённого
  пользователя, идёт через `displayLabel(forKey:)` или через готовое поле
  `label`. Метки уже содержат `@`, второй раз его дописывать не надо.
- **Новая сущность «на пользователя» ключуется `UserKey`** и переносится в
  `adoptRecords` (§6). Иначе она потеряется при смене ника — ровно то, ради чего
  вводился ключ.
- **Callback'и вне per-chat очереди** — не ломай это (Стоп должен прерывать).
  Исключение: кнопка, которая **запускает** генерацию (`ex:` — пример онбординга),
  обязана идти через `ChatUpdateDispatcher`, иначе порядок сообщений в чате
  разъедется.
- **Приветствие группы — только через `claimGroupGreeting`.** Telegram доставляет
  вход дважды (`my_chat_member` + `/start <payload>` от `?startgroup=`), пути
  разные и порядок не гарантирован. Новый повод поздороваться с группой обязан
  проходить через тот же claim и тот же `GroupWelcomePresenter`.
- **Каналы доставки в группы** (напоминания, поздравления, любые рассылки) берут
  чаты через `ownedGroupChatIDs` — он отсекает чаты, из которых бота удалили.
  Не обходи его прямым фильтром по `chatOwnership`. Личка адресуется через
  `privateChatID(forKey:)` — он так же отсекает заблокировавших бота.
- **Мёртвый адрес отмечается, а не ретраится.** 403 (заблокировали/выгнали) и
  «chat not found» — это навсегда: любая фоновая рассылка обязана позвать
  `setBotPresence(chatID:isMember:false)`, иначе она будет биться в ту же стену
  на каждом проходе и раздувать счётчик ошибок. 429/5xx/сеть — наоборот, ретрай.
- **Персональная цена не уходит в общий чат.** Winback-скидка живёт на аккаунте;
  в групповом сообщении цену берём из `subscriptionPricing(username: nil)` —
  тапнуть «Продлить» может любой участник, и платить он будет по прайс-листу.
  То же самое в меню: страница покупки в группе рендерится без личных чисел
  (§13), а страница, которая **вся** про одного человека (`MenuPage.isPersonal`),
  в группе не рендерится вообще.
- **Оплата не переписывает владельца живого чата.** Платёжные пути зовут
  `claimChatForPayment`, а не `assignChat`: группу, за которую платит активная
  чужая подписка, оплата не забирает (§7 «Спонсор-герой»). Новый платёжный путь
  обязан использовать её же и обработать `.keptSponsor` в тексте подтверждения —
  иначе бот поздравит покупателя с доступом, который открыл не он.
- **Ошибка провайдера внутри SSE обязана ронять поток.** Новый адаптер
  OpenAI-совместимого API декодит `error` (`ProviderStreamErrorPayload`) и
  завершает стрим `ProviderAdapterError.upstream`. Тихий `continue` превращает
  отказ (лимит, кончившийся баланс, модерация) в «Пустой ответ.» — и делает целый
  класс проблем невидимым в логах (§8).
- **`editMessage` не занимает per-chat бюджет.** Правки идут через
  `waitForEditSlot()` (глобальное ведро). Не возвращай их в `waitForMessageSlot`:
  групповое ведро 20/мин рассчитано на отправку, и edit-стриминг съест его
  целиком, заблокировав чтение SSE (§11).
- **Draft — только личка**; в группах и на старых Bot API — edit-стриминг.
  Draft эфемерен → финальный текст обязательно `sendMessage`, не только draft.
- **Имя пользователя — это чужой текст, а не подпись.** `first_name`, ник и
  название группы человек задаёт себе сам, а бот вставляет их в HTML-сообщение,
  подписанное собой. Поэтому экранирование живёт **в источнике меток** —
  `UserIdentity.displayLabel` / `sanitizeName` и `ChatMetaInfo.displayLabel` —
  а не на каждом из десятков мест склейки. Санитайзер отправки пропускает
  готовые сущности (`&lt;`) как есть, так что двойного экранирования нет.
  Новая метка обязана идти через них: `first_name` вида
  `<a href="…">Поддержка</a>` иначе станет живой ссылкой внутри сообщения бота —
  без всякой модели и prompt-инъекции.
- **Значения атрибутов в HTML экранируются целиком, включая кавычки**
  (`TelegramHTMLFormatter.escapeAttributeValue`). Без `"` строка вида
  `x" onclick="y` закрывает атрибут и дописывает свой; Telegram отвечает
  «can't parse entities», и ответ не приходит вообще.
- **`href` — только по белому списку схем** (`allowedURLSchemes`: http, https,
  tg, mailto, tel). Ссылка в сообщении бота наследует доверие к боту, а текст
  ссылки произволен, поэтому `javascript:`/`data:`/протокол-относительный `//`
  отбрасываются вместе с самим тегом `<a>` (текст остаётся).
- **Telegram-вывод — HTML** (`TelegramHTMLFormatter`), не Markdown. В system prompt
  боту сказано не тегать участников (`@` перед именами).
- **Резать длинный текст — только `MessageSplitter.splitRendered`** (не `split`
  и не по `.count`): он один считает бюджет в экранированных символах, держит
  границу вне разметки и переоткрывает теги в продолжении (§9). Любая служебная
  строка, которую дописывают **после** текста ответа (маркер продолжения,
  «⏹ Остановлено», футер), обязана идти после `closingTagMarkup(in:)` — иначе
  она попадёт внутрь незакрытого блока. Список переоткрываемых тегов
  (`MessageSplitter.renderedTags`) держать в согласии с allow-list форматтера.
- **`ChatKey` = chatID + threadID** (топики форумов — отдельные контексты;
  threadID=0 = основной).
- Русский — основной язык пользовательских сообщений и документации.
- **Язык текстов для пользователя** (ревизия после роадмап-шагов 1–10). Обращение —
  только на «вы». Внутренние термины наружу не выходят: в коде остаются
  `tenant`/`whitelist`/`preset`/`provider`/`reasoning`, а пользователь видит
  «премиум-доступ · спонсор», «гости чата», «заготовки», «сервис ИИ»,
  «обдумывание» (`ReasoningEffort.displayName`, ввод — через
  `ReasoningEffort(userInput:)`, понимает и `high`, и «глубоко»),
  «стиль ответа» вместо температуры, «память» вместо длины истории,
  «под ответом» вместо футера. Любую цифру или механику объясняем через пользу:
  про баланс всегда говорим **за что** (стоимость каждого ответа), **когда**
  (сразу после ответа) и **сколько примерно** (доли цента). Жаргон допустим
  только на `super*`-страницах меню и в супер-админских ветках команд.
  `UserFacingError` не должен выпускать наружу английский текст провайдера —
  нераспознанные ошибки оборачиваются в «Что-то пошло не так…». HTTP-ошибка
  апстрима отдаёт **только** `httpStatusReason(code)`: тело ответа раньше
  вставлялось в чат дословно, а туда сервис кладёт что хочет — фрагменты
  запроса, идентификаторы аккаунта, префиксы ключей. Полное тело остаётся в
  логах. Итоговая строка дополнительно проходит `SecretRedactor` (§15).
- **`/help` (`BotCallbackHandler.faqText`) держать под ~3800 символов**:
  `MessageSplitter.charLimit` = 3896, иначе справка приедет двумя сообщениями.
  Супер-админские команды в общий `/help` не добавлять — для них есть
  `superAdminHelpText`.

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

---

## 19. Тесты

`swift test` — цель `LLM_chat_botTests` (`Tests/LLM_chat_botTests/`), 303 теста,
чистая логика без сети: стор поднимается в памяти (`Fixtures.makeStore()`),
Supabase, Telegram и провайдеры не участвуют.

- `MessageSplitterTests` — бюджет в экранированных символах, границы вне
  разметки, переоткрытие тегов в продолжении (§9).
- `TelegramHTMLFormatterTests` — allow-list тегов, экранирование атрибутов,
  схемы `href`, `<script>` (§17).
- `TelegramHTMLFormatterGoldenTests` + `HTMLCorpus` — 69 входов (все ветки
  чтения тега, атрибутов и сущностей + то, что реально выдаёт модель) и их
  точный вывод, снятый **до** разбиения санитайзера на три стадии. Файл не
  утверждает, что этот вывод идеален, — только что разбиение его не изменило.
  Он же держит регрессию найденного при разбиении падения: текст,
  заканчивающийся на `<` (оборванный блок кода), ронял процесс — проверка
  границы смотрела на текущий индекс вместо следующего.
- `CommandParserTests`, `MessageRoutingPolicyTests` — `/cmd@bot`+суффикс,
  «`/buying` — не `/buy`», реакция в группе только на reply/@-упоминание.
- `UserIdentityTests` — `UserKey` (в т.ч. что типизированный текст не может
  подделать `#<id>`), директория, adoption, retention (§6).
- `SubscriptionScheduleTests` — `dueNotice`: волны, дедуп, legacy-ключ,
  catch-up окно winback; нормализация и декод конфига (§7/§14).
- `Store*Tests` — доступ и роли, подписки и цены со скидкой, кошельки и дневная
  порция премиума, реферал и антифрод, источники трафика, реклама, free-модели,
  онбординг, память чата, воронка, dirty-tracking и restore.
- `StoreModePresetTests` — режимы (§7 «Режимы»): модель 🆓-режима разрешена без
  подписки, ⭐ не даёт ничего, фолбэк детерминирован и предпочитает рабочий
  режим, применение пишет весь бандл или ничего, ручная правка снимает
  `activeModeID`, повторный выбор того же режима не чистит переписку, правка
  сохраняет тапы, неизвестный тариф декодится как `premium`, конфиг переживает
  flush → restore.
- `StorePendingInputTests` — слот ожидания ввода (§13): одно ожидание на чат,
  взведение вытесняет прежнее, потраченное не оставляет ни следа, ни владельца,
  перевзведение живого ожидания владельца сохраняет.
- `MenuRouteTests` — разбор `callback_data`, отказ неизвестной команде, пустой
  аргумент = отсутствующий, round-trip ссылок всех страниц и всех
  `PurchaseSource` (§13).
- `MenuPageRenderTests` — рендер **каждой** страницы меню в личке и в группе, за
  владельца и за обычного юзера: у каждой кнопки маршрут существует, `nav:`
  ведёт на реальную страницу, тело не пустое и влезает в одно сообщение; личные
  страницы и страница покупки в группе не печатают личных чисел; кнопка «←»
  называет ту страницу, на которую ведёт (`MenuPage.backLabel`). Плюс гейты
  тонкой настройки: **каждая** `requiresFullAccess`-страница отказывает
  бесплатному чату и открывается, как только у него появился баланс; ручки
  памяти видны только оператору; главная предлагает режимы и помечает ⭐ те, что
  закрыты.
- `PaymentTypeTests` — сравнение TON-адресов (обе записи одного счёта),
  форматирование атомарных сумм, пакеты кредитов, минимумы валют карты.
- `ExternalPaymentTests` — внешняя касса (§7): подпись ссылки и уведомления
  сверены с примером из документации вендора (хеш посчитан вне кода), подделка
  подписи/суммы/чужого секрета отклоняется, суммы парсятся целочисленно
  (`0.29` не превращается в 28.99…), реквизиты работают только тройкой,
  пополнения переживают выключенную подписку, скидка не опускает цену ниже
  минимума валюты, счёт переиспользуется и оплачивается один раз, конфиг и
  открытые счета переживают рестарт.
- `ExternalCallbackEndToEndTests` — деньги от кассы до доступа: подписанное
  уведомление включает премиум и пишет плательщику, повторное — не продлевает
  второй раз, пакет ложится на баланс по курсу суперадмина и помечается как
  реальная оплата, неподписанное и недоплаченное не дают ничего.
- `EndToEndTests` + `FakeTelegram.swift` — **сквозные**: апдейт входит в
  `BotOrchestrator.dispatch`, проходит настоящие команды/меню/генерацию и
  настоящий `TelegramHTTPGateway`, а приземляется в локальный дублёр Bot API —
  тест читает **то, что увидел бы пользователь** (текст, кнопки, `parse_mode`).
  Подделаны только модель (`FakeProviderGateway`) и загрузчик медиа. Покрыто:
  приветствие с примерами, ответ в личке и молчание в группе без обращения,
  рендер меню и переход на страницу покупки, отказ **каждой** `super*`-страницы
  обычному юзеру (цикл по `MenuPage.allCases` — новая страница попадает в
  проверку сама), реферальный диплинк с выплатой после первого ответа, `src_`-метка,
  оффер при исчерпании дневного лимита, тап по примеру, тап по ⭐-режиму без
  доступа (приходит страница покупки, настройки чата не изменились, источник
  учтён в воронке) и по 🆓-режиму (применяются модель, стиль и память сразу),
  разбивка длинного
  ответа, ожидание ввода в группе (чужое сообщение не съедается и получает
  обычный ответ; неверное значение перевзводит ожидание с тем же владельцем),
  проверка, что ни одна отправленная боту кнопка не ведёт в никуда.

**Правила.**
- Тест формулирует **правило продукта**, а не текущий вывод функции: «оплата
  никогда не сокращает срок», «порция возвращается, если ответа не было»,
  «оплата не отбирает чужой чат».
- Новая денежная или доступная механика приезжает с тестом — это единственная
  проверка, которая ловит регрессию до продакшена (тесты уже поймали одну:
  §6, `userKey(username:)` перестал принимать `#<userID>` — все ролевые гейты
  молча отвечали «нет»).
- `Tests/` копируется в Docker-образ: SwiftPM проверяет **все** цели манифеста,
  и без каталога сборка падает («overlapping sources»).
- **`TELEGRAM_API_BASE`** (§15) существует ради сквозных тестов: он переключает
  `TelegramHTTPGateway` на локальный дублёр. В проде его не задают никогда —
  дефолт `https://api.telegram.org`.
- Ждать результат — только по условию (`waitUntil`, `waitForCall`), не
  `sleep`: бот отвечает на своих тасках, и фиксированная пауза даёт либо
  флаки, либо медленный прогон.
