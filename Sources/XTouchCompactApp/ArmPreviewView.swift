#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct ArmPreviewView: View {
        let snapshot: PanelSnapshot
        @EnvironmentObject private var language: LanguageSettings
        var body: some View {
            let l = language.localizer
            VStack(alignment: .leading, spacing: 12) {
                Text(l.text("Arm preview")).font(.headline)
                Text(l.text("Illustrative pose · software values only")).font(.caption).foregroundStyle(.secondary)
                if let pose = snapshot.armPreview {
                    HStack {
                        drawing(pose, top: false).frame(minWidth: 240, minHeight: 240)
                        drawing(pose, top: true).frame(width: 180, height: 240)
                    }
                    ForEach(Array(pose.joints.enumerated()), id: \.offset) { index, value in
                        Text("J\(index + 1): \(value.formatted(.number.precision(.fractionLength(0 ... 2))))°").monospacedDigit()
                    }
                    if let value = pose.wristRoll {
                        Text("J5: \(value.formatted())°")
                    }
                    if let value = pose.toolRoll {
                        Text("J6: \(value.formatted())°")
                    }
                    if let value = pose.gripper {
                        Text(l.text("example.arm.gripper") + ": " + value.formatted() + "%")
                    }
                    if let value = pose.speed {
                        Text(l.text("example.arm.speed") + ": " + value.formatted() + "%")
                    }
                    if let enabled = pose.enabled {
                        Text(l.text(enabled ? "Enabled" : "Disabled"))
                    }
                } else {
                    Text(l.text("Reference-arm parameters arm.j1–arm.j4 in degrees are missing. Launch with --reference-arm-example to load the example."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding()
        }

        private func drawing(_ pose: ArmPreviewSnapshot, top: Bool) -> some View {
            let title = language.localizer.text(top ? "Top view" : "Side view")
            return VStack {
                Text(title).font(.caption)
                Canvas { context, size in
                    let origin = CGPoint(x: size.width / 2, y: top ? size.height / 2 : size.height - 20)
                    let scale = min(size.width / 4.8, size.height / 2.5)
                    let points = top ? [ArmPreviewSnapshot.Point(x: 0, y: 0), pose.topDirection] : pose.sidePoints
                    let projected = points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y - $0.y * scale) }
                    var path = Path(); path.addLines(projected)
                    context.stroke(path, with: .color(pose.enabled == true ? .cyan : .gray), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    for point in projected {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(.orange))
                    }
                }
            }.background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    struct PanelMenu: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        var body: some View {
            Toggle(language.localizer.text("Arm preview"), isOn: Binding(get: { snapshot.armPreviewVisible }, set: { intents.setArmPreviewVisible?($0) }))
                .accessibilityIdentifier("workspace.panel.armPreview")
        }
    }
#endif
