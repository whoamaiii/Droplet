import Foundation

/// Conservative classification of the engine's diagnostic text. Unknown errors
/// stop; an automatic retry is never a reason to request browser access.
enum DownloadFailure: Equatable {
    case network, source, authentication, permission, disk, missingEngine, unknown

    static func classify(_ message: String) -> Self {
        let text = message.lowercased()
        func has(_ values: [String]) -> Bool { values.contains { text.contains($0) } }
        if has(["no space left", "disk quota exceeded", "read-only file system"]) { return .disk }
        if has(["permission denied", "operation not permitted", "access is denied"]) { return .permission }
        if has(["sign in", "sign-in", "login required", "log in", "authentication", "private video", "members-only", "cookies"]) { return .authentication }
        if has(["unsupported url", "not available", "removed", "not found", "http error 404", "http error 410", "requested format", "http error 403", "forbidden", "drm"]) { return .source }
        if has(["timed out", "timeout", "connection reset", "connection refused", "temporary failure", "temporarily unavailable", "network is unreachable", "http error 408", "http error 429", "http error 500", "http error 502", "http error 503", "http error 504"]) { return .network }
        if text.contains("unavailable") { return .source }
        return .unknown
    }

    static func launch(_ error: Error) -> Self {
        let error = error as NSError
        if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return .missingEngine }
        if (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
            || (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError) { return .permission }
        return .unknown
    }

    var retryable: Bool { self == .network }
}
