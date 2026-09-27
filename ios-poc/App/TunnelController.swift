import Foundation
import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    @Published var manager: NETunnelProviderManager?
    @Published var status: NEVPNStatus = .invalid
    @Published var message = ""

    // Values published by the extension (see PacketTunnelProvider.report()).
    @Published var footprint: UInt64 = 0
    @Published var peakFootprint: UInt64 = 0
    @Published var availableMemory: UInt64 = 0
    @Published var updatedAt: Date?
    @Published var stage = ""
    @Published var lastError = ""
    @Published var coreLog: [String] = []

    @Published var stack: String {
        didSet { Shared.defaults.set(stack, forKey: Shared.Key.stack) }
    }

    private var timer: Timer?
    private var statusObserver: NSObjectProtocol?

    private var tunnelBundleId: String {
        Bundle.main.object(forInfoDictionaryKey: "POCTunnelBundleId") as? String ?? ""
    }

    init() {
        stack = Shared.defaults.string(forKey: Shared.Key.stack) ?? Shared.defaultStack
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.status = self?.manager?.connection.status ?? .invalid }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshShared() }
        }
        Task { await load() }
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleId
            }
            status = manager?.connection.status ?? .invalid
        } catch {
            message = "load: \(error.localizedDescription)"
        }
    }

    func install() async {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.serverAddress = "FlClash PoC"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "FlClash PoC"
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            status = manager.connection.status
            message = "VPN profile saved"
        } catch {
            message = "save: \(error.localizedDescription)"
        }
    }

    func start() {
        guard let manager else {
            message = "install the VPN profile first"
            return
        }
        do {
            try manager.connection.startVPNTunnel()
            message = "starting"
        } catch {
            message = "start: \(error.localizedDescription)"
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func forceGC() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data(Shared.forceGCMessage.utf8)) { _ in }
        } catch {
            message = "forceGC: \(error.localizedDescription)"
        }
    }

    func loadConfig() -> String {
        (try? String(contentsOf: Shared.configURL, encoding: .utf8)) ?? ""
    }

    func saveConfig(_ yaml: String) {
        do {
            try FileManager.default.createDirectory(at: Shared.clashHomeURL, withIntermediateDirectories: true)
            try yaml.write(to: Shared.configURL, atomically: true, encoding: .utf8)
            message = "config.yaml saved (\(yaml.utf8.count) bytes); restart the tunnel to apply"
        } catch {
            message = "save config: \(error.localizedDescription)"
        }
    }

    private func refreshShared() {
        let defaults = Shared.defaults
        footprint = (defaults.object(forKey: Shared.Key.footprint) as? NSNumber)?.uint64Value ?? 0
        peakFootprint = (defaults.object(forKey: Shared.Key.peakFootprint) as? NSNumber)?.uint64Value ?? 0
        availableMemory = (defaults.object(forKey: Shared.Key.availableMemory) as? NSNumber)?.uint64Value ?? 0
        let timestamp = defaults.double(forKey: Shared.Key.updatedAt)
        updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        stage = defaults.string(forKey: Shared.Key.stage) ?? ""
        lastError = defaults.string(forKey: Shared.Key.lastError) ?? ""
        coreLog = defaults.stringArray(forKey: Shared.Key.coreLog) ?? []
        if let manager { status = manager.connection.status }
    }
}

extension NEVPNStatus {
    var label: String {
        switch self {
        case .invalid: return "not installed"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}
