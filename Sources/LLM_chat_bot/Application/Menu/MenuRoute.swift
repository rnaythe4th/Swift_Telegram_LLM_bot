import Foundation

// A parsed `menu:` callback. Everything that travels in a button's
// callback_data arrives here once, is checked once, and is read by name after
// that — instead of every handler re-deriving `parts[2]` behind its own
// `guard parts.count >= 3`.

/// Top-level commands the menu dispatcher knows. A button whose command is not
/// in this list cannot reach a handler: parsing fails and the tap answers with
/// a toast rather than silently doing nothing.
enum MenuCommand: String, CaseIterable {
    // Navigation
    case open, close, nav, noop
    // Per-chat settings
    case role, model, temp, stats, history, provider, reasoning, reset, help
    /// Reference modes: `mode` is the user-facing picker, `smode` the
    /// super-admin editor behind it.
    case mode, smode
    // Presets
    case pm
    // Purchase
    case buy
    // Admin panel
    case tenant, wl, def
    // Super-admin
    case sa, stenant, sim, sinspect, ads, markup, dailylimit
    case stars, freemodels, sbal, crypto, card
    /// Hosted checkout settings (§7 «Внешняя касса»).
    case extpay
    // Growth and retention
    case funnel, promo, rem, examples, onb, sref, strf
    // Help
    case sahelp
}

/// `<command>[:<arg>…]`, already split and validated.
///
/// Indices match the raw payload: `arg(1)` is the token right after the
/// command, exactly what `parts[1]` used to be — so a handler reads the same
/// position it always did, minus the bounds check.
struct MenuRoute {
    let command: MenuCommand
    private let parts: [String]

    /// Fails for anything the dispatcher has no case for. An empty payload is
    /// the bare `menu:` button, which means "open the main page".
    init?(action rawAction: String) {
        let action = rawAction.isEmpty ? MenuCommand.open.rawValue : rawAction
        let parts = action.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, let command = MenuCommand(rawValue: head) else { return nil }
        self.command = command
        self.parts = parts
    }

    /// Argument at `index`, or nil when it is missing or empty. An empty token
    /// is treated as missing on purpose: `nav:` and a chat id of `""` are both
    /// a button that lost its payload, not a request to act on nothing.
    func arg(_ index: Int) -> String? {
        guard index >= 0, index < parts.count else { return nil }
        let value = parts[index]
        return value.isEmpty ? nil : value
    }

    func int(_ index: Int) -> Int? {
        arg(index).flatMap(Int.init)
    }

    func page(_ index: Int) -> MenuPage? {
        arg(index).flatMap { MenuPage(rawValue: $0.lowercased()) }
    }

    /// The token every handler switches on first. Missing reads as `""`, which
    /// lands in `default` — the same place a bounds guard used to send it.
    var sub: String { arg(1) ?? "" }

    /// Payload as it arrived, for the rare handler that needs the tail whole.
    var rawArguments: [String] { Array(parts.dropFirst()) }

    // MARK: - Rendering (the other half of the round trip)

    /// `<command>[:<arg>…]` — the payload a button carries. The only place the
    /// wire format is written, so a caller cannot invent a separator or leave
    /// out the command.
    static func link(_ command: MenuCommand, _ arguments: String...) -> String {
        ([command.rawValue] + arguments).joined(separator: ":")
    }

    /// `nav:<page>` — the link a navigation button carries.
    static func navigation(to page: MenuPage) -> String {
        link(.nav, page.rawValue)
    }

    /// `nav:pay:<source>` — the purchase page always records which surface sent
    /// the person there (CLAUDE.md §17), so the source is part of the link.
    static func purchase(from source: PurchaseSource) -> String {
        link(.nav, MenuPage.pay.rawValue, source.rawValue)
    }
}
