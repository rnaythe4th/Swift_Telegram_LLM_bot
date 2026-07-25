import Foundation

enum UserFacingError {
    static let alertCharLimit = 190
    private static let bodyPreviewLimit = 350

    static func message(_ error: Error, context: String? = nil) -> String {
        let body = describe(error)
        guard let context, !context.isEmpty else { return body }
        return "\(context): \(body)"
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
            let bodyText = String(data: response.data, encoding: .utf8) ?? ""
            let parsed = parseAPIErrorMessage(from: response.data, bodyText: bodyText)
            let statusReason = httpStatusReason(response.statusCode)

            if let parsed, !parsed.isEmpty {
                return "\(statusReason). \(parsed)"
            }

            let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return statusReason
            }
            return "\(statusReason). \(truncate(trimmed, limit: bodyPreviewLimit))"

        case .decodeFailure:
            return "Сервис ИИ ответил непонятно. Попробуйте ещё раз."

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

    private static func parseAPIErrorMessage(from data: Data, bodyText: String) -> String? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        if let dict = json as? [String: Any] {
            if let value = extractMessage(from: dict) { return value }
        }

        if let array = json as? [[String: Any]] {
            for entry in array {
                if let value = extractMessage(from: entry) { return value }
            }
        }

        return nil
    }

    private static func extractMessage(from dict: [String: Any]) -> String? {
        if let errorField = dict["error"] {
            if let str = errorField as? String, !str.isEmpty { return str }
            if let nested = errorField as? [String: Any] {
                if let value = pickString(nested, keys: ["message", "description", "detail"]) {
                    return value
                }
                if let metadata = nested["metadata"] as? [String: Any],
                   let raw = metadata["raw"] as? String,
                   !raw.isEmpty {
                    return raw
                }
            }
        }

        if let value = pickString(dict, keys: [
            "description",
            "message",
            "error_description",
            "detail",
            "msg",
            "errorMessage"
        ]) {
            return value
        }

        if let parameters = dict["parameters"] as? [String: Any],
           let value = pickString(parameters, keys: ["description", "message"]) {
            return value
        }

        return nil
    }

    private static func pickString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return text[..<endIndex] + "…"
    }
}
