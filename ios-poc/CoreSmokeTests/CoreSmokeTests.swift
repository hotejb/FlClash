import Darwin
import XCTest

/// Runtime smoke tests for the Go core <-> Swift bridge (PacketTunnel/ClashCore.swift
/// over libclash.a) on the iOS Simulator. Everything short of a real tunnel:
/// Go runtime init in an iOS process, the bride.h callbacks, method
/// round-trips, config parsing and the mixed listener.
///
/// The Go core is process-global state, so the tests share one core and run
/// in name order (XCTest sorts test methods alphabetically).
final class CoreSmokeTests: XCTestCase {
    private static var homeDir: URL!
    private static var mixedPort: UInt16 = 0

    private var core: ClashCore { .shared }

    override class func setUp() {
        super.setUp()
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clash-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: homeDir)
        super.tearDown()
    }

    // MARK: - Tests

    func test01_initClash() throws {
        XCTAssertEqual(try core.invoke(method: "getIsInit") as? Bool, false)
        try core.initClash(homeDir: Self.homeDir)
        XCTAssertEqual(try core.invoke(method: "getIsInit") as? Bool, true)
    }

    func test02_setupConfigRejectsMalformedYAML() throws {
        try writeConfig("mixed-port: [this is not\n  valid: yaml")
        XCTAssertThrowsError(try core.setupConfig()) { error in
            XCTAssertTrue("\(error.localizedDescription)".hasPrefix("setupConfig: "), "\(error)")
        }
    }

    func test03_setupConfigRejectsInvalidConfig() throws {
        // Well-formed YAML, but the rule targets a proxy that does not exist.
        try writeConfig(Self.config(port: try freePort(), rules: ["MATCH,no-such-proxy"]))
        XCTAssertThrowsError(try core.setupConfig()) { error in
            XCTAssertTrue(error.localizedDescription.contains("no-such-proxy"), "\(error)")
        }
    }

    func test04_setupConfigAcceptsValidConfig() throws {
        Self.mixedPort = try freePort()
        try writeConfig(Self.config(port: Self.mixedPort, rules: ["MATCH,DIRECT"]))
        try core.setupConfig()
    }

    func test05_startListenerAcceptsConnections() throws {
        XCTAssertEqual(try core.invoke(method: "startListener") as? Bool, true)
        let fd = try connectLoopback(port: Self.mixedPort)
        close(fd)
    }

    func test06_mixedPortProxiesHTTP() throws {
        let body = "hello from loopback \(UUID().uuidString)"
        let server = try LoopbackHTTPServer(body: body)
        defer { server.stop() }

        let fd = try connectLoopback(port: Self.mixedPort)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let target = "127.0.0.1:\(server.port)"
        try sendAll(fd, "GET http://\(target)/smoke HTTP/1.1\r\nHost: \(target)\r\nConnection: close\r\n\r\n")
        let response = readAll(fd)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(response.hasSuffix(body), response)
        XCTAssertEqual(server.requests.first?.hasPrefix("GET /smoke HTTP/1.1"), true, "\(server.requests)")
    }

    func test07_getProxiesRoundTrip() throws {
        let data = try XCTUnwrap(core.invoke(method: "getProxies") as? [String: Any])
        XCTAssertNotNil(data["all"] as? [String], "\(data.keys)")
        let proxies = try XCTUnwrap(data["proxies"] as? [String: Any], "\(data.keys)")
        let direct = try XCTUnwrap(proxies["DIRECT"] as? [String: Any], "\(proxies.keys)")
        XCTAssertEqual(direct["name"] as? String, "DIRECT")
        XCTAssertEqual(direct["type"] as? String, "Direct")
        let global = try XCTUnwrap(proxies["GLOBAL"] as? [String: Any], "\(proxies.keys)")
        XCTAssertEqual(global["type"] as? String, "Selector")
    }

    func test08_getTrafficRoundTrip() throws {
        // lib/core/interface.dart: arguments is onlyStatisticsProxy (bool).
        let traffic = try XCTUnwrap(core.invoke(method: "getTraffic", arguments: false) as? [String: Any])
        XCTAssertNotNil(traffic["up"], "\(traffic)")
        XCTAssertNotNil(traffic["down"], "\(traffic)")
    }

    func test09_getConnectionsRoundTrip() throws {
        let snapshot = try XCTUnwrap(core.invoke(method: "getConnections") as? [String: Any])
        XCTAssertNotNil(snapshot["downloadTotal"], "\(snapshot)")
        XCTAssertNotNil(snapshot["uploadTotal"], "\(snapshot)")
    }

    func test10_getMemoryStats() throws {
        // rss goes through purego's dlopen(libSystem) + proc_pidinfo on darwin/ios.
        let stats = try XCTUnwrap(core.invoke(method: "getMemoryStats") as? [String: Any])
        let rss = try XCTUnwrap((stats["rss"] as? NSNumber)?.uint64Value, "\(stats)")
        XCTAssertGreaterThan(rss, 0)
        XCTAssertNotNil(stats["heapInuse"], "\(stats)")
    }

    func test11_forceGC() throws {
        XCTAssertEqual(try core.invoke(method: "forceGc") as? Bool, true)
        core.gc() // exported forceGC(), no callback
    }

    func test12_invalidCallReleasesCallback() throws {
        let baseline = ClashCore.liveCallbacks
        let reply = try core.invokeRaw("{not json")
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], reply)
        let error = try XCTUnwrap(response["error"] as? [String: Any], reply)
        XCTAssertEqual(error["code"] as? String, "invalid_method_call", reply)
        waitForLiveCallbacks(baseline)
    }

    func test13_repeatedInvokesReleaseCallbacks() throws {
        let baseline = ClashCore.liveCallbacks
        for i in 0..<200 {
            switch i % 4 {
            case 0: XCTAssertEqual(try core.invoke(method: "getIsInit") as? Bool, true)
            case 1: XCTAssertNotNil((try core.invoke(method: "getProxies") as? [String: Any])?["proxies"])
            case 2: XCTAssertNotNil(try core.invoke(method: "getTraffic", arguments: true) as? [String: Any])
            default: XCTAssertEqual(try core.invoke(method: "forceGc") as? Bool, true)
            }
        }
        // Concurrent callers, as the app and provider messages would do.
        let core = self.core
        let errorsLock = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            do {
                _ = try core.invoke(method: "getConnections")
            } catch {
                errorsLock.lock()
                errors.append(error)
                errorsLock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        waitForLiveCallbacks(baseline)
        // The listener is still serving after all of that.
        close(try connectLoopback(port: Self.mixedPort))
    }

    func test14_stopListenerClosesPort() throws {
        XCTAssertEqual(try core.invoke(method: "stopListener") as? Bool, true)
        XCTAssertThrowsError(try connectLoopback(port: Self.mixedPort))
    }

    func test15_restartListener() throws {
        XCTAssertEqual(try core.invoke(method: "startListener") as? Bool, true)
        close(try connectLoopback(port: Self.mixedPort))
    }

    func test16_shutdown() throws {
        XCTAssertEqual(try core.invoke(method: "shutdown") as? Bool, true)
        XCTAssertEqual(try core.invoke(method: "getIsInit") as? Bool, false)
        XCTAssertThrowsError(try connectLoopback(port: Self.mixedPort))
    }

    func test17_exportedTrafficStringsAreCallerOwned() throws {
        // getTraffic/getTotalTraffic (core/lib.go) return a malloc'ed JSON
        // string the caller frees. Run under Address Sanitizer in CI, so a
        // string freed by Go before returning would be reported here.
        let exports: [(String, (GoUint8) -> UnsafeMutablePointer<CChar>?)] = [
            ("getTraffic", { getTraffic($0) }),
            ("getTotalTraffic", { getTotalTraffic($0) }),
        ]
        for i in 0..<500 {
            for (name, export) in exports {
                let pointer = try XCTUnwrap(export(GoUint8(i % 2)), name)
                let json = String(cString: pointer)
                free(pointer)
                let traffic = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], "\(name): \(json)")
                XCTAssertNotNil(traffic["up"] as? NSNumber, "\(name): \(json)")
                XCTAssertNotNil(traffic["down"] as? NSNumber, "\(name): \(json)")
            }
        }
        // test06 downloaded through DIRECT, which counts when not limited
        // to proxy traffic.
        let pointer = try XCTUnwrap(getTotalTraffic(0))
        defer { free(pointer) }
        let json = String(cString: pointer)
        let total = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json)
        XCTAssertGreaterThan((total["down"] as? NSNumber)?.int64Value ?? 0, 0, json)
    }

    // MARK: - Helpers

    private static func config(port: UInt16, rules: [String]) -> String {
        """
        mixed-port: \(port)
        allow-lan: false
        bind-address: 127.0.0.1
        mode: rule
        log-level: info
        ipv6: false
        find-process-mode: off
        unified-delay: false
        geodata-mode: false
        geo-auto-update: false
        profile:
          store-selected: false
          store-fake-ip: false
        dns:
          enable: true
          ipv6: false
          enhanced-mode: normal
          default-nameserver:
            - 223.5.5.5
          nameserver:
            - 223.5.5.5
            - 119.29.29.29
        proxies: []
        proxy-groups: []
        rules:
        \(rules.map { "  - \($0)" }.joined(separator: "\n"))

        """
    }

    private func writeConfig(_ yaml: String) throws {
        try yaml.write(to: Self.homeDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    /// Callbacks are released by Go right after the result callback returns,
    /// so give the release a moment to land.
    private func waitForLiveCallbacks(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while ClashCore.liveCallbacks != expected && Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(ClashCore.liveCallbacks, expected, "callbacks not released by Go", file: file, line: line)
    }
}

// MARK: - Sockets

struct SocketError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
}

