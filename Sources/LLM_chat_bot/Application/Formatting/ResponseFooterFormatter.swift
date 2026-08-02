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
        // An answer cut off by the token ceiling is reported whatever the chat
        // switched off: the tumblers hide *statistics*, and "this is not the
        // whole answer" is not a statistic — without it the user reads a
        // sentence that stops mid-word as the model's own idea of an ending.
        let truncated = meta?.finishReason == .length
        guard truncated || showTokens || showCost || showModel || balanceAfter != nil || sponsorLine != nil else {
            return nil
        }

        let usage = meta?.usage
        var lines: [String] = []

        if truncated {
            lines.append("✂️ <i>Ответ обрезан лимитом длины — попросите продолжить.</i>")
        }

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

    /// The single way a token count becomes text.
    ///
    /// `Int(_: Double)` traps on `NaN`, on an infinity and on anything past
    /// `Int.max`, and these numbers come from a provider's JSON and from totals
    /// accumulated out of it — a counter nobody bounds. A crash while
    /// *formatting a footer* takes the whole bot down, and it would do it again
    /// on every render of the chat that stored the value, so the conversion
    /// only ever happens where it is guarded.
    static func formatTokenValue(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let whole = value.rounded(.towardZero)
        guard whole == value, let exact = Int(exactly: whole) else {
            return value.isFinite && abs(value) < 1e15
                ? String(format: "%.3f", value)
                : String(format: "%.3e", value)
        }
        return String(exact)
    }

    private static func formatCost(_ cost: Double) -> String {
        guard cost.isFinite else { return "—" }
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
