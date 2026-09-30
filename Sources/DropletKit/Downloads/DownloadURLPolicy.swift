import Foundation
import Darwin

/// All entry points use the same validation before constructing Process arguments.
enum DownloadURLPolicy {
    static func parse(_ input: String) -> URL? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(raw.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
            guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return nil }
        }
        guard !raw.isEmpty, raw.utf8.count <= 8192,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty,
              !host.contains("%"), !host.contains("\\"),
              let url = components.url else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        // Bracketed IPv6 is validated by URLComponents. DNS names and IPv4
        // must not contain empty labels or shell-like/non-host punctuation.
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return nil }
            var address = in6_addr()
            guard String(host.dropFirst().dropLast()).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            }) else { return nil }
        }
        return url
    }

    static func isYouTube(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}
