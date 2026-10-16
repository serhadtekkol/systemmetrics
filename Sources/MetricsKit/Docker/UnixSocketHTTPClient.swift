import Darwin
import Foundation

/// Status code and raw body of one HTTP response. Headers are not kept; nothing here needs them.
public struct HTTPResponse: Equatable, Sendable {
    public var status: Int, body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

/// Transport failures. The `Int32` payloads are `errno` values.
///
/// - `socketOptionFailed`: `setsockopt` refused a timeout or `SO_NOSIGPIPE`; the request is
///   not sent, because without them a hung daemon could block forever or SIGPIPE the app.
/// - `invalidPath`: the request path is not an absolute path of printable non-space ASCII.
/// - `responseTooLarge`: the response exceeded the caller's `maxBytes`.
public enum UnixSocketError: Error, Equatable {
    case socketPathTooLong, socketFailed(Int32), socketOptionFailed(Int32), connectFailed(Int32), writeFailed(Int32)
    case readFailed(Int32), timeout, responseTooLarge, malformedResponse, invalidPath
}

/// Issues a blocking `GET` and returns the response. Implementations may block for up to
/// their timeout, so callers must not invoke this on the main thread.
public protocol HTTPTransport: AnyObject {
    /// - Parameters:
    ///   - path: Absolute request target, e.g. `/containers/json`.
    ///   - maxBytes: Upper bound on the whole response (headers + body); larger responses
    ///     throw `UnixSocketError.responseTooLarge`. Pick it per endpoint.
    func get(_ path: String, maxBytes: Int) throws -> HTTPResponse
}

public extension HTTPTransport {
    /// `get(_:maxBytes:)` with `UnixSocketHTTPClient.defaultMaxResponseBytes`; for tools and
    /// tests. The Docker sampler always passes a per-endpoint limit.
    func get(_ path: String) throws -> HTTPResponse {
        try get(path, maxBytes: UnixSocketHTTPClient.defaultMaxResponseBytes)
    }
}

/// Minimal HTTP/1.0 GET over a unix domain socket, for the Docker Engine API.
///
/// HTTP/1.0 makes the server close the connection after the body and rules out chunked
/// encoding, so "read to EOF, split at the first blank line" is the whole parser. One
/// connection per request: Docker's socket is local and connect costs microseconds.
///
/// Timeouts: `timeout` bounds connect, every write and every read (`SO_SNDTIMEO`/`SO_RCVTIMEO`),
/// and the read loop also stops once `timeout` has elapsed in total, so a daemon trickling
/// bytes cannot hold a request open indefinitely. Worst case is about twice `timeout`.
public final class UnixSocketHTTPClient: HTTPTransport {
    public let socketPath: String
    public let timeout: TimeInterval
    /// Large enough for `/system/df` with hundreds of images; protects memory against a runaway reply.
    public static let defaultMaxResponseBytes = 16 * 1024 * 1024

    /// - Parameter timeout: Seconds; values below 1 ms are raised to 1 ms because a zero
    ///   `timeval` would mean "block forever".
    public init(socketPath: String, timeout: TimeInterval = 2) {
        self.socketPath = socketPath
        self.timeout = max(timeout, 0.001)
    }

    /// `true` for an absolute path of printable ASCII without spaces. The path is written
    /// verbatim into the request line, so CR, LF or a space would let a crafted value (e.g. a
    /// container id from a fake daemon) inject headers or a second request.
    static func isValidRequestPath(_ path: String) -> Bool {
        path.utf8.first == UInt8(ascii: "/") && path.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    public func get(_ path: String, maxBytes: Int) throws -> HTTPResponse {
        guard Self.isValidRequestPath(path) else { throw UnixSocketError.invalidPath }
        let deadline = Date().addingTimeInterval(timeout)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketFailed(errno) }
        defer { close(fd) }

        func setOption<T: BitwiseCopyable>(_ name: Int32, _ value: T) throws {
            var value = value
            guard setsockopt(fd, SOL_SOCKET, name, &value, socklen_t(MemoryLayout<T>.size)) == 0 else {
                throw UnixSocketError.socketOptionFailed(errno)
            }
        }
        // Without SO_NOSIGPIPE a daemon closing mid-write would kill the whole app with SIGPIPE;
        // without the timeouts a hung daemon would block this thread forever. Either failing
        // is a reason not to send the request at all.
        try setOption(SO_NOSIGPIPE, Int32(1))
        let tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        try setOption(SO_RCVTIMEO, tv)
        try setOption(SO_SNDTIMEO, tv)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw UnixSocketError.socketPathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // A stale socket file (daemon gone) fails here immediately with ECONNREFUSED.
        guard connected == 0 else { throw UnixSocketError.connectFailed(errno) }

        let request = Array("GET \(path) HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            let n = request[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw (errno == EAGAIN || errno == EWOULDBLOCK) ? UnixSocketError.timeout : UnixSocketError.writeFailed(errno)
            }
            sent += n
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                response.append(buffer, count: n)
                if response.count > maxBytes { throw UnixSocketError.responseTooLarge }
                if Date() > deadline { throw UnixSocketError.timeout }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw (errno == EAGAIN || errno == EWOULDBLOCK) ? UnixSocketError.timeout : UnixSocketError.readFailed(errno)
            }
        }
        // Strip the header in place: `response` is uniquely owned here, so this shifts bytes
        // inside the existing buffer instead of allocating a second up-to-`maxBytes` copy.
        let head = try Self.parseHead(response)
        response.removeSubrange(..<head.bodyStart)
        return HTTPResponse(status: head.status, body: response)
    }

    /// Splits a complete HTTP/1.x response into status and body (the body is a fresh 0-based
    /// `Data`). `get` uses `parseHead` directly to avoid copying the body.
    /// - Throws: `UnixSocketError.malformedResponse` if there is no header terminator or the
    ///   status line is not `HTTP/x.y <code> ...`.
    public static func parse(_ data: Data) throws -> HTTPResponse {
        let head = try parseHead(data)
        return HTTPResponse(status: head.status, body: Data(data[head.bodyStart...]))
    }

    /// Status code and the index where the body starts.
    static func parseHead(_ data: Data) throws -> (status: Int, bodyStart: Data.Index) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { throw UnixSocketError.malformedResponse }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw UnixSocketError.malformedResponse
        }
        return (status, headerEnd.upperBound)
    }
}
