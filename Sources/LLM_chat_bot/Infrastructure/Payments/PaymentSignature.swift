import Foundation
import Crypto

/// Message authentication for hosted-checkout callbacks.
///
/// MD5 is not a choice: every Russian payment aggregator (FreeKassa, ruKassa,
/// PayOK, Cryptomus…) signs its notifications with `md5(field:field:secret:…)`,
/// and the bot has to speak what they speak. It is used here purely as a shared
/// secret over a fixed field order — nothing is hashed *for* secrecy, and the
/// secret never travels — so MD5's collision weakness does not apply. The
/// comparison is still constant-time (`SecretGuard`), because the endpoint is
/// public and hands out subscriptions.
enum PaymentSignature {
    static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
