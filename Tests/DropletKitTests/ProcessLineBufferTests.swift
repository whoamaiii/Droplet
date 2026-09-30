import Foundation
@testable import DropletKit

struct ProcessLineBufferTests {
    func testEveryByteBoundaryPreservesUnicodeAndRecords() throws {
        let text = "TITLE: Blåbær 🍓 日本語\r\nPROGRESS: 42\nERROR: siste ø"
        let data = Data(text.utf8)
        let expected = ["TITLE: Blåbær 🍓 日本語", "PROGRESS: 42", "ERROR: siste ø"]
        // Exhaust every possible two-chunk split, including inside UTF-8.
        for split in 0...data.count {
            var buffer = ProcessLineBuffer()
            var lines = try buffer.append(data.prefix(split))
            lines += try buffer.append(data.suffix(data.count - split))
            lines += buffer.finish()
            expectEqual(lines, expected, "Split at byte \(split)")
        }
        var buffer = ProcessLineBuffer()
        var lines: [String] = []
        for byte in data { lines += try buffer.append(Data([byte])) }
        lines += buffer.finish()
        expectEqual(lines, expected, "One-byte reads")
    }

    func testCRLFAndEOFProduceNoDuplicates() throws {
        var buffer = ProcessLineBuffer()
        expectEqual(try buffer.append(Data("a\rb\n\r\nc\r".utf8)), ["a", "b", "c"])
        expectEqual(try buffer.append(Data("\ntail".utf8)), [])
        expectEqual(buffer.finish(), ["tail"])
        expectEqual(buffer.finish(), [])
        expectEqual(try buffer.append(Data("late\n".utf8)), [])
        var empty = ProcessLineBuffer()
        expectEqual(empty.finish(), [])
    }

    func testOversizedRecordFailsBoundedly() throws {
        var buffer = ProcessLineBuffer(maximumLineBytes: 4)
        expectEqual(try buffer.append(Data("1234".utf8)), [])
        do {
            _ = try buffer.append(Data("5".utf8))
            recordFailure("Oversized record accepted")
        } catch {
            expectEqual(error as? ProcessLineBuffer.FramingError, .lineTooLong)
        }
        expectEqual(buffer.finish(), [])
        expectEqual(try buffer.append(Data("late\n".utf8)), [])
        var exact = ProcessLineBuffer(maximumLineBytes: 4)
        expectEqual(try exact.append(Data("1234\n".utf8)), ["1234"])
    }
}
