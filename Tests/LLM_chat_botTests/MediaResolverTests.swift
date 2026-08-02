import XCTest
@testable import LLM_chat_bot

// Attachments are the one thing a stranger can make the bot pull into memory.
// An album carries up to sixteen files, each of them read whole, base64'd and
// copied again into the provider request — and media is resolved *before*
// `GenerationLimiter` has a say, so nothing downstream caps the total either.

final class MediaResolverTests: XCTestCase {

    /// Sixteen large photos — a legal album — must not be downloaded just
    /// because Telegram allows each of them on its own.
    func testAnAlbumCannotOutgrowTheTurnBudget() async {
        let perFile = 4 << 20
        let stub = StubFileTelegram(fileSize: perFile)
        let resolver = TelegramMediaResolver(telegram: stub)
        let refs = (0..<16).map { InboundMediaRef.photo(fileID: "photo-\($0)") }

        do {
            _ = try await resolver.resolveMedia(refs)
            XCTFail("16 × 4 MiB is over the budget and must be refused")
        } catch let error as TelegramMediaResolverError {
            guard case .attachmentsTooHeavy = error else {
                return XCTFail("unexpected media error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let downloaded = await stub.downloadedBytes()
        XCTAssertLessThanOrEqual(
            downloaded,
            TelegramMediaResolver.turnByteBudget,
            "the budget is claimed before the download, not counted after it"
        )
    }

    /// The budget is a ceiling on the turn, not a new per-file limit: one file
    /// inside Telegram's own 20 MiB still resolves.
    func testASingleAttachmentInsideTheLimitStillResolves() async throws {
        let stub = StubFileTelegram(fileSize: 3 << 20)
        let resolver = TelegramMediaResolver(telegram: stub)

        let resolved = try await resolver.resolveMedia([.photo(fileID: "photo-1")])

        XCTAssertEqual(resolved.count, 1)
    }

    /// Telegram may omit `file_size`, and it is documented as an estimate when
    /// present — so the bytes that actually arrive are settled against the same
    /// budget rather than trusted.
    func testAFileThatLiesAboutItsSizeIsStillBounded() async {
        let stub = StubFileTelegram(fileSize: 1_024, actualBytes: TelegramMediaResolver.turnByteBudget + 1)
        let resolver = TelegramMediaResolver(telegram: stub)

        do {
            _ = try await resolver.resolveMedia([.photo(fileID: "photo-1")])
            XCTFail("a file bigger than the whole budget must be refused once it lands")
        } catch let error as TelegramMediaResolverError {
            guard case .attachmentsTooHeavy = error else {
                return XCTFail("unexpected media error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// A Bot API that only knows how to hand out files, and counts the bytes it was
/// asked for. Every other method is unreachable from the resolver.
private final class StubFileTelegram: TelegramGatewayPort {
    private let declaredSize: Int
    private let bytes: Int
    private let downloaded = LockedValue(0)

    init(fileSize: Int, actualBytes: Int? = nil) {
        declaredSize = fileSize
        bytes = actualBytes ?? fileSize
    }

    func downloadedBytes() async -> Int { downloaded.value }

    func getFile(fileID: String) async throws -> TelegramFile {
        TelegramFile(file_id: fileID, file_unique_id: fileID, file_size: declaredSize, file_path: "photos/\(fileID).jpg")
    }

    func downloadFile(filePath: String) async throws -> Data {
        downloaded.withLock { $0 += bytes }
        return Data(count: bytes)
    }

    private struct Unsupported: Error {}
    func deleteWebhook() async throws { throw Unsupported() }
    func setWebhook(url: String, secretToken: String, allowedUpdates: [String]) async throws { throw Unsupported() }
    func decodeIncomingUpdate(_ data: Data) throws -> TelegramUpdate { throw Unsupported() }
    func getMe() async throws -> TelegramUser { throw Unsupported() }
    func getUpdates(offset: Int?) async throws -> [TelegramUpdate] { throw Unsupported() }
    func sendMessage(_ request: SendMessageRequest) async throws -> TelegramMessage { throw Unsupported() }
    func editMessage(_ request: EditMessageRequest) async throws { throw Unsupported() }
    func sendMessageDraft(_ request: SendMessageDraftRequest) async throws { throw Unsupported() }
    func deleteMessage(chatID: ChatID, messageID: Int) async throws { throw Unsupported() }
    func sendChatAction(chatID: ChatID, threadID: Int64?, action: String) async throws { throw Unsupported() }
    func answerCallback(callbackQueryID: String, text: String?) async throws { throw Unsupported() }
    func sendInvoice(_ request: SendInvoiceRequest) async throws { throw Unsupported() }
    func answerPreCheckoutQuery(queryID: String, ok: Bool, errorMessage: String?) async throws { throw Unsupported() }
}
