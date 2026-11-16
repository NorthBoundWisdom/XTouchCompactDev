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
                    .accessibilityIdentifier("mcp.enabled")
                Toggle(l.text("Allow Agent writes"), isOn: Binding(get: { snapshot.mcpWritesAllowed }, set: { intents.setMCPWritesAllowed?($0) }))
                    .accessibilityIdentifier("mcp.permission.parameterWrite")
                Toggle(l.text("Allow Agent motor moves"), isOn: Binding(get: { snapshot.mcpMotorWritesAllowed }, set: { intents.setMCPMotorWritesAllowed?($0) }))
                    .accessibilityIdentifier("mcp.permission.motorWrites").disabled(!snapshot.mcpWritesAllowed)
                Text(l.text("Off by default and never restored on launch. Without it, Agent writes update values, rings and LEDs but leave faders in place."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(l.text("Allow simulation administration"), isOn: Binding(get: { snapshot.mcpSimulationControlAllowed }, set: { intents.setMCPSimulationControlAllowed?($0) }))
                    .accessibilityIdentifier("mcp.permission.simulationControl")
                Text(l.text("Simulation reset also requires Agent writes. Remote time advance is unavailable while the host drives the clock."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(l.text("Allow Agent task control"), isOn: Binding(get: { snapshot.mcpAgentControlAllowed }, set: { intents.setMCPAgentControlAllowed?($0) }))
                    .accessibilityIdentifier("mcp.permission.agentControl").disabled(!snapshot.mcpWritesAllowed)
                Text(l.text("Remote write limit: 60 per second; HTTP limit: 60 requests per minute."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(l.text("Recent MCP calls")) {
                    ForEach(snapshot.mcpAudit.reversed()) { entry in
                        HStack {
                            Text(entry.time, style: .time)
                            Text(entry.method).monospaced()
                            Spacer()
                            Text(l.text(entry.succeeded ? "Completed" : "Rejected"))
                        }.font(.caption)
                    }
                }.accessibilityIdentifier("mcpSettings.recentMcpCalls")
                Button(l.text("Copy access token")) { intents.copyMCPToken?() }.accessibilityIdentifier("mcpSettings.copyAccessToken")
            }
            Section(l.text("OSC output")) {
                Text(l.text("OSC requires trusted destination actual-state feedback and an independent heartbeat. This version has no built-in receiver configuration for that feedback; enabling output alone cannot make it ready."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(l.text("Host"), text: $host)
                    .accessibilityIdentifier("mcpSettings.host")
                TextField(l.text("Port"), value: $port, format: .number.grouping(.never))
                    .accessibilityIdentifier("mcpSettings.port")
                Picker(l.text("Parameter"), selection: $parameter) {
                    ForEach(snapshot.configuration.parameters) { Text($0.name + " · " + $0.id).tag($0.id) }
                }.accessibilityIdentifier("mcpSettings.parameter")
                Button(l.text("Apply output destination")) { intents.configureOSC?(host, port, parameter) }.accessibilityIdentifier("mcpSettings.applyOutputDestination")
                Toggle(l.text("Enable output"), isOn: Binding(get: { snapshot.oscEnabled }, set: { intents.setOSCEnabled?($0) }))
                    .accessibilityIdentifier("mcpSettings.enableOutput")
                Text(l.text("OSC limits: 0…1, maximum 0.25/s, independent heartbeat 0.3 s. Never restored on launch."))
                    .font(.caption)
                Text("OUT: \(snapshot.oscOutput.formatted())")
            }
            .onChange(of: snapshot.oscHost) { _, value in host = value }
            .onChange(of: snapshot.oscPort) { _, value in port = value }
            .onChange(of: snapshot.oscParameter) { _, value in parameter = value }
        }
    }
#endif
