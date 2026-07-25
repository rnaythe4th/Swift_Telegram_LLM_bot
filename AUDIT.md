# Аудит кода — 2026-07-25

Найдено при полном чтении `Sources/` (сборка проходит чисто, `swift build` OK).
Пункты пронумерованы `B1…B27`. В новой сессии можно сказать «почини B7» — там есть
всё нужное: где, что происходит, почему важно, варианты исправления.

Порядок — по убыванию ущерба.

---

## 🔴 Критично (ломает деньги или главную механику)

### B1. Дневной премиум-вкус работает ровно один день, потом умирает навсегда

> ✅ **Исправлено** (вариант 1 + вариант 3). `GenerationCoordinator` перед гейтом
> молча зовёт `restoreDowngradedModel`, если `remainingDailyPremium > 0`; новый
> `ChatContextStore.paidModelAccess` (`.full`/`.dailyTaste`/`.none`) пускает
> бесплатного пользователя с остатком порции выбрать платную модель в `/model` и
> в меню, называя остаток. CLAUDE.md §9 обновлён.

**Где:** `Application/Generation/GenerationCoordinator.swift:393-434`,
`Domain/Chat/ChatContextStore.swift:2853-2876` (`downgradeModelToFree` /
`restoreDowngradedModel`).

**Что происходит.** Гейт срабатывает только если текущая модель платная:

```swift
} else if let effectiveFree = await state.effectiveFreeModelIDs() {
    let currentModel = await state.model(chatKey: chatKey)
    if !effectiveFree.contains(currentModel) {      // ← вход в гейт
        ... consumeDailyPremium ...
        case .exhausted: downgradeModelToFree(...)  // ← модель стала бесплатной
```

После первого исчерпания лимита `context.model` = бесплатная модель. На следующие
сутки `consumeDailyPremium` **не вызывается вообще** — условие
`!effectiveFree.contains(currentModel)` теперь false. `restoreDowngradedModel`
зовётся единственный раз — в ветке `if hasAccess` (строка 398), то есть только
после покупки.

Вручную вернуть платную модель бесплатный пользователь **тоже не может**:
`BotMenuHandler.swift:709, 747` и `BotCommandHandler.swift:205` отвечают
«⭐ Это платная модель» именно потому, что `hasFullModelAccess == false`.

**Почему важно.** Вся механика «5 умных ответов в день» (роадмап шаг 6) — главный
драйвер конверсии по CLAUDE.md §9 — отрабатывает один раз в жизни чата. Сообщение
«Завтра будут снова — счётчик обнуляется каждый день» (`sendDailyLimitOffer`,
строка 125) — прямая ложь. Плюс шапка `/menu` («умных ответов сегодня осталось ·
5 из 5») показывает лимит, который невозможно потратить.

**Варианты исправления.**
1. *(предпочтительно)* Восстанавливать модель при смене суток независимо от
   доступа: в `processContent` перед гейтом, если `downgradedFromModel != nil` и
   `remainingDailyPremium(...).remaining > 0` — звать `restoreDowngradedModel`
   молча (без сообщения в чат; сообщение оставить только для случая `hasAccess`).
2. Не менять модель вообще: держать «отложенную» платную модель как есть, а на
   исчерпанном лимите подменять модель только в `GenerationSnapshot`
   (`snapshotAndAppend` получает `overrideModel:`). Тогда состояние чата не
   портится и `downgradedFromModel` не нужен. Чище, но правка шире.
3. Минимально: разрешить выбор платной модели в меню/`/model`, когда у чата есть
   остаток дневного лимита (`remainingDailyPremium > 0`).

---

### B2. Крипто-платежи не переживают рестарт: курсор эксплорера только в памяти

> ✅ **Исправлено** (вариант 3: оба). Курсоры живут в сторе
> (`CryptoConfigSnapshot.explorerCursors`, `advanceExplorerCursor` — только
> вперёд, `pruneExplorerCursors` чистит мёртвые адреса), холодный старт
> сканирует на 45 мин назад. Курсор двигается **после** зачисления пачки, иначе
> краш между записью курсора и кредитом теряет платёж. CLAUDE.md §7/§10/§14/§17.

**Где:** `Application/Payments/CryptoPaymentMonitor.swift:17, 53-54`.

```swift
private var cursors: [CursorKey: ExplorerCursor] = [:]
...
let cursor = cursors[key] ?? ExplorerCursor(lastSeenUnix: nowSeed)   // nowSeed = сейчас
```

**Что происходит.** При старте процесса курсор для каждого адреса ставится в
«сейчас». Любой перевод, пришедший **до** старта (во время редеплоя, падения,
или просто в первые 30 секунд), никогда не будет просканирован — эксплорер
запрашивается только «начиная с курсора».

