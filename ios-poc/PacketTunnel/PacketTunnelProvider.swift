import NetworkExtension
import os

class PacketTunnelProvider: NEPacketTunnelProvider {
    // Same values as android/service/src/main/java/com/follow/clash/service/VpnService.kt
    private static let ipv4Address = "172.19.0.1"
    private static let ipv4Prefix = "172.19.0.1/30"
    private static let ipv4Mask = "255.255.255.252"
    private static let dnsServer = "172.19.0.2"
    private static let mtu = 9000

    private let logger = Logger(subsystem: "FlClashPoC", category: "PacketTunnel")
    private let reporterQueue = DispatchQueue(label: "poc.memory-reporter")
    private var reporter: DispatchSourceTimer?
    private var peakFootprint: UInt64 = 0
    private var coreLog: [String] = []
    private let coreLogLock = NSLock()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let defaults = Shared.defaults
        defaults.removeObject(forKey: Shared.Key.lastError)
        defaults.removeObject(forKey: Shared.Key.coreLog)
        defaults.set(0, forKey: Shared.Key.peakFootprint)
        startReporter()
        setStage("applying network settings")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [Self.ipv4Address], subnetMasks: [Self.ipv4Mask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [Self.dnsServer])
        dns.matchDomains = [""] // send all DNS queries to the tunnel resolver
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: Self.mtu)

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.fail("setTunnelNetworkSettings: \(error.localizedDescription)", completionHandler)
                return
            }
            // Go calls block; keep them off the NE callback queue.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.startCore()
                    self.setStage("running")
                    completionHandler(nil)
                } catch {
                    self.fail(error.localizedDescription, completionHandler)
                }
            }
        }
    }

    private func startCore() throws {
        let home = Shared.clashHomeURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: Shared.configURL.path) else {
            throw ClashCoreError(message: "no config.yaml in the App Group; save one from the app first")
        }

        let core = ClashCore.shared
        setStage("starting core")
        try core.startLog { [weak self] level, payload in
            self?.appendCoreLog("[\(level)] \(payload)")
        }
        try core.start(homeDir: home)

        setStage("locating utun fd")
        guard let fd = TunnelFD.find(packetFlow: packetFlow) else {
            throw ClashCoreError(message: "could not find the utun file descriptor")
        }
        let stack = Shared.defaults.string(forKey: Shared.Key.stack) ?? Shared.defaultStack
        logger.info("startTUN fd=\(fd) (\(TunnelFD.interfaceName(fd: fd) ?? "?", privacy: .public)) stack=\(stack, privacy: .public)")
        setStage("starting TUN (fd \(fd), \(stack))")
        guard core.startTun(fd: fd, stack: stack, address: Self.ipv4Prefix, dns: Self.dnsServer) else {
            throw ClashCoreError(message: "the core refused to start the TUN; see the core error log")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        setStage("stopped (reason \(reason.rawValue))")
        ClashCore.shared.stop()
        reporter?.cancel()
        reporter = nil
        reporterQueue.sync { report() }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(decoding: messageData, as: UTF8.self) == Shared.forceGCMessage {
            ClashCore.shared.gc()
            reporterQueue.async { self.report() }
        }
        completionHandler?(nil)
    }

    // MARK: - Reporting to the app through the App Group

    private func startReporter() {
        let timer = DispatchSource.makeTimerSource(queue: reporterQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.report() }
        timer.resume()
        reporter = timer
    }

    private func report() {
        guard let footprint = Memory.physFootprint() else { return }
        peakFootprint = max(peakFootprint, footprint)
        let defaults = Shared.defaults
        defaults.set(NSNumber(value: footprint), forKey: Shared.Key.footprint)
        defaults.set(NSNumber(value: peakFootprint), forKey: Shared.Key.peakFootprint)
        defaults.set(NSNumber(value: os_proc_available_memory()), forKey: Shared.Key.availableMemory)
        defaults.set(Date().timeIntervalSince1970, forKey: Shared.Key.updatedAt)
    }

    private func setStage(_ stage: String) {
        logger.info("stage: \(stage, privacy: .public)")
        Shared.defaults.set(stage, forKey: Shared.Key.stage)
    }

    private func appendCoreLog(_ line: String) {
        logger.warning("core: \(line, privacy: .public)")
        coreLogLock.lock()
        coreLog.append(line)
        if coreLog.count > 20 { coreLog.removeFirst(coreLog.count - 20) }
        let snapshot = coreLog
        coreLogLock.unlock()
        Shared.defaults.set(snapshot, forKey: Shared.Key.coreLog)
    }

    private func fail(_ message: String, _ completionHandler: (Error?) -> Void) {
        logger.error("start failed: \(message, privacy: .public)")
        Shared.defaults.set(message, forKey: Shared.Key.lastError)
        setStage("failed")
        completionHandler(ClashCoreError(message: message))
    }
}
