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
                return "Провайдер \(provider.commandValue) не настроен. Выберите другой через /menu."
            }
        }

        if let media = error as? TelegramMediaResolverError {
            switch media {
            case .missingFilePath:
                return "Telegram не отдал файл. Попробуйте отправить медиа ещё раз."
            }
        }

        if let adapter = error as? ProviderAdapterError {
            switch adapter {
            case .invalidRequestType(let provider):
                return "Внутренний сбой адаптера \(provider.commandValue). Сообщите администратору."
            }
        }

        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }

        return "\(error)"
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
            return "Не удалось разобрать ответ сервера. Попробуйте ещё раз."

        case .encodeFailure:
            return "Не удалось подготовить запрос. Попробуйте ещё раз."
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
        case 400: return "Некорректный запрос (HTTP 400)"
        case 401: return "Неверный или отсутствующий API-ключ (HTTP 401)"
        case 402: return "Недостаточно средств на счёте провайдера (HTTP 402)"
        case 403: return "Доступ запрещён (HTTP 403)"
        case 404: return "Ресурс не найден, возможно неверная модель (HTTP 404)"
        case 408: return "Таймаут на стороне провайдера (HTTP 408)"
        case 413: return "Запрос слишком большой (HTTP 413)"
        case 415: return "Формат вложения не поддерживается (HTTP 415)"
        case 422: return "Запрос отклонён валидацией (HTTP 422)"
        case 429: return "Превышен лимит запросов (HTTP 429)"
        case 500...599: return "Провайдер временно недоступен (HTTP \(code))"
        default: return "Ошибка сервера HTTP \(code)"
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