**Почему важно.** Railway редеплоит часто; окно потери — весь даунтайм. Человек
отправил USDT, бот его не увидел, инвойс через 30 минут протухает. Деньги
получены, доступ не выдан, следов в логах нет (кроме отсутствия события).

**Варианты исправления.**
1. Персистить курсоры: добавить в `CryptoConfigSnapshot` поле
   `explorerCursors: [String: Int]` (ключ `"<asset>:<address>"`) + методы в сторе,
   помечающие `.crypto` грязным. Схема Supabase не меняется.
2. Дешевле и почти так же надёжно: стартовый курсор брать не как `now`, а как
   `min(now - lookbackWindow, …)`, где `lookbackWindow` ≈ время жизни инвойса
   (30 мин) + запас. Дедуп по `creditedTxHashes` уже есть, повторный скан
   безопасен. Одна строка, но повторный скан всех адресов на каждом старте.
3. Оба: (2) как страховка, (1) как основное.

---

### B3. Крипто-платёж не делает `flushNow()`

> ✅ **Исправлено.** `PersistenceCoordinator?` прокинут в `CryptoPaymentService`;
> `applyMatch` флашит после всех мутаций и до уведомлений — и в ветке полной
> оплаты, и в частичной. Реферальный бонус разделён на `redeem` (до флаша) и
> `announce` (после).

**Где:** `Application/Payments/CryptoPaymentService.swift:301-350` (`applyMatch`),
`CryptoPaymentMonitor.swift` — ни у сервиса, ни у монитора нет ссылки на
`PersistenceCoordinator`.

**Что происходит.** `activatePaidSubscription` / `creditPurchasedBalance` /
`redeemReferralPaymentBonus` меняют состояние и ждут обычного 2-секундного
debounce. Правило CLAUDE.md §17 («Платежи — `flushNow()`») здесь нарушено.

**Почему важно.** Убийственная комбинация с B2: платёж зачислен → SIGTERM через
секунду → подписка не записана, `creditedTxHashes` не записаны, инвойс не записан,
курсор потерян (B2) → платёж исчезает целиком. По отдельности риск маленький,
вместе — реальный.

**Исправление.** Прокинуть `PersistenceCoordinator?` в `CryptoPaymentService`
(создаётся в `LLM_chat_bot.swift:117` — координатор там уже есть, строка 89) и
звать `await persistence?.flushNow()` в конце `applyMatch` **после** всех мутаций,
до нотификаций. Аналогично тому, как это сделано в
`BotOrchestrator.handleSuccessfulPayment:717`.

---

### B4. В polling-режиме `my_chat_member` не приходит вообще

**Где:** `Infrastructure/Telegram/TelegramHTTPGateway.swift:116-118` —
`getUpdates` вызывается без `allowed_updates`.

```swift
let url = "\(telegramURL)/getUpdates?timeout=30&offset=\(offset ?? 0)"
```

**Что происходит.** Telegram по умолчанию **исключает** `my_chat_member` и
`chat_member` из `getUpdates`. Webhook регистрируется правильно
(`BotOrchestrator.swift:186`), polling — нет.

**Почему важно.** В polling-режиме (локальная разработка, и — что важнее —
аварийный fallback в `run()` при неудачном `setWebhook`, строка 195) молча
отключаются: приветствие группы при входе, событие воронки `addedToGroup`,
детект блокировки бота в личке, отметка `botRemoved`. Последняя — источник правды
для `privateChatID` / `ownedGroupChatIDs`, то есть напоминания и winback начинают
биться в мёртвые адреса.

**Исправление.** Добавить в URL
`&allowed_updates=["message","callback_query","pre_checkout_query","my_chat_member"]`
(percent-encoded). Лучше — вынести список в общую константу и использовать её и в
`setWebhook`, и в `getUpdates`, чтобы они не разъезжались.

---

## 🟠 Важно (ломает конкретный сценарий)

### B5. `/chats` и `/users` для админа всегда показывают пусто

**Где:** `Application/Commands/BotCommandHandler.swift:1488` и `:1527`.

```swift
let ownerFilter: String? = isSuperAdmin ? nil : fromUser?.username?.lowercased()
let groups = await state.groupChats(ownedBy: ownerFilter)
```

**Что происходит.** `groupChats(ownedBy:)` сравнивает `chatOwnership[chatID] == owner`,
а там лежит `UserKey` (`#12345`). Сырой ник никогда не совпадёт. Ровно тот
анти-паттерн, о котором предупреждает CLAUDE.md §17 («Никогда не сравнивай
сохранённого владельца с сырым ником»).

**Почему важно.** Владелец лицензии не видит ни одного своего чата и ни одного
пользователя. Суперадмин (фильтр `nil`) видит всё, поэтому баг незаметен при
тестировании из-под root.

