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
    /// Daily spending ceilings (§4.1).
    case spend
    // Help
    case sahelp

    /// The right this action needs, regardless of the page it was drawn on.
    ///
    /// A page gate is not enough. The keyboard is a message: it stays in the
    /// chat after the subscription that opened it lapses, after the super-admin
    /// who drew it is removed, and in a group it is shared with every member —
    /// so the tap has to be judged when it arrives, not when the button was
    /// painted. `history` had this check and said so in a comment; `temp`,
    /// `reasoning` and `provider` are the same class of setting and had none.
    ///
    /// Exhaustive on purpose: a new command names its audience or the build
    /// stops. The individual handlers keep their own `require…` guards — this
    /// is the floor, not a replacement for the finer rules inside (who owns
    /// this preset, whose chat this is).
    var access: MenuAccess {
        switch self {
        case .open, .close, .nav, .noop:
            return .everyone

        // Per-chat settings anyone in the chat may touch, plus the pickers whose
        // finer rules (whose preset, whose chat) live in the handler.
        case .role, .model, .stats, .reset, .help, .mode, .pm, .buy:
            return .everyone

        // Cost multipliers. `history` also carries an operator check inside for
        // the length buttons, while its "clear" and "dump" stay open to the chat.
        case .history:
            return .everyone
        case .temp, .reasoning:
            return .paidAccess
        case .provider:
            return .chatOperator

        case .tenant, .wl, .def:
            return .chatOperator

        case .smode, .sa, .stenant, .sim, .sinspect, .ads, .markup, .dailylimit,
             .stars, .freemodels, .sbal, .crypto, .card, .extpay,
             .funnel, .promo, .rem, .examples, .onb, .sref, .strf, .spend, .sahelp:
            return .superAdmin
        }
    }
}

/// A value a button may carry in its `callback_data`.
///
/// The payload is a string, and that is exactly the problem: every id in this
/// codebase is a type (`UserKey`, `ChatID`, `UserID`), and interpolating one
/// into a payload yields its *debug* description — `UserKey(#42)` — which comes
/// back through `MenuRoute.userKey` addressing nothing at all. That is not a
/// broken button that looks broken: it is "🗑 Да, удалить" answering «не
/// найдено», and it had happened to three destructive actions at once.
///
/// So a button takes values, not strings it glued together, and each type says
/// once how it is written down. The round trip is symmetric by construction:
/// what `callbackToken` writes is what the reader on the other side parses.
protocol CallbackArgument {
    var callbackToken: String { get }
}

extension String: CallbackArgument {
    var callbackToken: String { self }
}

extension Int: CallbackArgument {
    var callbackToken: String { String(self) }
}

/// The storage form, which is what `MenuRoute.userKey` reads back — never the
/// description, and never a label a person reads.
extension UserKey: CallbackArgument {
    var callbackToken: String { storageValue }
}

extension ChatID: CallbackArgument {
    var callbackToken: String { String(value) }
}

extension UserID: CallbackArgument {
    var callbackToken: String { String(value) }
}

/// Enumerations travel as their raw value, without a `.rawValue` at each call
/// site to forget. Conformance is declared per type rather than granted to
/// every `RawRepresentable`: `ServiceProvider` travels as `commandValue`, not
/// as its raw value, and a blanket rule would have silently written the wrong
/// one.
extension CallbackArgument where Self: RawRepresentable, Self.RawValue == String {
    var callbackToken: String { rawValue }
}

extension MenuPage: CallbackArgument {}
extension MenuCommand: CallbackArgument {}
extension PurchaseSource: CallbackArgument {}
extension PresetCategory: CallbackArgument {}
extension CryptoChain: CallbackArgument {}
extension CryptoAsset: CallbackArgument {}
extension FiatCurrency: CallbackArgument {}
extension FunnelPeriod: CallbackArgument {}
extension SuperHelpSection: CallbackArgument {}

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

    /// A `UserKey` that this button is carrying back. The payload is our own
    /// key making a round trip through Telegram, so it is read the same total
    /// way a stored value is (`init(storageValue:)`): a truncated or edited
    /// payload addresses no record instead of becoming an arbitrary key.
    func userKey(_ index: Int) -> UserKey? {
        arg(index).map { UserKey(storageValue: $0) }
    }

    func chatID(_ index: Int) -> ChatID? { int(index).map(ChatID.init) }

    func userID(_ index: Int) -> UserID? { int(index).map(UserID.init) }

    /// The token every handler switches on first. Missing reads as `""`, which
    /// lands in `default` — the same place a bounds guard used to send it.
    var sub: String { arg(1) ?? "" }

    /// Payload as it arrived, for the rare handler that needs the tail whole.
    var rawArguments: [String] { Array(parts.dropFirst()) }

    // MARK: - Rendering (the other half of the round trip)

    /// Telegram's hard limit on `callback_data` (Bot API: "1-64 bytes"). Worth
    /// naming because of *how* it fails: a single overlong button makes the API
    /// reject the whole `sendMessage`/`editMessage`, so one bad payload takes
    /// the entire page down rather than one button.
    static let maxCallbackDataBytes = 64

    /// `<command>[:<arg>…]` — the payload a button carries. The only place the
    /// wire format is written, so a caller cannot invent a separator or leave
    /// out the command, and each argument encodes itself (`CallbackArgument`).
    static func link(_ command: MenuCommand, _ arguments: any CallbackArgument...) -> String {
        link(command, arguments)
    }

    static func link(_ command: MenuCommand, _ arguments: [any CallbackArgument]) -> String {
        ([command.rawValue] + arguments.map(\.callbackToken)).joined(separator: ":")
    }

    /// `nav:<page>` — the link a navigation button carries.
    static func navigation(to page: MenuPage) -> String {
        link(.nav, page)
    }

    /// `nav:pay:<source>` — the purchase page always records which surface sent
    /// the person there (CLAUDE.md §17), so the source is part of the link.
    static func purchase(from source: PurchaseSource) -> String {
        link(.nav, MenuPage.pay, source)
    }
}
