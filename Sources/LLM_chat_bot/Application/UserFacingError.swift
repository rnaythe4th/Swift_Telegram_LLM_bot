import Foundation

enum UserFacingError {
    static let alertCharLimit = 190
    private static let bodyPreviewLimit = 350

    static func message(_ error: Error, context: String? = nil) -> String {
        let body = describe(error)
        let text: String
        if let context, !context.isEmpty {
            text = "\(context): \(body)"
        } else {
            text = body
        }
        // Belt and braces for the unrecognised-error branches below, which
        // print whatever an arbitrary `Error` chose to say: a request URL in
        // there would carry the bot token straight into a chat.
        return SecretRedactor.shared.redact(text)
    }

    static func shortMessage(_ error: Error, context: String? = nil) -> String {
        let full = message(error, context: context)
        return truncate(full, limit: alertCharLimit)
    }

    private static func describe(_ error: Error) -> String {
        if error is CancellationError {
            return "Операция отменена"
        }

        if let transport = error as? NetworkTransportError {
            return describeTransport(transport)
        }

        if let telegram = error as? TelegramAPIError {
            return describeTelegram(telegram)
        }

        if let registry = error as? ProviderGatewayRegistryError {
            switch registry {
            case .missingAdapter(let provider):
                return "Сервис \(provider.commandValue) не настроен. Выберите другой в /menu → 🔌 Сервис ИИ."
            }
        }

        if let media = error as? TelegramMediaResolverError {
            switch media {
            case .missingFilePath:
                return "Telegram не отдал файл. Попробуйте отправить его ещё раз."
            }
        }

        // Payment errors are already written for the payer ("все счета заняты,
        // выберите другую монету") — wrapping them in "Что-то пошло не так,
        // подробности:" buries the one sentence that says what to do next.
        if let crypto = error as? CryptoPaymentError, let text = crypto.errorDescription {
            return text
        }

        if let adapter = error as? ProviderAdapterError {
            switch adapter {
            case .invalidRequestType(let provider):
                return "Сбой при обращении к сервису \(provider.commandValue). Попробуйте ещё раз или смените сервис в /menu."
            case .upstream(_, let code, _):
                // The provider's own wording is English (and often internal):
                // the code is what carries actionable meaning, and it already
                // has a Russian phrasing here. The raw detail stays in the logs.
                if let code {
                    return httpStatusReason(code)
                }
                return "Сервис ИИ прервал ответ. Попробуйте ещё раз или выберите другую модель в /menu → 🤖 Модель."
            case .idleTimeout:
                return "Сервис ИИ перестал отвечать на середине. Попробуйте ещё раз — ответ не потрачен."
            }
        }

        // Anything we don't recognise would leak an English provider/runtime
        // description straight into a Russian chat — wrap it so the user still
        // gets an actionable sentence, with the raw detail kept for support.
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return "Что-то пошло не так — попробуйте ещё раз. Подробности: \(truncate(localized, limit: bodyPreviewLimit))"
        }

        return "Что-то пошло не так — попробуйте ещё раз. Подробности: \(truncate("\(error)", limit: bodyPreviewLimit))"
    }

    private static func describeTransport(_ error: NetworkTransportError) -> String {
        switch error {
        case .invalidStatus(let response):
            // Only the status reason, which is written for this audience and in
            // Russian. The upstream body used to be pasted in verbatim: that is
            // English provider jargon at best, and at worst it echoes whatever
            // the service chose to put in an error — request fragments, account
            // identifiers, key prefixes — into a user's chat. The full body is
            // still logged, where support can read it.
            return httpStatusReason(response.statusCode)

        case .decodeFailure:
            return "Сервис ИИ ответил непонятно. Попробуйте ещё раз."

        case .streamOverflow:
            return "Сервис ИИ прислал повреждённый ответ. Попробуйте ещё раз или выберите другую модель в /menu → 🤖 Модель."

        case .encodeFailure:
            return "Не удалось отправить запрос. Попробуйте ещё раз."
        }
    }

    private static func describeTelegram(_ error: TelegramAPIError) -> String {
        var parts: [String] = ["Telegram: \(error.descriptionText)"]
        if let retry = error.retryAfter {
            parts.append("повторите через \(retry) сек")
        }
        return parts.joined(separator: ". ")
    }

    private static func httpStatusReason(_ code: Int) -> String {
        switch code {
        case 400: return "Сервис ИИ не принял запрос (400)"
        case 401: return "Сервис ИИ отклонил запрос — напишите администратору бота (401)"
        case 402: return "У бота закончились средства у сервиса ИИ — сообщите администратору (402)"
        case 403: return "Сервис ИИ закрыл доступ — напишите администратору бота (403)"
        case 404: return "Такой модели нет — выберите другую в /menu → 🤖 Модель (404)"
        case 408: return "Сервис ИИ не ответил вовремя — попробуйте ещё раз (408)"
        case 413: return "Слишком большой запрос — сократите текст или вложение (413)"
        case 415: return "Такой файл не поддерживается (415)"
        case 422: return "Сервис ИИ не принял запрос — попробуйте переформулировать (422)"
        case 429: return "Слишком много запросов подряд — попробуйте через минуту (429)"
        case 500...599: return "Сервис ИИ временно недоступен — попробуйте позже (\(code))"
        default: return "Сбой на стороне сервиса ИИ (\(code))"
        }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return text[..<endIndex] + "…"
    }
}
