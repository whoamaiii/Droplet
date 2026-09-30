import Foundation

/// Frames raw subprocess bytes before decoding UTF-8. A read boundary is not
/// a character or line boundary. One instance belongs to one process attempt.
struct ProcessLineBuffer {
    enum FramingError: Error, Equatable { case lineTooLong }

    private var pending = Data()
    private var ended = false
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 1_048_576) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ bytes: Data) throws -> [String] {
        guard !ended else { return [] }
        var lines: [String] = []
        for byte in bytes {
            if byte == 10 || byte == 13 {
                // Empty records and the LF half of CRLF carry no events.
                if !pending.isEmpty {
                    lines.append(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                }
            } else {
                guard pending.count < maximumLineBytes else {
                    pending.removeAll(keepingCapacity: false)
                    ended = true
                    throw FramingError.lineTooLong
                }
                pending.append(byte)
            }
        }
        return lines
    }

    /// Deliver an unterminated final line exactly once. Call at pipe EOF,
    /// before interpreting process completion; process exit alone is not EOF.
    mutating func finish() -> [String] {
        guard !ended else { return [] }
        ended = true
        defer { pending.removeAll(keepingCapacity: false) }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}