**Исправление.** `let ownerFilter = isSuperAdmin ? nil : fromUser?.id.map { state.userKey(userID: $0) }`.
В меню (`renderAdminChats`, `renderAdminUsers`) это уже сделано правильно — можно
свериться с `BotMenuHandler.swift:4177`.

---

### B6. Владелец не может отменить свой крипто-инвойс

**Где:** `Application/Menu/BotMenuHandler.swift:2519`.

```swift
if invoice.username != (callback.from.username?.lowercased() ?? "") {
    try? await telegram.answerCallback(..., text: "🔒 Не ваш счёт")
    return
}
```

**Что происходит.** `invoice.username` — `UserKey` (`#12345`, кладётся в
`CryptoPaymentService.swift:87`), справа — сырой ник. Условие истинно всегда →
кнопка «Отменить» не работает ни у кого.

**Исправление.**
```swift
guard invoice.username == state.userKey(userID: callback.from.id) else { ... }
```
Заодно рядом: `case "refresh"` (строка 2501) вообще не проверяет владельца — стоит
добавить ту же проверку, иначе чужой callback_data покажет адрес и сумму инвойса.

---

### B7. `seenAt` пользователя почти никогда не персистится

**Где:** `Domain/Chat/ChatContextStore.swift:369-372`.

```swift
let outcome = userDirectoryValue.record(userID:username:firstName:)
guard outcome.changed else { return }      // ← выходим, не пометив грязным
dirtyConfigs.insert(.userDirectory)
```

`record` (`UserDirectory.swift:160`) всегда обновляет `identity.seenAt`, но
`changed` = `isNew || previous != normalized` — то есть только новый человек или
смена ника.

**Что происходит.** Обновления `seenAt` живут в памяти и попадают в базу лишь
попутно, когда кто-то другой сменит ник или впервые придёт (тогда пишется вся
строка целиком). На тихом боте — не попадают вообще, и после рестарта `seenAt`
откатывается к давнему значению.

**Почему важно.** Два потребителя:
- `dueWalletWinbacks` (`ChatContextStore.swift:3158`) считает «молчит ≥ N дней» по
  `seenAt` → активный человек получает «👋 Давно вас не было» (и отметка
  `lapsedNoticeAt` ставится навсегда, второго шанса не будет);
- `UserDirectory.retention` (D1/D7 на странице «📊 Воронка») систематически
  занижает возвращаемость.

**Варианты исправления.**
1. Помечать `.userDirectory` грязным всегда, но троттлить: писать, если
   `seenAt` сдвинулся больше чем на N минут (например 15). Одна строка
   `bot_config` на 10 000 записей — писать её на каждое сообщение нельзя.
2. Возвращать из `record` отдельный флаг `seenAtAdvanced` с тем же троттлингом
   внутри `UserDirectory`.

Заодно стоит заметить: строка `user_directory` при 10 000 идентичностей
сериализуется целиком на каждый флаш, где она грязная. Если бот вырастет — это
кандидат на вынос в отдельную таблицу.

---

### B8. Оплата в чужой группе перехватывает её у активного спонсора

**Где:** `Application/BotOrchestrator.swift:700`
(`await state.assignChat(chatID: message.chat.id, to: payerKey)`) и
`Application/Payments/CryptoPaymentService.swift:322` (то же самое).

**Что происходит.** `assignChat` безусловно переписывает `chatOwnership[chatID]`.
Если участник группы, уже покрытой активной подпиской @A, покупает премиум для
себя прямо в этой группе, чат уходит под @B. У @A он пропадает из
`ownedGroupChatIDs` — то есть из его «мои чаты», из напоминаний и из строки
«премиум для чата открыл @A».

**Почему важно.** Тихая потеря чужого оплаченного ресурса, без единого сообщения.
Если @B потом не продлит, чат упадёт во free-tier, хотя подписка @A ещё жива.

**Варианты исправления.**
1. Привязывать только если чат ничей или его владелец **неактивен**:
   `if chatOwner == nil || !tenantIsActive(chatOwner)`. Иначе — оставить как есть
   и написать покупателю «здесь уже премиум от @A, ваша подписка работает в личке
   и ваших чатах» (текст для этого уже есть в `renderPay:2183`).
2. Сделать `assignChat(chatID:to:overwriteActive:)` с явным флагом и передавать
   `false` из платёжных путей, `true` — из ручной привязки (`/tenant claim`).

---

### B9. Личные данные утекают в общий чат через меню

**Где:** `Application/Menu/BotMenuHandler.swift:1509-1511` (`showPage` рендерит
страницу под тапнувшего и **редактирует общее сообщение**), плюс конкретные
страницы: `renderPay:2203-2207` (баланс), `:2215-2227` (персональная
winback-скидка), `renderAdminInvite:4460` (инвайт-токен).

**Что происходит.** В группе меню — одно сообщение на всех. Кто нажал кнопку, под
того страница и перерисовывается, но видят её все участники.

