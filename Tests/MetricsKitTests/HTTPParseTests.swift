import Testing
import Foundation
import Darwin
@testable import MetricsKit

struct HTTPParseTests {
    @Test func parsesStatusAndBody() throws {
        let raw = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}".utf8)
        let r = try UnixSocketHTTPClient.parse(raw)
        #expect(r.status == 200)
        #expect(String(decoding: r.body, as: UTF8.self) == "{\"a\":1}")
    }
    @Test func notFound() throws {
        #expect(try UnixSocketHTTPClient.parse(Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)).status == 404)
    }
    @Test func garbageThrows() {
        #expect(throws: UnixSocketError.self) { try UnixSocketHTTPClient.parse(Data("hello".utf8)) }
        #expect(throws: UnixSocketError.self) { try UnixSocketHTTPClient.parse(Data("HTTP/1.0 abc\r\n\r\n".utf8)) }
        #expect(throws: UnixSocketError.self) { try UnixSocketHTTPClient.parse(Data()) }
    }
    @Test func parseBodyStartsAtIndexZero() throws {
        // The client strips the header in place; the body must still be a normal 0-based Data.
        let r = try UnixSocketHTTPClient.parse(Data("HTTP/1.0 200 OK\r\n\r\nxyz".utf8))
        #expect(r.body.startIndex == 0 && r.body == Data("xyz".utf8))
    }
    /// The path goes verbatim into the request line; CR/LF or a space would let a crafted value
    /// smuggle a second header or request. Rejected before any socket is opened.
    @Test(arguments: ["/a\r\nX-Evil: 1", "/a\nb", "/a b", "/a\tb", "relative", ""])
    func invalidRequestPathIsRejected(_ path: String) {
        let client = UnixSocketHTTPClient(socketPath: "/tmp/does-not-exist-\(UUID().uuidString).sock", timeout: 2)
        #expect(throws: UnixSocketError.invalidPath) { try client.get(path, maxBytes: 1024) }
    }
    @Test func missingSocketFailsFast() {
        let client = UnixSocketHTTPClient(socketPath: "/tmp/does-not-exist-\(UUID().uuidString).sock", timeout: 2)
        let start = Date()
        #expect(throws: UnixSocketError.self) { try client.get("/_ping") }
        #expect(Date().timeIntervalSince(start) < 1)
    }
    @Test func tooLongSocketPathIsRejected() {
        let client = UnixSocketHTTPClient(socketPath: "/tmp/" + String(repeating: "x", count: 200), timeout: 2)
        #expect(throws: UnixSocketError.socketPathTooLong) { try client.get("/_ping") }
    }

    // MARK: - Real sockets (local only, no network)

    /// Short path: `sun_path` is limited to 104 bytes and the test-runner temp dir can be long.
    private func socketPath() -> String { "/tmp/sm-\(UUID().uuidString.prefix(8)).sock" }

    /// Binds (and optionally listens on) a unix socket; returns the fd. Caller closes and unlinks.
    private func bindSocket(at path: String, listen shouldListen: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(rc == 0)
        if shouldListen { try #require(listen(fd, 4) == 0) }
        return fd
    }

    @Test func staleSocketFileFailsFast() throws {
        // Docker Desktop quit uncleanly: the socket file exists but nothing is listening.
        let path = socketPath()
        let fd = try bindSocket(at: path, listen: false)
        close(fd)
        defer { unlink(path) }
        #expect(FileManager.default.fileExists(atPath: path))
        let start = Date()
        #expect(throws: UnixSocketError.self) { try UnixSocketHTTPClient(socketPath: path, timeout: 2).get("/_ping") }
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func hungDaemonTimesOut() throws {
        // Daemon accepts connections (kernel backlog) but never answers.
        let path = socketPath()
        let fd = try bindSocket(at: path, listen: true)
        defer { close(fd); unlink(path) }
        let start = Date()
        #expect(throws: UnixSocketError.timeout) { try UnixSocketHTTPClient(socketPath: path, timeout: 0.3).get("/_ping") }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.25 && elapsed < 1.5)
    }

    /// Serves one fixed response to the first connection, then closes.
    private func serveOnce(at path: String, response: [UInt8]) throws -> (fd: Int32, thread: Thread) {
        let fd = try bindSocket(at: path, listen: true)
        let t = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &buf, buf.count)
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
        t.start()
        return (fd, t)
    }

    @Test func responseOverPerCallCapIsRejected() throws {
        let path = socketPath()
        let body = String(repeating: "x", count: 4_000)
        let server = try serveOnce(at: path, response: Array("HTTP/1.0 200 OK\r\n\r\n\(body)".utf8))
        defer { close(server.fd); unlink(path) }
        #expect(throws: UnixSocketError.responseTooLarge) {
            try UnixSocketHTTPClient(socketPath: path, timeout: 2).get("/_ping", maxBytes: 1_024)
        }
    }
    @Test func responseUnderPerCallCapIsReturnedWithoutHeader() throws {
        let path = socketPath()
        let server = try serveOnce(at: path, response: Array("HTTP/1.0 200 OK\r\nA: b\r\n\r\n{\"ok\":1}".utf8))
        defer { close(server.fd); unlink(path) }
        let r = try UnixSocketHTTPClient(socketPath: path, timeout: 2).get("/_ping", maxBytes: 1_024)
        #expect(r.status == 200)
        #expect(r.body == Data(#"{"ok":1}"#.utf8))
    }
}
