import Foundation

/// State shared between the app and the PacketTunnel extension through the
/// App Group. The group id comes from Info.plist (POCAppGroup), which is
/// filled from the POC_APP_GROUP build setting in project.yml.
enum Shared {
    static let appGroup: String = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "POCAppGroup") as? String,
              !group.isEmpty, !group.contains("$(")
        else {
            fatalError("POCAppGroup missing from Info.plist; regenerate the project with xcodegen")
        }
        return group
    }()

    static var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            fatalError("App Group \(appGroup) is not available; check entitlements")
        }
        return defaults
    }

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            fatalError("App Group container for \(appGroup) is not available; check entitlements")
        }
        return url
    }

    /// Go core home dir (constant.SetHomeDir). setupConfig reads config.yaml from here.
    static var clashHomeURL: URL {
        containerURL.appendingPathComponent("clash", isDirectory: true)
    }

    static var configURL: URL {
        clashHomeURL.appendingPathComponent("config.yaml")
    }

    static let stacks = ["mixed", "system", "gvisor"]
    /// FlClash's default TunStack is mixed (lib/models/clash_config.dart).
    static let defaultStack = "mixed"

    enum Key {
        static let stack = "poc.stack"
        static let footprint = "poc.footprint"
        static let peakFootprint = "poc.peakFootprint"
        static let availableMemory = "poc.availableMemory"
        static let updatedAt = "poc.updatedAt"
        static let stage = "poc.stage"
        static let lastError = "poc.lastError"
        static let coreLog = "poc.coreLog"
    }

    /// Message the app sends via NETunnelProviderSession.sendProviderMessage.
    static let forceGCMessage = "forceGC"
}
