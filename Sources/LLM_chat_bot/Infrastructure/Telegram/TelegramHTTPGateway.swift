import Foundation

struct TelegramAPIError: Error, LocalizedError {
    let action: String
    let statusCode: Int
    let descriptionText: String
    let retryAfter: Int?
    let migrateToChatID: Int64?
    let rawBody: String
    
    var errorDescription: String? {
        var parts: [String] = ["\(action) failed: \(descriptionText)", "HTTP \(statusCode)"]
        if let retryAfter { parts.append("retry_after=\(retryAfter)") }
        if let migrateToChatID { parts.append("migrate_to_chat_id=\(migrateToChatID)") }
        return parts.joined(separator: " | ")
    }
}

final class TelegramHTTPGateway: TelegramGatewayPort, @unchecked Sendable {
    private let network: NetworkClient
    private let telegramURL: String
    private let botToken: String
    private let rateLimiter: TelegramRateLimiter?
    private let metrics: RuntimeMetrics?

    init(
        network: NetworkClient,
        botToken: String,
        rateLimiter: TelegramRateLimiter? = nil,
        metrics: RuntimeMetrics? = nil
    ) {
        self.network = network
        self.botToken = botToken
        self.telegramURL = "https://api.telegram.org/bot\(botToken)"
        self.rateLimiter = rateLimiter
        self.metrics = metrics
    }

    /// `allowed_updates` as a percent-encoded JSON array, ready for a query
    /// string. Built once: the list never changes at runtime.
    private static let encodedAllowedUpdates: String = {
        let json = "[" + TelegramUpdateSubscription.allowedUpdates.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        // Only unreserved characters survive — brackets, quotes and commas all
        // have to be escaped for Telegram to parse the array.
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return json.addingPercentEncoding(withAllowedCharacters: unreserved) ?? json
    }()

    /// Retries a Telegram call that failed with 429, honoring `retry_after`.
    /// Centralizes what used to be scattered per-call-site retry loops.
    private func with429Retry<T>(attempts: Int = 3, _ op: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await op()
            } catch let error as TelegramAPIError where error.retryAfter != nil {
                await metrics?.increment(MetricName.telegramRateLimited)
                attempt += 1
                guard attempt < attempts else { throw error }
                let delay = min(error.retryAfter ?? 1, 30)
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    func deleteWebhook() async throws {
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/deleteWebhook",
            method: .post,
            timeoutSeconds: 10,
            maxBodyBytes: 1 << 18,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "deleteWebhook", statusCode: raw.statusCode, data: raw.data)
    }