**Почему важно.**
- Баланс `$X.XXXX` и личная скидка −30% становятся публичными. CLAUDE.md §17:
  «Персональная цена не уходит в общий чат» — здесь нарушено.
- `renderAdminInvite` публикует пригласительный токен админа в чат: по нему любой
  участник получает платный доступ за счёт этого админа. Токен один на владельца,
  отозвать — только регенерацией.

**Варианты исправления.**
1. Для персональных страниц (`pay`, `adminInvite`, `referral`, `superBalances`)
   в группе не редактировать общее сообщение, а отвечать
   `answerCallback(show_alert:)` «откройте в личке» + ссылку `t.me/<bot>?start=`.
   Для `referral` это уже сделано (`nav`-гейт, строка 537-546) — распространить
   тот же приём.
2. Мягче: в группе скрывать только персональные блоки (баланс, скидка, токен),
   оставляя саму страницу покупки — она общая по смыслу.

---

### B10. Ожидание текстового ввода в меню перехватывает чужие сообщения в группе

**Где:** `Application/Menu/BotMenuHandler.swift:97-263` и далее — все
`_pending*Inputs` в сторе ключуются по `ChatKey`, не по пользователю.
Вызывается из `BotOrchestrator.route:642`, то есть **до** `MessageRoutingPolicy`.

**Что происходит.** Суперадмин в группе нажал «✏️ Изменить цену». Следующее
сообщение **любого** участника — даже не адресованное боту — съедается
`processTextInput`, возвращается `true`, LLM-ответа нет. Участник получает
«🔒 Только суперадмин может изменить цену» ни с того ни с сего, а в
`hasPendingCryptoPoolAddInput` (строка 242) — вообще молчание: `return true` без
ответа. Ожидание при этом потрачено, админу надо начинать заново.

**Почему важно.** Тихо проглоченное сообщение в общем чате выглядит как поломка
бота, и воспроизводится легко: настройка из группы — обычный сценарий для
суперадмина.

**Варианты исправления.**
1. Ключевать ожидания парой `(ChatKey, UserKey)`: `_pendingXInputs[chatKey]` →
   `[chatKey: (userKey, payload)]`, и в `processTextInput` игнорировать (вернуть
   `false`) сообщения от другого человека. Правка механическая, но в ~8 местах.
2. Дешевле: в группе не ставить ожидание вовсе — просить продолжить в личке или
   принимать значение через аргумент команды.

---

### B11. Коллизия слотов крипто-инвойсов приводит к зачислению не тому человеку

> ✅ **Исправлено.** Нет свободного слота → `CryptoPaymentError.slotsExhausted(asset)`
> вместо тихого слота 0. Заодно `UserFacingError` отдаёт тексты
> `CryptoPaymentError` как есть, не заворачивая в «Что-то пошло не так».

**Где:** `Application/Payments/CryptoPaymentService.swift:113-126`.

```swift
var picked: Int = 0
var attempts = 0
while attempts < maxSlots {
    let candidate = await state.nextCryptoSlot(asset: asset)
    if !usedSlots.contains(candidate) { picked = candidate; break }
    attempts += 1
}
slot = picked            // ← если все слоты заняты, тихо остаётся 0
```

**Что происходит.** Когда свободных слотов нет, цикл выходит с `picked = 0` —
слотом, который почти наверняка занят. Два открытых инвойса получают **одинаковую
`exactAmountAtomic`**, и `applyIncomingTransfer` (ветка «exact match», строка 254)
отдаёт платёж старшему по `createdAt`.

**Почему важно.** Деньги одного пользователя закрывают подписку другого. Режим
`amountDelta` — режим по умолчанию (`_cryptoMatchMode = .amountDelta`).
Вероятность низкая (нужно `maxConcurrentSlots` одновременных инвойсов на одну
монету), последствие — прямая финансовая ошибка без следов.

**Исправление.** При исчерпании слотов бросать ошибку (например новый
`CryptoPaymentError.slotsExhausted(asset)` с текстом «все счета сейчас заняты,
попробуйте через несколько минут или выберите другую монету») — по аналогии с
`poolExhausted` в режиме `uniqueAddress`.

---

### B12. Ошибки провайдера в SSE-потоке превращаются в «Пустой ответ»

**Где:** `Infrastructure/Providers/OpenRouterProviderAdapter.swift:102-109`.

```swift
guard let json = payload.data(using: .utf8) else { continue }
if let usage = parseUsage(jsonData: json) { capturedUsage = usage }
if let text = parseDelta(jsonData: json), !text.isEmpty { continuation.yield(.text(text)) }
```

**Что происходит.** OpenRouter шлёт ошибки **внутри** потока
(`{"error":{"code":429,"message":"rate limited"}}`, модерация, «no endpoints
found» и т.п.) с HTTP 200. Этот payload не парсится ни как usage, ни как delta →
молча игнорируется. Поток завершается, `fullAccumulator` пуст → пользователь
видит «<i>Пустой ответ.</i>» с футером.

