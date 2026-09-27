import Foundation

struct ClashCoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin Swift wrapper over the Go exports in core/lib.go, mirroring what
/// android/core/src/main/cpp/core.cpp does over JNI:
///
/// - Every Go call that takes a callback gets an opaque retained pointer.
///   Go calls `result_func(callback, json)` with an ActionResult JSON and then
///   `release_object_func(callback)` (except for event-listener messages).
/// - Strings passed *into* Go are malloc'ed (strdup) and freed by Go through
///   `free_string_func`.
/// - Strings returned *by* Go exports (getTraffic, getTotalTraffic) are
///   malloc'ed and owned by the caller, who frees them with free(3).
/// - protect/resolve_process are never called on iOS (see core/bride_ios.go).
final class ClashCore {
    static let shared = ClashCore()

    private final class Callback {
        let handler: (String) -> Void
        init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    }

    private static let liveLock = NSLock()
    private static var live = 0

    /// Callbacks handed to Go that Go has not released yet (includes the
    /// event listener while one is installed). Used by the smoke tests to
    /// check the retain/release contract.
    static var liveCallbacks: Int {
        liveLock.lock()
        defer { liveLock.unlock() }
        return live
    }

    private static func adjustLive(_ delta: Int) {
        liveLock.lock()
        live += delta
        liveLock.unlock()
    }

    private init() {
        result_func = { context, data in
            guard let context, let data else { return }
            Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue().handler(String(cString: data))
        }
        release_object_func = { context in
            guard let context else { return }
            Unmanaged<Callback>.fromOpaque(context).release()
            ClashCore.adjustLive(-1)
        }
        free_string_func = { pointer in
            free(pointer)
        }
        protect_func = { _, _ in }
        resolve_process_func = { _, _, _, _, _ in nil }
    }

    private static func retained(_ handler: @escaping (String) -> Void) -> UnsafeMutableRawPointer {
        adjustLive(1)
        return Unmanaged.passRetained(Callback(handler)).toOpaque()
    }

    /// Sends one Action (core/action.go) and blocks until its ActionResult arrives.
    /// Mirrors lib/core/interface.dart: `data` is whatever that method expects;
    /// for initClash / setupConfig it is itself a JSON-encoded string.
    @discardableResult
    func invoke(method: String, data: Any? = nil, timeout: TimeInterval = 60) throws -> Any? {
        let action: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "data": data ?? NSNull(),
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: action), as: UTF8.self)
        let output = try invokeRaw(json, label: method, timeout: timeout)

        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8), options: [.fragmentsAllowed]),
              let result = object as? [String: Any]
        else {
            // invokeAction replies with a bare error string if the action JSON is invalid.
            throw ClashCoreError(message: "\(method): \(output)")
        }
        if let code = result["code"] as? Int, code != 0 {
            throw ClashCoreError(message: "\(method): \(result["data"] ?? "error")")
        }
        return result["data"] is NSNull ? nil : result["data"]
    }

    /// Passes `json` to invokeAction as is and blocks until Go replies,
    /// returning the raw reply (an ActionResult JSON, or a bare error string
    /// if `json` is not a valid Action).
    func invokeRaw(_ json: String, label: String = "invokeAction", timeout: TimeInterval = 60) throws -> String {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var raw: String?
        let callback = Self.retained { value in
            lock.lock()
            raw = value
            lock.unlock()
            done.signal()
        }
        invokeAction(callback, strdup(json))

        guard done.wait(timeout: .now() + timeout) == .success else {
            throw ClashCoreError(message: "\(label): timed out after \(Int(timeout))s")
        }
        lock.lock()
        defer { lock.unlock() }
        return raw ?? ""
    }

    /// Same sequence the Flutter app drives (lib/core/controller.dart +
    /// lib/state.dart): initClash(home-dir, version) -> setupConfig(params),
    /// which parses <home-dir>/config.yaml -> startListener.
    func start(homeDir: URL) throws {
        try initClash(homeDir: homeDir)
        try setupConfig()
        try invoke(method: "startListener")
    }

    /// initClash: sets the Go core's home dir (only the first call per
    /// process takes effect, see core/hub.go handleInitClash).
    func initClash(homeDir: URL) throws {
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let initParams = try jsonString(["home-dir": homeDir.path, "version": osMajor])
        guard (try invoke(method: "initClash", data: initParams)) as? Bool == true else {
            throw ClashCoreError(message: "initClash returned false")
        }
    }

    /// setupConfig: parses and applies <home-dir>/config.yaml.
    func setupConfig() throws {
        // Defaults from core/common.go defaultSetupParams().
        let setupParams = try jsonString([
            "selected-map": [String: String](),
            "test-url": "https://www.gstatic.com/generate_204",
        ])
        let setupError = (try invoke(method: "setupConfig", data: setupParams)) as? String ?? ""
        if !setupError.isEmpty {
            // Go falls back to an empty default config in this case.
            throw ClashCoreError(message: "setupConfig: \(setupError)")
        }
    }

    /// Forwards core log events at warning level or above (the config's
    /// log-level still filters on the Go side) to `onLog`.
    func startLog(onLog: @escaping (String, String) -> Void) throws {
        let listener = Self.retained { value in
            guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                  let message = object["data"] as? [String: Any],
                  message["type"] as? String == "log",
                  let event = message["data"] as? [String: Any],
                  let level = event["LogLevel"] as? String,
                  level == "warning" || level == "error",
                  let payload = event["Payload"] as? String
            else { return }
            onLog(level, payload)
        }
        setEventListener(listener)
        try invoke(method: "startLog")
    }

    /// Starts the TUN listener on the utun fd owned by NEPacketTunnelProvider.
    /// Values mirror android/service/.../VpnService.kt. Go only logs failures.
    func startTun(fd: Int32, stack: String, address: String, dns: String) {
        _ = startTUN(nil, fd, strdup(stack), strdup(address), strdup(dns))
    }

    func stop() {
        stopTun()
    }

    func gc() {
        forceGC()
    }

    private func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
