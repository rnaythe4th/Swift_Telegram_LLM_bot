import Foundation

/// Frames a `text/event-stream` byte stream into event payloads.
///
/// Split out of `NetworkClient` because framing is the part that is worth
/// testing and the part that gets it wrong: a chunk boundary can land inside a
/// line, inside a UTF-8 sequence, or between the `\r` and the `\n`, and every
/// one of those turns into a lost token in the middle of an answer.
///
/// Only `data:` lines are kept — `event:`, `id:`, `retry:` and comment lines
/// (`: OPENROUTER PROCESSING`) carry nothing this bot acts on. Multi-line data
/// is joined with `\n`, as the specification requires.
struct ServerSentEventParser {
    /// Ceiling on the bytes held while waiting for a line terminator.
    ///
    /// A provider that opens the stream and then sends a never-ending line
    /// would otherwise grow this buffer until the process dies — the response
    /// body limit that guards `perform` does not apply to a stream nobody
    /// finishes reading. Hitting it is a failure, not a truncation: half a JSON
    /// payload silently dropped is how a wrong answer gets billed as a right one.
    let bufferLimit: Int

    private var buffer = Data()
    private var dataLines: [String] = []

    init(bufferLimit: Int) {
        self.bufferLimit = bufferLimit
    }

    struct BufferOverflow: Error {
        let limit: Int
    }

    /// What one line of the stream amounted to.
    ///
    /// `keepAlive` exists because silence is what the pipeline treats as death
    /// (`StreamWatchdog`), and a provider thinking for two minutes is not
    /// silent — it sends comments (`: OPENROUTER PROCESSING`) and fields this
    /// bot has no use for. Dropping those on the floor made a working model
    /// look like a stalled one and cut the answer off at 75 seconds, after the
    /// provider had already been paid for the thinking.
    enum Event: Equatable {
        case payload(String)
        case keepAlive
    }

    /// Feeds the next network chunk and returns everything it completed.
    mutating func consume(_ chunk: Data) throws -> [Event] {
        buffer.append(chunk)
        var payloads: [Event] = []

        while let terminator = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<terminator]
            buffer.removeSubrange(buffer.startIndex...terminator)

            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }

            // A blank line dispatches the event that has accumulated so far.
            if line.isEmpty {
                payloads.append(takePayload().map(Event.payload) ?? .keepAlive)
                continue
            }
            if let value = Self.dataValue(of: line) {
                dataLines.append(value)
            } else {
                // A comment, an `event:`, an `id:` — nothing to act on, but
                // proof the connection is alive.
                payloads.append(.keepAlive)
            }
        }

        guard buffer.count <= bufferLimit else {
            throw BufferOverflow(limit: bufferLimit)
        }
        return payloads
    }

    /// Payload left over when the connection closes without a final blank line
    /// — providers do end that way, and the last chunk is usually `[DONE]`.
    mutating func finish() -> [Event] {
        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
            let line = tail.hasSuffix("\r") ? String(tail.dropLast()) : tail
            if let value = Self.dataValue(of: line) {
                dataLines.append(value)
            }
        }
        buffer.removeAll(keepingCapacity: false)
        return takePayload().map { [.payload($0)] } ?? []
    }

    private mutating func takePayload() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }

    /// `data: {…}` and `data:{…}` are the same line — the single optional space
    /// after the colon belongs to the framing, further whitespace belongs to
    /// the value.
    private static func dataValue(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst("data:".count)
        return value.hasPrefix(" ") ? String(value.dropFirst()) : String(value)
    }
}