**Почему важно.** Реальная причина отказа (кончился баланс OpenRouter, модель
недоступна, сработала модерация) не доходит ни до пользователя, ни в логи. Порция
дневного премиума при этом корректно возвращается (`refundDailyPremium`), так что
баг «только» диагностический — но он делает целый класс проблем невидимым.

**Исправление.** Добавить в `OpenRouterStreamChunk` опциональное поле `error` и,
если оно пришло, `continuation.finish(throwing: ProviderAdapterError.upstream(...))`.
`UserFacingError.message` уже умеет заворачивать нераспознанное в «Что-то пошло не
так…» (CLAUDE.md §17), так что английский текст провайдера наружу не выйдет.
То же самое стоит проверить для `DeepSeekProviderAdapter`.

---

### B13. Групповой стриминг упирается в лимит 20 сообщений/мин

**Где:** `Infrastructure/Telegram/TelegramHTTPGateway.swift:222`
(`editMessage` → `waitForMessageSlot(chatID:)`),
`Application/Runtime/TelegramRateLimiter.swift:70-72` (для `chatID < 0` — ведро
`capacity: 4, refillPerSecond: 20/60 ≈ 0.333`).

**Что происходит.** В группах используется edit-стриминг, редактирующий
placeholder раз в 3 секунды (`GenerationCoordinator.swift:881`) — ровно 20/мин,
то есть ровно весь бюджет чата. Плюс placeholder, финальный edit, футер, реклама,
оффер лимита. Ведро уходит в ноль, и каждый следующий вызов ждёт ~3 с внутри
`for try await event` — то есть **блокирует чтение SSE-потока**.

**Почему важно.** Два эффекта: (а) ответ в группе визуально «залипает»,
(б) `AsyncThrowingStream` в `ssePayloads` и в адаптере созданы без
`bufferingPolicy` → **unbounded**, и всё, что провайдер успел прислать, копится в
памяти. Длинный ответ при двух параллельных генерациях в одной группе — заметный
всплеск RSS.

**Почему это в принципе лишнее:** лимит Telegram «20 сообщений в минуту на группу»
относится к **отправке**, `editMessageText` под него не подпадает.

**Варианты исправления.**
1. Не пропускать `editMessage` через per-chat ведро — только через глобальное
   (`waitForGlobalSlot`). Ретрай по `retry_after` уже есть в `with429Retry` и в
   самом цикле стриминга.
2. Отдельное ведро для правок (по аналогии с `globalDrafts`), например 6/с
   глобально, без per-chat ограничения.
3. Независимо от выбора: задать `bufferingPolicy: .bufferingNewest(N)` обоим
   `AsyncThrowingStream`, чтобы медленный консьюмер не мог раздуть память.

---

## 🟡 Стоит починить

### B14. Разбиение длинных сообщений считает символы до HTML-экранирования

**Где:** `Infrastructure/Telegram/TelegramHTTPGateway.swift:133-165`
(`sendMessage` режет `request.text`, а проверяет `html.count`),
`GenerationCoordinator.swift:705` и `:876` (`messageAccumulator.count >= charLimit`).

**Что происходит.** `MessageSplitter.split` режет **сырой** текст по 3896
символам, а `TelegramHTMLFormatter.helper` затем экранирует: `&` → `&amp;` (×5),
`<` → `&lt;` (×4). Кусок из ответа с кодом (`if (a < b && c > d)`) легко
перерастает 4096 → Telegram отвечает 400 «message is too long», и кусок ответа
теряется.

Побочно: разрез может пройти внутри тега — открывающий `<b>` останется в первом
сообщении (форматтер его закроет), а `</b>` во втором будет выброшен, форматирование
поедет.

**Варианты исправления.**
1. Разбивать по длине **после** экранирования: `helper(text:)` → потом
   `MessageSplitter.split` по результату. Требует, чтобы сплиттер не резал внутри
   сущности/тега — можно просто искать `\n`/пробел, как сейчас, но проверять, что
   позиция не внутри `<…>` и не внутри `&…;`.
2. Проще и достаточно на практике: снизить `charLimit` для сырого текста и
   добавить страховку — если `html.count > telegramMaxChars`, дорезать html-строку
   по последней безопасной позиции.

---

### B15. Кошелёк «доказанного плательщика» теряется при опознании человека

**Где:** `Domain/Chat/ChatContextStore.swift:426-438` (`adoptRecords`).

```swift
existing.balanceUsd += wallet.balanceUsd
existing.spentBilledUsd += wallet.spentBilledUsd
existing.spentRealUsd += wallet.spentRealUsd
// toppedUpUsd и lapsedNoticeAt не переносятся
```

