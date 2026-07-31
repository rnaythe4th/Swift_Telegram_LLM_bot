import Foundation

/// FreeKassa (SCI form protocol).
///
/// The aggregator hosts the payment page, so one integration covers every rail
/// it resells — Сбербанк Онлайн, СБП, карты РФ и зарубежные, ЮMoney, крипта —
/// and new rails appear without a release on our side.
///
/// Outgoing: `https://pay.freekassa.com/?m=…&oa=…&currency=…&o=…&s=md5(m:oa:secret1:currency:o)`.
/// Incoming: a form POST with `MERCHANT_ID`, `AMOUNT`, `intid`,
/// `MERCHANT_ORDER_ID`, `SIGN = md5(MERCHANT_ID:AMOUNT:secret2:MERCHANT_ORDER_ID)`,
/// acknowledged with the literal body `YES`.
///
/// The two secret words are different on purpose and the adapter keeps them
/// that way: word 1 signs a link the payer can read character by character, so
/// only word 2 may authorise a subscription.
struct FreeKassaCheckoutAdapter: ExternalCheckoutPort {
    let vendor: ExternalPaymentVendor = .freekassa
    /// Overridable for tests; production never changes it.
    let checkoutBaseURL: String

    init(checkoutBaseURL: String = "https://pay.fk.money/") {
        self.checkoutBaseURL = checkoutBaseURL
    }

    var acknowledgement: String { "YES" }

    func checkoutURL(
        order: ExternalPaymentOrder,
        credentials: ExternalPaymentCredentials
    ) throws -> String {
        guard order.amountMinorUnits > 0 else { throw ExternalPaymentError.priceNotSet }
        // Signed and sent as the same string: a link whose `oa` renders
        // differently than the signature was computed over is rejected by the
        // gateway with an error the payer cannot act on.
        let amount = FiatCurrency.decimalString(minorUnits: order.amountMinorUnits)
        let signature = PaymentSignature.md5Hex(
            [
                credentials.merchantID,
                amount,
                credentials.secretWord,
                order.currency.rawValue,
                order.id,
            ].joined(separator: ":")
        )
        var items: [(name: String, value: String)] = [
            ("m", credentials.merchantID),
            ("oa", amount),
            ("currency", order.currency.rawValue),
            ("o", order.id),
            ("s", signature),
            ("lang", "ru"),
        ]
        // Preselects one rail on the vendor's page ("сразу СБП"), when the
        // super-admin configured its code. Absent = the payer picks there.
        if let method = order.methodCode, !method.isEmpty {
            items.append(("i", method))
        }
        let separator = checkoutBaseURL.contains("?") ? "&" : "?"
        return checkoutBaseURL + separator + URLForm.encode(items)
    }

    func verifyCallback(
        parameters: [String: String],
        credentials: ExternalPaymentCredentials
    ) throws -> ExternalCheckoutCallback {
        // Field names are matched case-insensitively: the documented casing is
        // upper, what actually arrives has varied, and a notification rejected
        // over a lowercase key looks exactly like a wrong secret.
        let fields = CaseInsensitiveFields(parameters)
        guard let merchantID = fields["MERCHANT_ID"] else {
            throw ExternalPaymentError.malformedCallback("MERCHANT_ID")
        }
        guard let amountRaw = fields["AMOUNT"] else {
            throw ExternalPaymentError.malformedCallback("AMOUNT")
        }
        guard let orderID = fields["MERCHANT_ORDER_ID"] else {
            throw ExternalPaymentError.malformedCallback("MERCHANT_ORDER_ID")
        }
        // A missing signature must fail as a bad signature, never as "no field
        // to check" — that difference is the whole endpoint.
        let presented = fields["SIGN"] ?? ""
        let expected = PaymentSignature.md5Hex(
            [merchantID, amountRaw, credentials.callbackSecret, orderID].joined(separator: ":")
        )
        guard SecretGuard.constantTimeEquals(presented.lowercased(), expected) else {
            throw ExternalPaymentError.badSignature
        }
        // The signature already proves the sender knows our secret, so this can
        // only differ if someone reconfigured the shop mid-flight — refuse
        // rather than credit a payment we cannot explain.
        guard merchantID == credentials.merchantID else {
            throw ExternalPaymentError.badSignature
        }
        guard let amountMinorUnits = FiatCurrency.minorUnits(from: amountRaw) else {
            throw ExternalPaymentError.malformedCallback("AMOUNT")
        }
        return ExternalCheckoutCallback(
            orderID: orderID,
            // `intid` is FreeKassa's own payment id and the natural dedup key;
            // without it the order id still bounds a payment to one fulfilment.
            vendorPaymentID: fields["intid"] ?? orderID,
            amountMinorUnits: amountMinorUnits,
            methodCode: fields["CUR_ID"]
        )
    }
}

/// Case-insensitive read-only view over callback fields.
private struct CaseInsensitiveFields {
    private let storage: [String: String]

    init(_ parameters: [String: String]) {
        var lowered: [String: String] = [:]
        for (key, value) in parameters { lowered[key.lowercased()] = value }
        storage = lowered
    }

    subscript(name: String) -> String? {
        guard let value = storage[name.lowercased()], !value.isEmpty else { return nil }
        return value
    }
}
