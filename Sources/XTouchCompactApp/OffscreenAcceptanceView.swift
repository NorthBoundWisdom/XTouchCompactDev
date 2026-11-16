#if os(macOS)
    import SwiftUI
    import XTouchCompactCore

    /// Test carrier for the unchanged production views. Native menus/dialogs remain manual.
    struct OffscreenAcceptanceView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @State private var page = "main"
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(["main", "settings", "organize", "offline", "parameters", "macros", "arm", "connection"], id: \.self) { name in
                        Button(name) { page = name }.accessibilityIdentifier("fixture.page.\(name)")
                    }
                    Button("Capture owned view") { intents.integrationCapture?() }.accessibilityIdentifier("fixture.capture")
                }
                HStack {
                    Button("Mock touch F1") { intents.touchFader?(1, true) }.accessibilityIdentifier("fixture.touch")
                    Button("Mock release F1") { intents.touchFader?(1, false) }.accessibilityIdentifier("fixture.release")
                    Button("Mock touch F2") { intents.touchFader?(2, true) }.accessibilityIdentifier("fixture.touch2")
                    Button("Mock release F2") { intents.touchFader?(2, false) }.accessibilityIdentifier("fixture.release2")
                    Button("Agent value 90") { intents.integrationAgentWrite?(90) }.accessibilityIdentifier("fixture.agent90")
                    Button("Agent value 70") { intents.integrationAgentWrite?(70) }.accessibilityIdentifier("fixture.agent70")
                    Button("Mock layer B input") { intents.integrationPhysicalLayer?(.b) }.accessibilityIdentifier("fixture.physicalB")
                    Button("Flush owned values") { intents.integrationFlushValues?() }.accessibilityIdentifier("fixture.flush")
                    Button("Advance injected clock") { intents.integrationAdvance?() }.accessibilityIdentifier("fixture.advance")
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(snapshot.integrationSummary.keys.sorted(), id: \.self) { key in
                            Text(snapshot.integrationSummary[key] ?? "")
                                .accessibilityIdentifier("inspection.\(key)")
                                .accessibilityLabel(key)
                                .accessibilityValue(snapshot.integrationSummary[key] ?? "")
                        }
                    }.font(.caption)
                }.frame(height: 24)
                Group {
                    switch page {
                    case "connection": ConnectionSettingsView(snapshot: snapshot, intents: intents)
                    case "settings": ScrollView { LanguageSettingsView(snapshot: snapshot, intents: intents) }
                    case "organize": ScrollView { OrganizeWorkspace(snapshot: snapshot, intents: intents) }
                    case "offline": OfflineCaptureView(snapshot: snapshot, intents: intents)
                    case "macros": ScrollView { SurfaceProgramsView(snapshot: snapshot, intents: intents) }
                    case "parameters": ParameterWorkspace(snapshot: snapshot, intents: intents)
                    case "arm":
                        VStack {
                            PanelMenu(snapshot: snapshot, intents: intents)
                            ArmPreviewView(snapshot: snapshot)
                        }
                    default: ContentView(snapshot: snapshot, intents: intents)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12).background(Theme.background).preferredColorScheme(.dark)
        }
    }
#endif