**Что происходит.** При слиянии pending-кошелька (заведённого под голым ником) с
уже существующим `#<userID>` теряются `toppedUpUsd` и `lapsedNoticeAt`.

**Почему важно.** `toppedUpUsd > 0` — единственный признак «платил реальные
деньги» (CLAUDE.md §17). Его потеря выкидывает человека из аудитории «Возврат по
балансу» и искажает суперадминскую картину «кто клиент». Потеря `lapsedNoticeAt`
может привести к повторной отправке оффера.

**Исправление.** Дописать в слияние:
```swift
existing.toppedUpUsd += wallet.toppedUpUsd
existing.lapsedNoticeAt = existing.lapsedNoticeAt ?? wallet.lapsedNoticeAt
existing.updatedAt = [existing.updatedAt, wallet.updatedAt].compactMap { $0 }.max()
```

---

### B16. `keysHoldingState` не защищает всех, за кем что-то числится

**Где:** `Domain/Chat/ChatContextStore.swift:395-409`.

Учтены: тенанты, кошельки, владение чатами, суперадмины, инвайты, лицензии,
админы, пригласившие из реферала. **Не** учтены:
- `_cryptoInvoices.values.map(\.username)` — владельцы открытых инвойсов;
- `_simulatedRoles.keys`;
- `userTenantMap.values`;
- `referralLedgerValue.tallies.keys` (записи прунятся раньше тэлли).

**Почему важно.** При переполнении директории (>10 000) идентичность такого
человека может быть выброшена. Последствия: `openCryptoInvoiceForUser` перестаёт
находить его инвойс (он лежит под `#id`, а `userKey(username:)` теперь вернёт
голый ник), а в интерфейсе он превращается в `id 12345`.

**Исправление.** Дописать четыре `formUnion` в `keysHoldingState()`.

---

### B17. Winback-скидка перевыдаётся при каждой неудачной попытке доставки

**Где:** `Application/Lifecycle/SubscriptionReminderService.swift:243-249`.

**Что происходит.** `grantWinbackDiscount` вызывается **до** отправки. Если все
каналы вернули transient-ошибку, `deliver` возвращает `.failed`, отметка
`markNoticeSent` не ставится — и следующий свип выдаёт скидку заново, сбрасывая
48-часовое окно. Если все каналы оказались мёртвыми (`.noChannel`), скидка уже
выдана, а сообщение о ней не ушло вообще.

**Почему важно.** Скидка может тихо продлеваться неделями; человек, который
никогда её не видел, платит меньше.

**Исправление.** Выдавать скидку один раз на цикл: либо ставить отметку о выдаче
отдельно от отметки о доставке, либо в `grantWinbackDiscount` не перевыдавать,
если уже есть активная (`guard tenants[u]?.winbackDiscount?.isActive() != true`).

---

### B18. `firstFreeModel` недетерминирован — берётся `.first` у `Set`

> ✅ **Исправлено.** `firstFreeModel()` = первая закреплённая суперадмином,
> иначе `sorted().first`; `GenerationCoordinator` зовёт её вместо
> `effectiveFree.first`.

**Где:** `Domain/Chat/ChatContextStore.swift:1829-1831` (`firstFreeModel`),
`Application/Generation/GenerationCoordinator.swift:409` (`effectiveFree.first`).

**Что происходит.** `effectiveFreeModelIDs()` возвращает `Set<String>`; порядок
`.first` произволен и меняется между запусками и даже между вызовами после
мутаций. Порядок, заданный суперадмином в `_freeModelIDs`, полностью игнорируется.

**Почему важно.** Чат, упавший на бесплатную модель, каждый раз может получать
разную — качество ответов скачет без причины. И суперадмин не может выбрать, какая
модель служит запасной.

**Исправление.** Отдавать закреплённые модели по порядку:
```swift
func firstFreeModel() -> String? {
    if let pinned = _freeModelIDs.first { return pinned }
    return effectiveFreeModelIDs()?.sorted().first
}
```
и в `GenerationCoordinator` использовать `state.firstFreeModel()` вместо
`effectiveFree.first`.

---

### B19. Обещание бонуса при переходе по реф-ссылке использует не тот флаг

**Где:** `Application/Commands/BotCommandHandler.swift:400` — `config.paysAnything`.

`ReferralConfig` (`Domain/Chat/Referral.swift:68-73`) специально различает:
- `paysAnything` — включая бонус за оплату друга;
- `paysOnSignup` — только награды за регистрацию.

При `inviterRewardCents == 0 && inviteeRewardCents == 0 && payingFriendBonusCents > 0`
пользователю печатается «на ваш баланс придёт **$0.00**». `paysOnSignup` заведён
ровно под этот случай и используется в меню (`BotMenuHandler.swift:3572`), но не
здесь.

