import Foundation

/// Whether the bot can promise that what it writes will still be there
/// tomorrow — and therefore whether it is allowed to take money (§4.3).
///
/// The failure this exists for is the most ordinary one there is: the database
/// is unreachable at boot. Before, the bot went on to announce readiness, take
/// traffic, answer `/buy`, accept `successful_payment` and write it into a
/// memory that dies with the process. The customer paid; the subscription
/// lasted until the next redeploy. Refusing the sale is the only honest answer,
/// and `pre_checkout_query` is built for it: answer `ok: false` with a reason
/// and Telegram shows it to the buyer without charging them.
enum StateDurability: Sendable, Equatable {
    /// Database reachable, writer lock ours, writes are going through.
    case durable
    /// Another instance holds the writer lock (§3.1). We answer questions but
    /// change nothing — and sell nothing, because the other instance owns the
    /// state a purchase would land in.
    case readOnly(reason: String)
    /// No database. Everything works and nothing survives a restart.
    case volatile(reason: String)

    var acceptsPayments: Bool {
        if case .durable = self { return true }
        return false
    }

    var isDegraded: Bool { !acceptsPayments }

    /// Whether this instance should take updates at all.
    ///
    /// `readOnly` means another process owns the state: answering from a copy
    /// we cannot write would lose the conversation and every counter in it, so
    /// the webhook declines and Telegram redelivers to whoever is the writer.
    /// `volatile` still answers — a bot with no database is a supported mode
    /// (local development, a first run); it just sells nothing.
    var acceptsUpdates: Bool {
        if case .readOnly = self { return false }
        return true
    }

    /// What the buyer is told at checkout. Deliberately not "error": nothing is
    /// broken from their side, and they have lost nothing.
    var purchaseRefusalMessage: String {
        "Оплата временно недоступна — идёт обслуживание. Попробуйте через несколько минут, деньги не спишутся."
    }

    /// One line for `/metrics` and the super-admin panel.
    var statusLine: String {
        switch self {
        case .durable: return "durable"
        case .readOnly(let reason): return "read-only (\(reason))"
        case .volatile(let reason): return "volatile (\(reason))"
        }
    }
}