    func setWebhook(url: String, secretToken: String, allowedUpdates: [String]) async throws {
        struct Body: Codable {
            let url: String
            let secret_token: String
            let allowed_updates: [String]
            let max_connections: Int
            let drop_pending_updates: Bool
        }
        let body = Body(
            url: url,
            secret_token: secretToken,
            allowed_updates: allowedUpdates,
            max_connections: 40,
            drop_pending_updates: false
        )
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/setWebhook",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 15,
            maxBodyBytes: 1 << 18,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "setWebhook", statusCode: raw.statusCode, data: raw.data)
    }

    func decodeIncomingUpdate(_ data: Data) throws -> TelegramUpdate {
        let decoded = try JSONDecoder().decode(TelegramAPIUpdate.self, from: data)
        return map(decoded)
    }
    
    func getMe() async throws -> TelegramUser {
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/getMe",
            method: .get,
            timeoutSeconds: 35,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        let decoded: TelegramResponse<TelegramAPIUser> = try decodeEnvelope(action: "getMe", statusCode: raw.statusCode, data: raw.data)
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "getMe", statusCode: raw.statusCode, data: raw.data)
        }
        return map(result)
    }
    
    func getUpdates(offset: Int?) async throws -> [TelegramUpdate] {
        // Same subscription the webhook registers: without an explicit list
        // Telegram drops `my_chat_member` from long polling entirely.
        let allowed = Self.encodedAllowedUpdates
        let url = "\(telegramURL)/getUpdates?timeout=30&offset=\(offset ?? 0)&allowed_updates=\(allowed)"
        let spec = HTTPRequestSpec(url: url, method: .get, timeoutSeconds: 35, validStatusCodes: 100..<600)
        let raw = try await network.perform(spec)
        
        let decoded: TelegramResponse<[TelegramAPIUpdate]> = try decodeEnvelope(
            action: "getUpdates",
            statusCode: raw.statusCode,
            data: raw.data
        )
        
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "getUpdates", statusCode: raw.statusCode, data: raw.data)
        }
        return result.map(map)
    }
    
    func sendMessage(_ request: SendMessageRequest) async throws -> TelegramMessage {
        let html = TelegramHTMLFormatter.helper(text: request.text)
        if html.count <= MessageSplitter.charLimit {
            return try await sendSingle(request, html: html)
        }
        var remaining = request.text
        var lastMessage: TelegramMessage?
        var isFirst = true
        while !remaining.isEmpty {
            let chunk: String
            if remaining.count <= MessageSplitter.charLimit {
                chunk = remaining
                remaining = ""
            } else {
                let (done, rest) = MessageSplitter.split(remaining)
                chunk = done
                remaining = rest
            }
            let chunkRequest = SendMessageRequest(
                chatID: request.chatID,
                threadID: request.threadID,
                replyTo: isFirst ? request.replyTo : nil,
                text: chunk,
                replyMarkup: isFirst ? request.replyMarkup : nil
            )
            lastMessage = try await sendSingle(chunkRequest, html: TelegramHTMLFormatter.helper(text: chunk))
            isFirst = false
        }
        guard let lastMessage else {
            return try await sendSingle(request, html: html)
        }
        return lastMessage
    }

    private func sendSingle(_ request: SendMessageRequest, html: String) async throws -> TelegramMessage {
        let body = TelegramSendMessageBody(
            chat_id: request.chatID,
            text: html,
            reply_parameters: request.replyTo.map { ReplyParameters(message_id: $0) },
            message_thread_id: request.threadID,
            parse_mode: "HTML",
            reply_markup: request.replyMarkup
        )

        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/sendMessage",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            validStatusCodes: 100..<600
        )

        await rateLimiter?.waitForMessageSlot(chatID: request.chatID)
        return try await with429Retry {
            let raw = try await network.perform(spec)
            let decoded: TelegramResponse<TelegramAPIMessage> = try decodeEnvelope(
                action: "sendMessage",
                statusCode: raw.statusCode,
                data: raw.data
            )

            guard decoded.ok, let result = decoded.result else {
                throw buildTelegramError(action: "sendMessage", statusCode: raw.statusCode, data: raw.data)
            }

            return map(result)
        }
    }
    
    func editMessage(_ request: EditMessageRequest) async throws {
        let body = TelegramEditMessageTextBody(
            chat_id: request.chatID,
            message_id: request.messageID,
            text: TelegramHTMLFormatter.helper(text: request.text),
            parse_mode: "HTML",
            reply_markup: request.replyMarkup
        )
        
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/editMessageText",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            maxBodyBytes: 1 << 20,
            validStatusCodes: 100..<600
        )

        await rateLimiter?.waitForMessageSlot(chatID: request.chatID)
        try await with429Retry {
            let raw = try await network.perform(spec)
            try validateTelegramEnvelope(action: "editMessageText", statusCode: raw.statusCode, data: raw.data)
        }
    }
    
    func sendMessageDraft(_ request: SendMessageDraftRequest) async throws {
        // Drafts are cosmetic previews: when the shared draft budget is spent,
        // fail fast with a synthetic retry_after so DraftStreamer backs off
        // one tick instead of queueing. The initial empty draft (generation
        // start) always goes through — it happens once and drives the
        // draft-capability probe.
        if let rateLimiter, !request.text.isEmpty {
            guard await rateLimiter.tryTakeDraftSlot() else {
                throw TelegramAPIError(
                    action: "sendMessageDraft",
                    statusCode: 429,
                    descriptionText: "local draft budget exhausted",
                    retryAfter: 1,
                    migrateToChatID: nil,
                    rawBody: ""
                )
            }
        }
        let body = TelegramSendMessageDraftBody(
            chat_id: request.chatID,
            message_thread_id: request.threadID,
            draft_id: request.draftID,
            text: request.text.isEmpty ? "" : TelegramHTMLFormatter.helper(text: request.text),
            parse_mode: request.text.isEmpty ? nil : "HTML"
        )

        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/sendMessageDraft",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            maxBodyBytes: 1 << 20,
            validStatusCodes: 100..<600
        )

        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "sendMessageDraft", statusCode: raw.statusCode, data: raw.data)
    }

    func deleteMessage(chatID: Int, messageID: Int) async throws {
        let body = TelegramDeleteMessageBody(chat_id: chatID, message_id: messageID)
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/deleteMessage",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 10,
            maxBodyBytes: 1 << 18,
            validStatusCodes: 100..<600
        )
        await rateLimiter?.waitForGlobalSlot()
        try await with429Retry {
            let raw = try await network.perform(spec)
            try validateTelegramEnvelope(action: "deleteMessage", statusCode: raw.statusCode, data: raw.data)
        }
    }

    func sendChatAction(chatID: Int, threadID: Int64?, action: String) async throws {
        // Typing indicators are cosmetic: skip silently under load.
        if let rateLimiter {
            guard await rateLimiter.tryTakeCosmeticSlot() else { return }
        }
        struct Body: Codable {
            let chat_id: Int
            let action: String
            let message_thread_id: Int64?
        }
        let body = Body(chat_id: chatID, action: action, message_thread_id: threadID)
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/sendChatAction",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 10,
            maxBodyBytes: 1 << 18,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "sendChatAction", statusCode: raw.statusCode, data: raw.data)
    }

    func answerCallback(callbackQueryID: String, text: String?) async throws {
        let body = AnswerCallbackQueryBody(
            callback_query_id: callbackQueryID,
            text: text,
            show_alert: nil
        )

        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/answerCallbackQuery",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            maxBodyBytes: 1 << 20,
            validStatusCodes: 100..<600
        )

        await rateLimiter?.waitForGlobalSlot()
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "answerCallbackQuery", statusCode: raw.statusCode, data: raw.data)
    }
    
    func getFile(fileID: String) async throws -> TelegramFile {
        struct GetFileBody: Codable {
            let file_id: String
        }
        
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/getFile",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(GetFileBody(file_id: fileID))),
            timeoutSeconds: 35,
            validStatusCodes: 100..<600
        )
        
        let raw = try await network.perform(spec)
        let decoded: TelegramResponse<TelegramAPIFile> = try decodeEnvelope(
            action: "getFile",
            statusCode: raw.statusCode,
            data: raw.data
        )
        
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "getFile", statusCode: raw.statusCode, data: raw.data)
        }
        
        return map(result)
    }
    
    func downloadFile(filePath: String) async throws -> Data {
        let safePath = try Self.sanitizeFilePath(filePath)
        let spec = HTTPRequestSpec(
            url: "https://api.telegram.org/file/bot\(botToken)/\(safePath)",
            method: .get,
            timeoutSeconds: 35,
            maxBodyBytes: 20 << 20,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        guard (200..<300).contains(raw.statusCode) else {
            throw buildTelegramError(action: "downloadFile", statusCode: raw.statusCode, data: raw.data)
        }
        return raw.data
    }
    
    private static func sanitizeFilePath(_ filePath: String) throws -> String {
        let segments = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for segment in segments {
            guard !segment.isEmpty, segment != "." , segment != ".." else {
                throw TelegramAPIError(
                    action: "downloadFile",
                    statusCode: 0,
                    descriptionText: "Invalid file_path",
                    retryAfter: nil,
                    migrateToChatID: nil,
                    rawBody: ""
                )
            }
            guard segment.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw TelegramAPIError(
                    action: "downloadFile",
                    statusCode: 0,
                    descriptionText: "Invalid file_path",
                    retryAfter: nil,
                    migrateToChatID: nil,
                    rawBody: ""
                )
            }
        }
        return segments.joined(separator: "/")
    }

    func sendInvoice(_ request: SendInvoiceRequest) async throws {
        let currency: String
        let amount: Int
        let providerToken: String
        switch request.kind {
        case .stars(let starsAmount):
            currency = "XTR"
            amount = starsAmount
            providerToken = ""
        case .fiat(let fiatCurrency, let minorUnits, let token):
            currency = fiatCurrency
            amount = minorUnits
            providerToken = token
        }
        let body = TelegramSendInvoiceBody(
            chat_id: request.chatID,
            title: request.title,
            description: request.description,
            payload: request.payload,
            currency: currency,
            prices: [TelegramLabeledPrice(label: request.title, amount: amount)],
            provider_token: providerToken
        )
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/sendInvoice",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            validStatusCodes: 100..<600
        )
        await rateLimiter?.waitForMessageSlot(chatID: request.chatID)
        try await with429Retry {
            let raw = try await network.perform(spec)
            try validateTelegramEnvelope(action: "sendInvoice", statusCode: raw.statusCode, data: raw.data)
        }
    }

    func answerPreCheckoutQuery(queryID: String, ok: Bool, errorMessage: String?) async throws {
        let body = TelegramAnswerPreCheckoutQueryBody(
            pre_checkout_query_id: queryID,
            ok: ok,
            error_message: errorMessage
        )
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/answerPreCheckoutQuery",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 10,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "answerPreCheckoutQuery", statusCode: raw.statusCode, data: raw.data)
    }

    private func decodeEnvelope<T: Decodable>(action: String, statusCode: Int, data: Data) throws -> TelegramResponse<T> {
        do {
            return try JSONDecoder().decode(TelegramResponse<T>.self, from: data)
        } catch {
            throw buildTelegramError(action: action, statusCode: statusCode, data: data)
        }
    }
    
    private func validateTelegramEnvelope(action: String, statusCode: Int, data: Data) throws {
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data), !decoded.ok {
            throw buildTelegramError(action: action, statusCode: statusCode, data: data)
        }
        if !(200..<300).contains(statusCode) {
            throw buildTelegramError(action: action, statusCode: statusCode, data: data)
        }
    }
    
    private func buildTelegramError(action: String, statusCode: Int, data: Data) -> TelegramAPIError {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data) {
            return TelegramAPIError(
                action: action,
                statusCode: decoded.error_code ?? statusCode,
                descriptionText: decoded.description ?? "Telegram returned an unknown error",
                retryAfter: decoded.parameters?.retry_after,
                migrateToChatID: decoded.parameters?.migrate_to_chat_id,
                rawBody: raw
            )
        }
        
        return TelegramAPIError(
            action: action,
            statusCode: statusCode,
            descriptionText: "Invalid Telegram response",
            retryAfter: nil,
            migrateToChatID: nil,
            rawBody: raw
        )
    }
    
    // пока не знаю насколько это правильно, но хочется отделить внешний api от внутренних типов
    
    private func map(_ update: TelegramAPIUpdate) -> TelegramUpdate {
        TelegramUpdate(
            update_id: update.update_id,
            message: update.message.map(map),
            callback_query: update.callback_query.map(map),
            pre_checkout_query: update.pre_checkout_query.map(map),
            my_chat_member: update.my_chat_member.map(map)
        )
    }

    private func map(_ member: TelegramAPIChatMemberUpdated) -> ChatMemberUpdate {
        ChatMemberUpdate(
            chat: map(member.chat),
            from: map(member.from),
            oldStatus: member.old_chat_member.status,
            newStatus: member.new_chat_member.status
        )
    }
    
    private func map(_ message: TelegramAPIMessage) -> TelegramMessage {
        TelegramMessage(
            message_id: message.message_id,
            from: message.from.map(map),
            chat: map(message.chat),
            date: message.date,
            text: message.text,
            caption: message.caption,
            voice: message.voice.map(map),
            video: message.video.map(map),
            message_thread_id: message.message_thread_id,
            media_group_id: message.media_group_id,
            reply_to_message: message.reply_to_message.map(map),
            photo: message.photo?.map(map),
            successful_payment: message.successful_payment.map(map)
        )
    }

    private func map(_ preCheckout: TelegramAPIPreCheckoutQuery) -> TelegramPreCheckoutQuery {
        TelegramPreCheckoutQuery(
            id: preCheckout.id,
            from: map(preCheckout.from),
            currency: preCheckout.currency,
            total_amount: preCheckout.total_amount,
            invoice_payload: preCheckout.invoice_payload
        )
    }

    private func map(_ payment: TelegramAPISuccessfulPayment) -> TelegramSuccessfulPayment {
        TelegramSuccessfulPayment(
            currency: payment.currency,
            total_amount: payment.total_amount,
            invoice_payload: payment.invoice_payload,
            telegram_payment_charge_id: payment.telegram_payment_charge_id,
            provider_payment_charge_id: payment.provider_payment_charge_id
        )
    }
    
    private func map(_ callback: TelegramAPICallbackQuery) -> CallbackQuery {
        CallbackQuery(
            id: callback.id,
            from: map(callback.from),
            data: callback.data,
            message: callback.message.map(map)
        )
    }
    
    private func map(_ message: TelegramAPIMaybeInaccessibleMessage) -> MaybeInaccessibleMessage {
        MaybeInaccessibleMessage(
            chat: map(message.chat),
            message_id: message.message_id,
            date: message.date,
            text: message.text,
            message_thread_id: message.message_thread_id
        )
    }
    
    private func map(_ user: TelegramAPIUser) -> TelegramUser {
        TelegramUser(
            id: user.id,
            is_bot: user.is_bot,
            first_name: user.first_name,
            username: user.username
        )
    }
    
    private func map(_ chat: TelegramAPIChat) -> TelegramChat {
        TelegramChat(
            id: chat.id,
            type: chat.type,
            title: chat.title,
            username: chat.username,
            first_name: chat.first_name
        )
    }
    
    private func map(_ voice: TelegramAPIVoice) -> TelegramVoice {
        TelegramVoice(
            file_id: voice.file_id,
            file_unique_id: voice.file_unique_id,
            duration: voice.duration,
            mime_type: voice.mime_type,
            file_size: voice.file_size
        )
    }
    
    private func map(_ video: TelegramAPIVideo) -> TelegramVideo {
        TelegramVideo(
            file_id: video.file_id,
            file_unique_id: video.file_unique_id,
            width: video.width,
            height: video.height,
            duration: video.duration,
            mime_type: video.mime_type,
            file_size: video.file_size
        )
    }
    
    private func map(_ photo: TelegramAPIPhotoSize) -> PhotoSize {
        PhotoSize(
            file_id: photo.file_id,
            file_unique_id: photo.file_unique_id,
            width: photo.width,
            height: photo.height,
            file_size: photo.file_size
        )
    }
    
    private func map(_ file: TelegramAPIFile) -> TelegramFile {
        TelegramFile(
            file_id: file.file_id,
            file_unique_id: file.file_unique_id,
            file_size: file.file_size,
            file_path: file.file_path
        )
    }
}