**Исправление.** Заменить `config.paysAnything` на `config.paysOnSignup` в строке 400.

---

### B20. `/help` обещает, что для покупки нужен @username

**Где:** `Application/Callbacks/BotCallbackHandler.swift:131`.

> «Для покупки нужен `@username` — задайте его в настройках Telegram, если ещё нет.»

Прямо противоречит §6 CLAUDE.md и реальному коду: покупатель определяется по
`userKey(userID:)` (`BotCommandHandler.swift:2409-2410`,
`BotMenuHandler.swift:2360, 2388`), а `renderPay:2209` даже пишет обратное —
«@username для этого не нужен».

**Почему важно.** Текст отговаривает часть людей от покупки на ровном месте.

**Исправление.** Убрать предложение. Заодно проверить длину: сейчас `faqText`
= 3853 символа при `MessageSplitter.charLimit` = 3896 — запас 43 символа, любая
правка легко выведет справку за лимит и она приедет двумя сообщениями
(предупреждение в §17). Удаление этой фразы даёт нужный запас.

---

### B21. Пополнение баланса криптой отключается вместе с ценой подписки

**Где:** `Application/Menu/BotMenuHandler.swift:2249` и `:2292-2297`.

```swift
let cryptoCents = await state.cryptoPriceUsdCents()
if cryptoCents != nil, !cryptoAssets.isEmpty { ... кнопка "🪙 Криптой" ... }
```

Пакет кредитов стоит свою номинальную сумму (`CryptoPaymentService.swift:81-83`,
ветка `.credit`), цена подписки для него не нужна. Но доступность кнопки
завязана именно на неё.

**Почему важно.** CLAUDE.md §7: «У каждого способа свой выключатель… Раньше пакеты
исчезали вместе с выключенной подпиской — это убивало самый дешёвый вход». Для
Stars и карты это починили, для крипты — нет.

**Исправление.** Условие для крипто-пакетов — только `!cryptoAssets.isEmpty`
(наличие адресов). Убрать `cryptoCents != nil` в обоих местах.

---

### B22. Гейты ролей в меню ломаются у человека без @username

**Где:** `Application/Menu/BotMenuHandler.swift` — 32 использования
`callback.from.username`, из них критичны `:533` (`isSuperAdmin`), `:548`
(`isAdmin`), `:1032/1041` (`isRootSuperAdmin`), `:1106/1110` (`/simulate`),
`:2816` (превью напоминаний).

**Что происходит.** `isSuperAdmin(username: nil)` → `userKey(username: nil)` → nil
→ `false`. Суперадмин без ника теряет доступ к панели, хотя в сторе он лежит под
`#<userID>`.

**Почему важно.** §6 прямо утверждает, что @username больше не нужен. В
`processTextInput` (строка 98) и в `handleTenantAction` (строка 3097) это уже
исправлено — гейты остались непочиненными.

**Исправление.** Ввести в начале `processAction`
`let invokerKey = state.userKey(userID: callback.from.id)` и заменить все
`username: callback.from.username` на `username: invokerKey` (ключи проходят
резолв без изменений). Строку 1110 (`guard let username = callback.from.username`)
переписать на userID.

---

### B23. Проверка «это моя же пригласительная ссылка» не работает без ника

**Где:** `Application/Commands/BotCommandHandler.swift:573`.

```swift
if await state.userKey(username: fromUser?.username) == owner {
```

При отсутствии ника слева `nil`, справа `#id` → человек «активирует» собственный
инвайт: добавляет сам себя в `licensedUsernames` своего же тенанта и получает
сообщение «Приглашение от вас активировано». Безвредно, но выглядит как поломка.

**Исправление.** Сравнивать по списку кандидатов:
`await state.userKeys(username: fromUser?.username, userID: fromUser?.id).contains(owner)`.

---

## ⚪ Мелочи и технический долг

### B24. Суперадмины не исключены из рассылки «Возврат по балансу»

**Где:** `Domain/Chat/ChatContextStore.swift:3141-3170` (`dueWalletWinbacks`).

`dueSubscriptionNotices` (строка 706) и `subscriptionLifecycleStats` (строка 867)
явно фильтруют `!superAdminUsernames.contains(owner)` — «владельцу бота не продают
его же продукт». Для кошельков фильтра нет: суперадмин, пополнивший баланс для
теста и потративший его, получит «👋 Давно вас не было».

**Исправление.** Добавить `guard !superAdminUsernames.contains(key) else { continue }`.

---

### B25. Апдейты, принятые webhook'ом, теряются при выключении

**Где:** `App/LLM_chat_bot.swift:223-224` — `await intake.enqueue([update])` и
сразу `return .ok("")`; `BotOrchestrator.shutdown():266-269` ждёт только
`sessionRegistry.activeCount`, но не очередь `ChatUpdateDispatcher`.