private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

/// Binds a loopback TCP socket on port 0 and returns the listening fd.
private func bindLoopback() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError("socket") }
    var addr = loopbackAddress(port: 0)
    guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else {
        close(fd)
        throw SocketError("bind")
    }
    return fd
}

private func boundPort(_ fd: Int32) throws -> UInt16 {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard rc == 0 else { throw SocketError("getsockname") }
    return UInt16(bigEndian: addr.sin_port)
}

/// A loopback TCP port that was free a moment ago.
func freePort() throws -> UInt16 {
    let fd = try bindLoopback()
    defer { close(fd) }
    return try boundPort(fd)
}

func connectLoopback(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError("socket") }
    var addr = loopbackAddress(port: port)
    guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else {
        let error = SocketError("connect 127.0.0.1:\(port)")
        close(fd)
        throw error
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func sendAll(_ fd: Int32, _ string: String) throws {
    var bytes = Array(string.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeMutableBytes { send(fd, $0.baseAddress! + offset, $0.count - offset, 0) }
        guard n > 0 else { throw SocketError("send") }
        offset += n
    }
}

/// Reads until EOF (or the socket's receive timeout).
func readAll(_ fd: Int32) -> String {
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n <= 0 { break }
        data.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: data, as: UTF8.self)
}

/// Minimal HTTP/1.1 server on 127.0.0.1 that answers every request with `body`.
final class LoopbackHTTPServer {
    let port: UInt16
    private let fd: Int32
    private let store = RequestStore()

    private final class RequestStore {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    var requests: [String] { store.all }

    init(body: String) throws {
        fd = try bindLoopback()
        port = try boundPort(fd)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw SocketError("listen")
        }
        let listenFD = fd
        let store = self.store
        let thread = Thread {
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var request = [UInt8]()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !request.ends(with: Array("\r\n\r\n".utf8)) {
                    let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                    if n <= 0 { break }
                    request.append(contentsOf: buffer[0..<n])
                }
                store.add(String(decoding: request, as: UTF8.self))
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                try? sendAll(client, response)
                close(client)
            }
        }
        thread.start()
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

private extension Array where Element: Equatable {
    func ends(with suffix: [Element]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
