import Foundation

enum ResponseFooterFormatter {
    static func formatFooter(
        meta: StreamMeta?,
        fallbackModel: String,
        showTokens: Bool,
        showCost: Bool,
        showModel: Bool
    ) -> String? {
        guard showTokens || showCost || showModel else { return nil }

        let usage = meta?.usage
        var lines: [String] = []

        if showTokens {
            lines.append(contentsOf: tokenLines(usage: usage))
        }

        if showCost {
            if let cost = usage?.cost {
                lines.append("💵 $\(formatCost(cost))")
            } else {
                lines.append("💵 —")
            }
        }

        if showModel {
            lines.append("🤖 <code>\(meta?.model ?? fallbackModel)</code>")
        }

        guard !lines.isEmpty else { return nil }

        return "\n\n──────────\n" + lines.joined(separator: "\n")
    }

    private static func tokenLines(usage: StreamUsageSummary?) -> [String] {
        guard let usage else {
            return ["📊 Токены · —"]
        }

        let prompt = usage.promptTokens
        let completion = usage.completionTokens
        let total = usage.totalTokens

        var primary = "📊"
        var primaryParts: [String] = []
        if let prompt { primaryParts.append("вход \(formatTokenValue(prompt))") }
        if let completion { primaryParts.append("выход \(formatTokenValue(completion))") }
        if let total { primaryParts.append("всего <b>\(formatTokenValue(total))</b>") }

        if primaryParts.isEmpty {
            return ["📊 Токены · —"]
        }

        primary += " " + primaryParts.joined(separator: " · ")

        var lines = [primary]

        var detailParts: [String] = []
        if let hit = usage.cacheHitTokens, hit > 0 {
            detailParts.append("cache hit \(formatTokenValue(hit))")
        }
        if let write = usage.cacheWriteTokens, write > 0 {
            detailParts.append("cache write \(formatTokenValue(write))")
        }
        if let reasoning = usage.reasoningTokens, reasoning > 0 {
            detailParts.append("reasoning \(formatTokenValue(reasoning))")
        }
        if !detailParts.isEmpty {
            lines.append("   <i>\(detailParts.joined(separator: " · "))</i>")
        }

        return lines
    }

    static func formatTokenValue(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }

    private static func formatCost(_ cost: Double) -> String {
        if cost == 0 {
            return "0"
        }
        if cost < 0.0001 {
            return String(format: "%.6f", cost)
        }
        if cost < 0.01 {
            return String(format: "%.5f", cost)
        }
        return String(format: "%.4f", cost)
    }
}