**Что происходит.** Telegram получил 200 и считает апдейт доставленным. Всё, что
лежит в `updateDispatcher` (до 16 на чат) и в `albumBuffer` (holdback 750 мс), при
SIGTERM просто исчезает.

**Почему важно.** Заявленный «редеплой без потерь» (§11) держится только на том,
что окно узкое. Ущерб — потерянное сообщение пользователя, без следа.

**Варианты.** В `shutdown()` дождаться `updateDispatcher.totalQueuedOperations == 0`
(с тем же 8-секундным дедлайном, что и для генераций) и позвать
`intake.shutdown()` до этого, чтобы буфер альбомов слил остаток.

*Мелочь рядом:* доккомментарий `UpdateIntake` говорит про holdback 300 мс, а
`TelegramPhotoAlbumBuffer` использует 0.75 с (флаш-таск тикает каждые 300 мс, так
что альбом реально уезжает через ~900 мс). Расхождение с CLAUDE.md §4/§11.

---

### B26. `activeCount` падает до нуля до завершения отменённой генерации

**Где:** `Application/SessionRegistry.swift:36-45` — `cancel` удаляет сессию сразу,
не дожидаясь, пока стрим-таск домотает `finishGeneration`.

**Почему важно.** `shutdown()` ждёт `activeCount > 0`; если в момент выключения
кто-то нажал «Стоп», счётчик уже 0 и процесс не подождёт запись ответа в историю.
Окно крошечное, но бесплатно закрывается.

**Исправление.** В `cancel` не удалять сессию, а помечать её отменённой; удаление
оставить `finish`.

---

### B27. Мелкие несоответствия текстов и поведения

Все — низкий приоритет, чинятся за одну правку каждая.

1. **`ModelPriceMonitor.swift:107`** — «При следующем сообщении будет автоматически
   выбрана бесплатная модель». Неправда: подмена происходит только при исчерпанном
   дневном лимите и только у пользователей без доступа (`GenerationCoordinator:404`).
2. **`ModelPriceMonitor.swift:88`** → `superAdminPrivateChats()`
   (`ChatContextStore.swift:2158`) возвращает не «личку суперадминов», а чаты,
   привязанные к root-тенанту. Если личка root не привязана (а `autoAssignIfNeeded`
   срабатывает только для тенантов), уведомление о закреплённой платной модели не
   уходит никому.
3. **`BotOrchestrator.route:628`** — `text.hasPrefix("/buy") || text.hasPrefix("/start")`
   ловит и `/buying`, и `/startsomething`, пропуская их мимо access-gate. Стоит
   использовать уже готовый `CommandParser` вместо префикса.
4. **`BotOrchestrator.run:193-196`** — при неудачном `setWebhook` уходим в polling,
   но `deleteWebhook()` не зовём. Telegram продолжит долбиться в URL, а `getUpdates`
   будет возвращать ошибку «terminated by other getUpdates request / webhook is active».
5. **`GenerationCoordinator.processContent:454-464`** — typing-индикатор гасится
   `defer` сразу после `streamReply` (то есть после старта таска), так что реально
   он работает только пока ждём слот лимитера. Не баг, но комментарий §9 создаёт
   впечатление, что typing идёт всю генерацию.
6. **`runEditStreaming.splitAndContinue:851-853`** — если не удалось отправить
   сообщение-продолжение, бросается `CancellationError`, и пользователь видит
   «⏹ Остановлено», хотя ничего не останавливал.
7. **`Domain/Chat/UserBalance.swift:3`** — доккомментарий «keyed by lowercased
   @username» устарел после перехода на `UserKey`.

---

## Что проверено и оказалось в порядке

Чтобы в следующей сессии не перечитывать заново:

- `PersistenceCoordinator.flushOnce` — гонки нет: между проверкой `while flushing`
  и `flushing = true` нет `await`, актор атомарен.
- `GenerationLimiter` — слот освобождается ровно один раз, `finishGeneration`
  вызывается на всех путях (проверены обе ветки стриминга и оба `catch`).
- `refundDailyPremium` вызывается только при наличии `premiumTicket`, то есть
  только если порция реально была потрачена — «чужой» счётчик не уменьшается.
- Идемпотентность Stars/карты (`processedPaymentChargeIDs`) и крипты
  (`creditedTxHashes`) — корректна.
- `dueNotice` — волны выбираются правильно: до истечения ближайшая, после —
  самая поздняя открытая; legacy-ключ `expiring` учтён.
- Реферальная выплата — кредит балансов и `rewardedAt` в одном шаге актора,
  двойной выплаты быть не может.
- `FunnelDailyLog.prune` считает окно от реального «сегодня», а не от времени
  записи.
- `UpdateDeduplicator` (кольцо 2048 + `Set`) — корректен.
- `TelegramHTTPGateway.sanitizeFilePath` — path traversal закрыт.
