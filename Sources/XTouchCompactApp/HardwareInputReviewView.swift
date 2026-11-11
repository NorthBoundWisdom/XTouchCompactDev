#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct HardwareInputReviewView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var layer: CompactLayer = .a
        @State private var group: CompactInputGroup = .touches
        @State private var incompleteOnly = false
        @State private var followsInputLayer = true
        private var l: Localizer {
            language.localizer
        }

        private var observation: HardwareObservationPresentation {
            snapshot.hardwareObservation ?? .init()
        }

        private var selected: LayerInputReviewPresentation? {
            observation.reviewLayers.first { $0.layer == layer }
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explanation
                    HStack(spacing: 16) {
                        ForEach(observation.reviewLayers) { item in
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Layer \(item.layer.rawValue.uppercased())").font(.title2.bold())
                                Text(l.text("Inputs received: %@ / %@", String(item.observedCount), String(item.rows.count)))
                                Text(l.text("Range/pair coverage: %@ / %@", String(item.coveredCount), String(item.rows.count)))
                                    .font(.caption).foregroundStyle(Theme.value)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).panelStyle()
                        }
                    }
                    HStack(spacing: 16) {
                        Picker(l.text("Review layer"), selection: Binding(get: { layer }, set: { layer = $0; followsInputLayer = false })) {
                            ForEach(CompactLayer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 180)
                        Picker(l.text("Control group"), selection: $group) {
                            ForEach(CompactInputGroup.allCases, id: \.self) { Text(l.text($0.titleKey)).tag($0) }
                        }.frame(width: 250)
                        Toggle(l.text("Follow input layer"), isOn: $followsInputLayer).toggleStyle(.checkbox)
                        Toggle(l.text("Show incomplete only"), isOn: $incompleteOnly).toggleStyle(.checkbox)
                        Spacer()
                    }
                    rows
                    crossLayerEvidence
                    if let receipt = observation.exportedReview {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(l.text("Review exported"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.value)
                            Text(receipt.path).textSelection(.enabled)
                            Text("SHA-256: \(receipt.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                            if receipt.captureSnapshotPath != nil {
                                Text(l.text("Keep the JSON, checksum and capture snapshot together.")).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(l.text("No raw recording attached; these counters alone are not capture evidence."))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }.panelStyle()
                    }
                    if let error = snapshot.runtimeError {
                        Text(l.text(error)).foregroundStyle(.orange)
                    }
                }
                .padding(18).frame(maxWidth: 1400)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onAppear {
                if let inputLayer = observation.inputLayer {
                    layer = inputLayer
                }
            }
            .onChange(of: observation.inputLayer) { _, value in
                if followsInputLayer, let value {
                    layer = value
                }
            }
            .onChange(of: followsInputLayer) { _, value in
                if value, let inputLayer = observation.inputLayer {
                    layer = inputLayer
                }
            }
        }

        private var explanation: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(l.text("Stage 1 · physical inputs"), systemImage: "checklist").font(.title2.bold())
                    Spacer()
                    if !observation.isPreview {
                        Label(snapshot.connection.connectedInput?.name ?? l.text("Waiting for MIDI input connection"), systemImage: "cable.connector.horizontal")
                            .foregroundStyle(snapshot.connection.connectedInput == nil ? Color.orange : Theme.value)
                    }
                }
                if observation.isPreview {
                    Text(l.text("Preview data")).foregroundStyle(Theme.touch)
                }
                if let latest = observation.latest, !latest.matchesConfiguredChannel {
                    Text(l.text("Received channel %@; configured TX is %@", String(latest.channel), String(snapshot.transmitChannel)))
                        .foregroundStyle(.orange)
                } else if let latest = observation.latest, latest.input == nil {
                    Text(l.text("Unmapped message · raw input retained") + " · " + latest.message.description).foregroundStyle(.orange)
                }
                Text(l.text("Use physical A/B buttons, then operate every control. Viewing another layer here sends nothing."))
                Text(l.text("Faders and encoders: reach 0 and 127. Touches, pushes and buttons: press/touch, then release."))
                    .foregroundStyle(.secondary)
                Text(l.text("Coverage is evidence, not hardware sign-off. Verify physical positions and printed legends yourself."))
                    .font(.caption).foregroundStyle(Theme.touch)
                Text(l.text("Reset clears these counters, not the recording."))
                    .font(.caption).foregroundStyle(.secondary)
            }.panelStyle()
        }

        private var rows: some View {
            VStack(alignment: .leading, spacing: 0) {
                rowColumns(control: l.text("Control"), events: l.text("Events"), range: l.text("Min–max"), edges: l.text("Press / release"), pairs: l.text("Pairs"), address: l.text("Received address"), status: l.text("Input coverage"))
                    .font(.caption.bold()).foregroundStyle(.secondary).padding(.bottom, 9)
                Divider()
                ForEach((selected?.rows ?? []).filter { $0.group == group && (!incompleteOnly || !$0.hasInputCoverage || $0.hasAnomalies) }) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        rowColumns(control: item.control.shortName, events: String(item.review.eventCount),
                                   range: item.rangeText,
                                   edges: item.group.requiresPressRelease ? "\(item.review.pressCount) / \(item.review.releaseCount)" : "—",
                                   pairs: item.group.requiresPressRelease ? String(item.review.pairCount) : "—",
                                   address: item.review.addresses.map(\.description).sorted().joined(separator: ", "), status: l.text(item.statusKey))
                        if item.hasAnomalies {
                            Text(l.text("Repeated presses: %@ · unmatched releases: %@", String(item.review.duplicatePressCount), String(item.review.unmatchedReleaseCount)))
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
            }.panelStyle()
        }

        private func rowColumns(control: String, events: String, range: String, edges: String, pairs: String, address: String, status: String) -> some View {
            HStack(spacing: 14) {
                Text(control).frame(width: 60, alignment: .leading)
                Text(events).frame(width: 50, alignment: .trailing)
                Text(range).frame(width: 90, alignment: .center)
                Text(edges).frame(width: 100, alignment: .center)
                Text(pairs).frame(width: 50, alignment: .center)
                Text(address.isEmpty ? "—" : address).frame(maxWidth: .infinity, alignment: .leading)
                Text(status).frame(width: 150, alignment: .trailing)
            }.font(.callout.monospaced())
        }

        private var crossLayerEvidence: some View {
            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(l.text("Cross-layer release evidence"), icon: "arrow.left.arrow.right")
                Text(l.text("Hold F1 on A, select physical B, turn E1 to record B, then release F1. Repeat B → A."))
                    .font(.callout)
                if observation.crossLayerReleases.isEmpty {
                    Text(l.text("No cross-layer release observed yet.")).foregroundStyle(.secondary)
                }
                ForEach(observation.crossLayerReleases) { event in
                    Text(event.control.shortName + " · " + l.text("Press %@ · during %@ · release %@ · %@ event(s)", event.pressedLayer.rawValue.uppercased(), event.interveningLayer?.rawValue.uppercased() ?? "—", event.releasedLayer.rawValue.uppercased(), String(event.count)))
                        .font(.callout.monospaced()).foregroundStyle(Theme.value)
                }
                Text(l.text("This records the release address layer; it does not prove that the A/B key itself sent no message."))
                    .font(.caption).foregroundStyle(.secondary)
            }.panelStyle()
        }
    }
#endif
