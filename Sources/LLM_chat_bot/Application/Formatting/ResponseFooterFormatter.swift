import Foundation

enum ResponseFooterFormatter {
    /// `costMultiplier` converts the provider's real cost into the customer
    /// price (markup); every user-visible dollar amount goes through it.
    /// `balanceAfter` adds the remaining pay-as-you-go balance for users who
    /// were charged per-message.
    static func formatFooter(
        meta: StreamMeta?,
        fallbackModel: String,
        showTokens: Bool,
        showCost: Bool,
        showModel: Bool,
        costMultiplier: Double = 1.0,
        balanceAfter: Money? = nil,
        sponsorLine: String? = nil
    ) -> String? {
        guard showTokens || showCost || showModel || balanceAfter != nil || sponsorLine != nil else { return nil }

        let usage = meta?.usage
        var lines: [String] = []

        if showTokens {
            lines.append(contentsOf: tokenLines(usage: usage))
        }

        if showCost {
            if let cost = usage?.cost {
                lines.append("💵 $\(formatCost(cost * costMultiplier))")
            } else {
                lines.append("💵 —")
            }
        }

        if showModel {
            lines.append("🤖 <code>\(meta?.model ?? fallbackModel)</code>")
        }

        if let balanceAfter {
            lines.append("💰 Баланс · \(balanceAfter.formatted())" + (balanceAfter.isPositive ? "" : " <i>(исчерпан)</i>"))
        }

        if let sponsorLine {
            lines.append("<i>\(sponsorLine)</i>")
        }

        guard !lines.isEmpty else { return nil }

        return "\n\n──────────\n" + lines.joined(separator: "\n")
    }

    private static func tokenLines(usage: StreamUsageSummary?) -> [String] {
        guard let usage else {
            return ["📊 Объём текста · —"]
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
            return ["📊 Объём текста · —"]
        }

        primary += " " + primaryParts.joined(separator: " · ")

        var lines = [primary]

        var detailParts: [String] = []
        if let hit = usage.cacheHitTokens, hit > 0 {
            detailParts.append("из памяти \(formatTokenValue(hit))")
        }
        if let write = usage.cacheWriteTokens, write > 0 {
            detailParts.append("в память \(formatTokenValue(write))")
        }
        if let reasoning = usage.reasoningTokens, reasoning > 0 {
            detailParts.append("обдумывание \(formatTokenValue(reasoning))")
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
