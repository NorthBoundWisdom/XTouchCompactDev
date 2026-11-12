#if os(macOS)
    import SwiftUI
    import XTouchCompactCore

    enum Theme {
        static let background = Color(red: 0.055, green: 0.06, blue: 0.072)
        static let surface = Color.white.opacity(0.045)
        static let stroke = Color.white.opacity(0.08)
        static let chassisTop = Color(red: 0.15, green: 0.155, blue: 0.17)
        static let chassisBottom = Color(red: 0.085, green: 0.09, blue: 0.105)
        static let slot = Color.black.opacity(0.55)
        /// Encoder ring LEDs.
        static let ring = Color(red: 1.0, green: 0.62, blue: 0.16)
        /// Button LEDs.
        static let led = Color(red: 1.0, green: 0.27, blue: 0.2)
        static let ledOff = Color.white.opacity(0.09)
        static let value = Color(red: 0.25, green: 0.82, blue: 0.78)
        static let touch = Color(red: 0.98, green: 0.82, blue: 0.3)
        static let observed = Color(red: 0.62, green: 0.72, blue: 1.0)
        static let selection = Color(red: 0.42, green: 0.62, blue: 1.0)

        /// Parameter color tags; saturated enough to read as a thin strip on the dark chassis.
        static func tag(_ color: ParameterColor) -> Color {
            switch color {
            case .red: Color(red: 0.94, green: 0.33, blue: 0.31)
            case .orange: Color(red: 0.98, green: 0.58, blue: 0.22)
            case .yellow: Color(red: 0.95, green: 0.83, blue: 0.27)
            case .green: Color(red: 0.36, green: 0.8, blue: 0.42)
            case .teal: Color(red: 0.24, green: 0.78, blue: 0.76)
            case .blue: Color(red: 0.36, green: 0.58, blue: 0.98)
            case .purple: Color(red: 0.66, green: 0.47, blue: 0.95)
            case .pink: Color(red: 0.95, green: 0.45, blue: 0.7)
            }
        }
    }

    struct PanelStyle: ViewModifier {
        var padding: CGFloat = 14

        func body(content: Content) -> some View {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke) }
        }
    }

    extension View {
        func panelStyle(padding: CGFloat = 14) -> some View {
            modifier(PanelStyle(padding: padding))
        }
    }

    struct SectionTitle: View {
        let title: String
        let icon: String

        init(_ title: String, icon: String) {
            self.title = title
            self.icon = icon
        }

        var body: some View {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .tracking(0.8)
        }
    }

    /// The virtual panel scales as a whole: every dimension is `base * scale`.
    struct PanelMetrics: Equatable {
        static let naturalSize = CGSize(width: 794, height: 590)
        static let scaleRange: ClosedRange<CGFloat> = 1 ... 1.6

        var scale: CGFloat = 1

        func callAsFunction(_ base: CGFloat) -> CGFloat {
            base * scale
        }
    }

    private struct PanelMetricsKey: EnvironmentKey {
        static let defaultValue = PanelMetrics()
    }

    extension EnvironmentValues {
        var panelMetrics: PanelMetrics {
            get { self[PanelMetricsKey.self] }
            set { self[PanelMetricsKey.self] = newValue }
        }
    }
#endif
