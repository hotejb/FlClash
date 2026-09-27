import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var tunnel = TunnelController()
    @State private var yaml = ""
    @State private var importing = false

    private static let sampleConfig = """
    # Minimal config for memory measurement. Keep log-level at warning or
    # above so log forwarding does not skew the numbers.
    mode: rule
    log-level: warning
    ipv6: false
    dns:
      enable: true
      ipv6: false
      enhanced-mode: fake-ip
      nameserver:
        - 223.5.5.5
        - 1.1.1.1
    proxies: []
    rules:
      - MATCH,DIRECT
    """

    var body: some View {
        NavigationView {
            Form {
                Section("Tunnel") {
                    LabeledRow("Status", tunnel.status.label)
                    LabeledRow("Stage", tunnel.stage)
                    Picker("TUN stack", selection: $tunnel.stack) {
                        ForEach(Shared.stacks, id: \.self) { Text($0) }
                    }
                    Button("Install / save VPN profile") { Task { await tunnel.install() } }
                    Button("Start") { tunnel.start() }
                    Button("Stop") { tunnel.stop() }
                    Button("Force GC in extension") { tunnel.forceGC() }
                    if !tunnel.message.isEmpty {
                        Text(tunnel.message).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("Extension memory") {
                    LabeledRow("phys_footprint", Memory.format(tunnel.footprint))
                    LabeledRow("Peak", Memory.format(tunnel.peakFootprint))
                    LabeledRow("Available before limit", Memory.format(tunnel.availableMemory))
                    LabeledRow("Implied limit", Memory.format(tunnel.footprint + tunnel.availableMemory))
                    if let updatedAt = tunnel.updatedAt {
                        LabeledRow("Updated", updatedAt.formatted(date: .omitted, time: .standard))
                    }
                }

                if !tunnel.lastError.isEmpty || !tunnel.coreLog.isEmpty {
                    Section("Errors") {
                        if !tunnel.lastError.isEmpty {
                            Text(tunnel.lastError).foregroundColor(.red).textSelection(.enabled)
                        }
                        ForEach(Array(tunnel.coreLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                Section("Clash config (App Group config.yaml)") {
                    TextEditor(text: $yaml)
                        .font(.caption.monospaced())
                        .frame(minHeight: 220)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    Button("Import YAML file…") { importing = true }
                    Button("Use sample config") { yaml = Self.sampleConfig }
                    Button("Save config") { tunnel.saveConfig(yaml) }
                }
            }
            .navigationTitle("FlClash PoC")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if yaml.isEmpty { yaml = tunnel.loadConfig() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.yaml, .plainText, .data]) { result in
            switch result {
            case let .success(url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    yaml = try String(contentsOf: url, encoding: .utf8)
                    tunnel.message = "imported \(url.lastPathComponent); tap Save config"
                } catch {
                    tunnel.message = "import: \(error.localizedDescription)"
                }
            case let .failure(error):
                tunnel.message = "import: \(error.localizedDescription)"
            }
        }
    }
}

private struct LabeledRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
