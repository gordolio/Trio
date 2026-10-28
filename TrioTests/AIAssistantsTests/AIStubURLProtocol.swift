import Foundation

/// Answers requests from a handler registered for the request's host, so suites that use
/// different hosts can't see each other's requests even when they run at the same time.
/// A handler that throws a `URLError` makes the request fail with it.
final class AIStubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest, Data?) throws -> (Int, Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func setHandler(for host: String, _ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(for host: String?) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return host.flatMap { handlers[$0] }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request, Self.body(of: request))
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// `URLProtocol` sees a nil `httpBody`; the body arrives as a stream.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension Data {
    /// Decodes an `application/x-www-form-urlencoded` body.
    var formFields: [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: self, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    var jsonObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any]
    }
}

extension Array where Element == URLQueryItem {
    var dict: [String: String] {
        Dictionary(map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}
