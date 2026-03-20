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
        
        var lines: [String] = ["", "━━━━━━━━━━━━━"]
        let usage = meta?.usage
        
        if showTokens {
            let tokenLines = [
                ("• Prompt", usage?.promptTokens),
                ("  • cache hit", usage?.cacheHitTokens),
                ("  • cache write", usage?.cacheWriteTokens),
                ("  • cache miss", usage?.cacheMissTokens),
                ("• Completion", usage?.completionTokens),
                ("  • reasoning", usage?.reasoningTokens),
                ("• Total", usage?.totalTokens)
            ]
                .compactMap { label, value in
                    value.map { "\(label): \(formatTokenValue($0))" }
                }
            
            lines.append(contentsOf: tokenLines.isEmpty ? ["• Токены: н/д"] : tokenLines)
        }
        
        if showCost {
            let costLine = usage?.cost.map { cost in
                "• Стоимость: $\(String(format: "%.6f", cost))"
            } ?? "• Стоимость: н/д"
            lines.append(costLine)
        }
        
        if showModel {
            lines.append("Модель: \(meta?.model ?? fallbackModel)")
        }
        
        return lines.count > 2 ? lines.joined(separator: "\n") : nil
    }
    
    static func formatTokenValue(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }
}
