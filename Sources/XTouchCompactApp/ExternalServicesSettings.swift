#if os(macOS)
    import SwiftUI
    import XTouchCompactLocalization

    struct ExternalServicesSettings: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var host = "127.0.0.1"
        @State private var port: UInt16 = 9000
        @State private var parameter = "a.Fader.1"
        private var l: Localizer {
            language.localizer
        }

        var body: some View {
            Section("MCP · 127.0.0.1:8765/mcp") {
                Toggle(l.text("Enable MCP"), isOn: Binding(get: { snapshot.mcpEnabled }, set: { intents.setMCPEnabled?($0) }))
                Toggle(l.text("Allow Agent writes"), isOn: Binding(get: { snapshot.mcpWritesAllowed }, set: { intents.setMCPWritesAllowed?($0) }))
                Button(l.text("Copy access token")) { intents.copyMCPToken?() }
            }
            Section(l.text("OSC output")) {
                TextField(l.text("Host"), text: $host)
                TextField(l.text("Port"), value: $port, format: .number)
                Picker(l.text("Parameter"), selection: $parameter) {
                    ForEach(snapshot.configuration.parameters) { Text($0.name + " · " + $0.id).tag($0.id) }
                }
                Button(l.text("Apply output destination")) { intents.configureOSC?(host, port, parameter) }
                Toggle(l.text("Enable output"), isOn: Binding(get: { snapshot.oscEnabled }, set: { intents.setOSCEnabled?($0) }))
                Text(l.text("OSC limits: 0…1, maximum 0.25/s, heartbeat 1 s. Never restored on launch."))
                    .font(.caption)
                Text("OUT: \(snapshot.oscOutput.formatted())")
            }
        }
    }
#endif
