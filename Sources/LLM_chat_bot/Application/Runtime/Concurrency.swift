import Foundation

/// Minimal lock-guarded box for values shared across concurrency domains
/// where an actor would be overkill (flags, task references).
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&_value) }
    }
}

/// Process-wide lifecycle flags shared between the HTTP server, the update
/// sources and the shutdown path.
final class RuntimeFlags: Sendable {
    /// True once state restore finished; /ready reports 503 until then.
    let ready = LockedValue(false)
    /// True while the process is draining before exit; the webhook endpoint
    /// answers 503 so Telegram redelivers those updates to the next instance.
    let draining = LockedValue(false)
}
