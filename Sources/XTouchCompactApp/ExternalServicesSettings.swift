#if os(macOS)
    import SwiftUI
    import XTouchCompactLocalization

    struct ExternalServicesSettings: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var host: String
        @State private var port: UInt16
        @State private var parameter: String
        init(snapshot: PanelSnapshot, intents: PanelIntents) {
            self.snapshot = snapshot; self.intents = intents
            _host = State(initialValue: snapshot.oscHost)
            _port = State(initialValue: snapshot.oscPort)
            _parameter = State(initialValue: snapshot.oscParameter)
        }

        private var l: Localizer {
            language.localizer
        }

        var body: some View {
            Section("MCP · 127.0.0.1:\(String(snapshot.mcpPort))/mcp") {
                Toggle(l.text("Enable MCP"), isOn: Binding(get: { snapshot.mcpEnabled }, set: { intents.setMCPEnabled?($0) }))
                Toggle(l.text("Allow Agent writes"), isOn: Binding(get: { snapshot.mcpWritesAllowed }, set: { intents.setMCPWritesAllowed?($0) }))
                Button(l.text("Copy access token")) { intents.copyMCPToken?() }
            }
            Section(l.text("OSC output")) {
                TextField(l.text("Host"), text: $host)
                TextField(l.text("Port"), value: $port, format: .number.grouping(.never))
                Picker(l.text("Parameter"), selection: $parameter) {
                    ForEach(snapshot.configuration.parameters) { Text($0.name + " · " + $0.id).tag($0.id) }
                }
                Button(l.text("Apply output destination")) { intents.configureOSC?(host, port, parameter) }
                Toggle(l.text("Enable output"), isOn: Binding(get: { snapshot.oscEnabled }, set: { intents.setOSCEnabled?($0) }))
                Text(l.text("OSC limits: 0…1, maximum 0.25/s, heartbeat 1 s. Never restored on launch."))
                    .font(.caption)
                Text(l.text("OSC keeps stationary values active. A scheduler pause over 1 s stops output."))
                    .font(.caption).foregroundStyle(.secondary)
                Text("OUT: \(snapshot.oscOutput.formatted())")
            }
            .onChange(of: snapshot.oscHost) { _, value in host = value }
            .onChange(of: snapshot.oscPort) { _, value in port = value }
            .onChange(of: snapshot.oscParameter) { _, value in parameter = value }
        }
    }
#endif
