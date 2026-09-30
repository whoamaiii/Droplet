import Foundation

struct HTTPResponse {
    let data: Data
    let statusCode: Int
}

protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

enum HTTPTransportError: Error {
    case insecureURL
    case nonHTTPResponse
}

/// Transport only: HTTP error statuses are data, not proof a license is invalid.
final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.scheme?.lowercased() == "https" else {
            throw HTTPTransportError.insecureURL
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HTTPTransportError.nonHTTPResponse
        }
        return HTTPResponse(data: data, statusCode: response.statusCode)
    }
}

/// A TLS endpoint cannot redirect a license-bearing request to a different
/// origin or plaintext connection. Refused redirects remain HTTP 3xx responses.
final class HTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static func permits(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
              original.scheme?.lowercased() == "https",
              target.scheme?.lowercased() == "https",
              let sourceHost = original.host,
              sourceHost.lowercased() == target.host?.lowercased(),
              (original.port ?? 443) == (target.port ?? 443),
              target.user == nil, target.password == nil else { return false }
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.permits(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}
