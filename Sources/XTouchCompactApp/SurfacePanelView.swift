#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    /// Virtual X-TOUCH COMPACT front panel.
    ///
    /// Left: eight channel strips (encoder, three buttons, motor fader, button below the fader).
    /// Middle: the master fader strip. Right: eight more encoders, the layer buttons and six
    /// transport buttons. The view renders a `PanelSnapshot` and emits `PanelIntents` only.
    struct SurfacePanelView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @Binding var selection: CompactControl?
        let onSelectLayer: (CompactLayer) -> Void
        @Environment(\.panelMetrics) private var m

        var body: some View {
            VStack(alignment: .leading, spacing: m(12)) {
                header
                HStack(alignment: .top, spacing: m(14)) {
                    HStack(alignment: .top, spacing: m(6)) {
                        ForEach(1 ... PanelLayout.stripCount, id: \.self) { strip in
                            channelStrip(strip)
                        }
                    }
                    masterStrip
                    sideBlock
                }
            }
            .padding(m(18))
            .frame(width: PanelMetrics.naturalSize.width * m.scale, alignment: .leading)
            .background {
                // The shadow belongs to the chassis only, never to the control tree.
                RoundedRectangle(cornerRadius: m(18))
                    .fill(LinearGradient(colors: [Theme.chassisTop, Theme.chassisBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            }
            .overlay { RoundedRectangle(cornerRadius: m(18)).stroke(Theme.stroke) }
        }

        private var header: some View {
            HStack(spacing: m(10)) {
                Text("X-TOUCH COMPACT")
                    .font(.system(size: m(17), weight: .black, design: .rounded))
                    .tracking(2)
                Text(l.text(snapshot.hardwareObservation != nil ? "INPUT OBSERVER" : snapshot.isMock ? "MOCK DEVICE" : "HARDWARE MIRROR"))
                    .font(.system(size: m(9), weight: .bold, design: .monospaced))
                    .foregroundStyle(snapshot.isMock ? Theme.value : .green)
                    .padding(.horizontal, m(7))
                    .padding(.vertical, m(3))
                    .background((snapshot.isMock ? Theme.value : Color.green).opacity(0.14), in: Capsule())
                if let pedals = snapshot.mockPedals, snapshot.hardwareObservation == nil {
                    MockPedalControls(pedals: pedals, intents: intents)
                }
                Spacer()
                Text(snapshot.hardwareObservation != nil ? l.text("Highlights show input, not device LEDs") : snapshot.isMock ? l.text("拖动推子 / 旋钮、按下按键 = 模拟实体操作") : l.text("≈ Last input · — Not yet reported"))
                    .font(.system(size: m(10)))
                    .foregroundStyle(.secondary)
            }
        }

        // MARK: Blocks

        private func channelStrip(_ strip: Int) -> some View {
            VStack(spacing: m(5)) {
                encoderCell(strip)
                ForEach(PanelLayout.stripButtons(strip: strip), id: \.self) { buttonCell($0) }
                faderCell(strip).padding(.top, m(3))
                buttonCell(PanelLayout.selectButton(strip: strip))
            }
            .frame(width: m(62))
        }

        private var masterStrip: some View {
            VStack(spacing: m(5)) {
                // Keeps the master fader level with the channel faders.
                statusIndicators.frame(height: m(EncoderCell.height + 3 * (ButtonCell.height + 5)))
                faderCell(PanelLayout.masterFader).padding(.top, m(3))
                buttonCell(PanelLayout.masterButton)
            }
            .frame(width: m(62))
        }

        private var statusIndicators: some View {
            TimelineView(.periodic(from: .now, by: 0.08)) { context in
                VStack(spacing: m(13)) {
                    statusGroup("INTERFACE") {
                        statusLight("USB", state: snapshot.surfaceStatus.usb, color: .blue, at: context.date)
                    }
                    statusGroup("MIDI") {
                        HStack(spacing: m(7)) {
                            statusLight("IN", state: snapshot.surfaceStatus.midiIn, color: Theme.ring, at: context.date)
                            statusLight("OUT", state: snapshot.surfaceStatus.midiOut, color: Theme.ring, at: context.date)
                        }
                    }
                    statusGroup("FOOT") {
                        HStack(spacing: m(7)) {
                            statusLight("SW", state: snapshot.surfaceStatus.footSwitch, color: Theme.ring, at: context.date)
                            statusLight("EXP", state: snapshot.surfaceStatus.footExpression, color: Theme.ring, at: context.date)
                        }
                    }
                    statusGroup("MODE") {
                        statusLight("MC", state: snapshot.surfaceStatus.mcMode, color: Theme.touch, at: context.date)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .help(l.text(snapshot.isMock ? "Simulated device indicators" : "Device indicator state is not reported"))
        }

        private func statusGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(spacing: m(5)) {
                Text(title)
                    .font(.system(size: m(7), weight: .bold))
                    .tracking(m(0.8))
                    .foregroundStyle(.secondary)
                content()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }

        private func statusLight(_ title: String, state: SurfaceStatusPresentation.Light?, color: Color, at date: Date) -> some View {
            let lit = state?.isLit(at: date)
            return VStack(spacing: m(3)) {
                Circle()
                    .fill(lit == true ? color : Theme.ledOff)
                    .overlay {
                        if lit == nil {
                            Circle().stroke(Color.secondary.opacity(0.6), lineWidth: m(0.8))
                            Text("?").font(.system(size: m(6), weight: .bold)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: m(7), height: m(7))
                    .shadow(color: lit == true ? color.opacity(0.65) : .clear, radius: m(3))
                Text(title)
                    .font(.system(size: m(6), weight: .semibold))
                    .foregroundStyle(lit == true ? color : .secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(l.text(lit.map { $0 ? "On" : "Off" } ?? "Not reported"))
        }

        private var sideBlock: some View {
            VStack(spacing: m(10)) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(m(62)), spacing: m(6)), count: 2), spacing: m(5)) {
                    ForEach(PanelLayout.sideEncoders, id: \.self) { encoderCell($0) }
                }
                layerButtons
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(m(39)), spacing: m(6)), count: 3), spacing: m(5)) {
                    ForEach(PanelLayout.transport) { transport in
                        buttonCell(transport.button, symbol: transport.symbol)
                    }
                }
            }
            .frame(width: m(130))
        }

        private var layerButtons: some View {
            VStack(spacing: m(4)) {
                Text(l.text("Layer")).font(.system(size: m(8), weight: .bold)).foregroundStyle(.secondary).tracking(1)
                HStack(spacing: m(6)) {
                    ForEach(CompactLayer.allCases, id: \.self) { layer in
                        let isActive = snapshot.isLayerHighlighted(layer)
                        Button { onSelectLayer(layer) } label: {
                            Text(layer.rawValue.uppercased())
                                .font(.system(size: m(13), weight: .heavy, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: m(28))
                                .foregroundStyle(isActive ? Color.black : Color.secondary)
                                .background(isActive ? Theme.touch : Color.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: m(6)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l.text("层 %@", String(layer.rawValue.uppercased())))
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .help(l.text("切换到 Layer %@；软件不发电机指令，但设备切层时会自行把推子走一遍", String(layer.rawValue.uppercased())))
                    }
                }
            }
        }

        // MARK: Cells

        /// With a highlighted group, controls outside it are dimmed (display only).
        private func isDimmed(_ group: String?) -> Bool {
            guard let highlighted = snapshot.highlightedGroup else { return false }
            return group != highlighted
        }

        @ViewBuilder
        private func faderCell(_ index: Int) -> some View {
            if let fader = snapshot.fader(index) {
                FaderCell(
                    fader: fader,
                    isDimmed: isDimmed(fader.group),
                    isSelected: selection == .fader(index),
                    onSelect: { selection = .fader(index) },
                    onMove: { intents.moveFader(index, $0) },
                    onTouch: intents.touchFader.map { touch in { touch(index, $0) } }
                )
            }
        }

        @ViewBuilder
        private func encoderCell(_ index: Int) -> some View {
            if let encoder = snapshot.encoder(index) {
                EncoderCell(
                    encoder: encoder,
                    isDimmed: isDimmed(encoder.group),
                    isSelected: selection == .encoder(index) || selection == .encoderPush(index),
                    onSelect: { selection = .encoder(index) },
                    onTurn: { intents.turnEncoder(index, $0) },
                    onPush: intents.pushEncoder.map { push in { push(index, $0) } }
                )
            }
        }

        @ViewBuilder
        private func buttonCell(_ index: Int, symbol: String? = nil) -> some View {
            if let button = snapshot.button(index) {
                ButtonCell(
                    button: button,
                    symbol: symbol,
                    observesInput: snapshot.hardwareObservation != nil,
                    isSelected: selection == .button(index),
                    onSelect: { selection = .button(index) },
                    onPress: { intents.pressButton(index) },
                    onRelease: intents.releaseButton.map { release in { release(index) } }
                )
            }
        }
    }

    // MARK: - Fader

    private struct FaderCell: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let fader: FaderPresentation
        let isDimmed: Bool
        let isSelected: Bool
        let onSelect: () -> Void
        let onMove: (UInt8) -> Void
        let onTouch: ((Bool) -> Void)?
        @Environment(\.panelMetrics) private var m
        @State private var isDragging = false

        private static let slotLength: CGFloat = 196
        private static let capHeight: CGFloat = 38

        private var isTouched: Bool {
            fader.isTouched ?? isDragging
        }

        private var displayedValue: String {
            if fader.mirrorsHardware, !fader.capFollowsTarget {
                guard let reading = fader.hardwareReading else { return "—" }
                return (reading.isCurrent ? "" : "≈") + String(reading.value)
            }
            if fader.followsObservedPosition {
                return fader.observed.map { String($0) } ?? "—"
            }
            return fader.detail ?? String(fader.target)
        }

        /// Send mode only: what is known about the physical cap, kept apart from the target above it.
        private var deviceStatus: (text: String, color: Color)? {
            guard fader.capFollowsTarget else { return nil }
            if fader.isMotorPending == true {
                return (l.text("暂缓"), Theme.touch)
            }
            if fader.motorDelivery == .failed || fader.motorDelivery == .refused {
                return (l.text("未发出"), Theme.led)
            }
            if fader.motorDelivery == .staged {
                return (l.text("待发送"), Theme.touch)
            }
            guard let reading = fader.hardwareReading else { return (l.text("实体 %@", "?"), .secondary) }
            return (l.text("实体 %@", (reading.isCurrent ? "" : "≈") + String(reading.value)), Theme.observed)
        }

        private var isUndelivered: Bool {
            fader.motorDelivery == .failed || fader.motorDelivery == .refused
        }

        private var accessibleValue: String {
            if fader.mirrorsHardware {
                let reading = fader.hardwareReading.map { String($0.value) + " " + l.text($0.isCurrent ? "Last received input" : "Last input · awaiting confirmation") }
                    ?? l.text("Not reported")
                return fader.capFollowsTarget ? String(fader.target) + ", " + (deviceStatus?.text ?? "") + ", " + reading : reading
            }
            if fader.followsObservedPosition {
                let position = fader.observed.map { String($0) } ?? l.text("Not reported")
                let touch = fader.isTouched.map { l.text($0 ? "Touched" : "Released") } ?? l.text("Not reported")
                return position + " " + touch
            }
            return isTouched ? l.text("%@，触摸中", String(fader.capPosition)) : String(fader.target)
        }

        var body: some View {
            VStack(spacing: m(4)) {
                linkBadge
                slot
                colorStrip(fader.color)
                Text(fader.label ?? (fader.isMaster ? "MAIN" : "F\(fader.index)"))
                    .font(.system(size: m(9), weight: .semibold))
                    .foregroundStyle(fader.label == nil ? .secondary : Theme.value)
                    .lineLimit(1)
                Text(displayedValue)
                    .font(.system(size: m(10), design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                if fader.mirrorsHardware {
                    // Fixed height in both hardware modes so strips do not jump on a mode switch.
                    Text(deviceStatus?.text ?? " ")
                        .font(.system(size: m(8), design: .monospaced))
                        .foregroundStyle(deviceStatus?.color ?? .clear)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .help(deviceStatusHelp)
                }
            }
            .padding(.vertical, m(5))
            .frame(maxWidth: .infinity)
            .opacity(isDimmed ? 0.35 : 1)
            .background(isSelected ? Theme.selection.opacity(0.16) : Color.black.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: m(8)))
            .overlay {
                RoundedRectangle(cornerRadius: m(8))
                    .stroke(isTouched ? Theme.touch : isSelected ? Theme.selection : Color.clear, lineWidth: isTouched ? 2.5 : 1.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(CompactControl.fader(fader.index).localizedName(using: l)) \(fader.label ?? "")")
            .accessibilityValue(accessibleValue)
            .accessibilityAdjustableAction { direction in
                onSelect()
                let step = direction == .increment ? 1 : -1
                let nextValue: Int = min(max(Int(fader.target) + step, 0), 127)
                onMove(UInt8(nextValue))
            }
            .help(l.text("拖动 %@", String(CompactControl.fader(fader.index).shortName)))
        }

        private var deviceStatusHelp: String {
            guard fader.capFollowsTarget else { return "" }
            if fader.isMotorPending == true {
                return l.text("触摸期间电机指令已暂缓，松开后再对位")
            }
            if isUndelivered {
                return l.text("电机指令未发出，实体推子没有被驱动")
            }
            if fader.motorDelivery == .staged {
                return l.text("Staged. Press Send to push it to the device.")
            }
            return l.text("滑块是软件目标；设备不回报电机走位，这里只显示实体推子最近一次上报的位置")
        }

        /// Leader shows ⛓ name; members show → name. Empty space keeps strips aligned.
        private var linkBadge: some View {
            let text = switch fader.linkRole {
            case let .leader(name): "⛓ " + name
            case let .member(name): "→ " + name
            case nil: " "
            }
            return Text(text)
                .font(.system(size: m(8), weight: .semibold))
                .foregroundStyle(Theme.touch.opacity(0.9))
                .lineLimit(1)
                .frame(height: m(10))
                .help(fader.linkRole.map { role in
                    switch role {
                    case let .leader(name): l.text("Leads link %@", name)
                    case let .member(name): l.text("Follows link %@", name)
                    }
                } ?? "")
        }

        private func colorStrip(_ color: ParameterColor?) -> some View {
            Capsule()
                .fill(color.map(Theme.tag) ?? Color.clear)
                .frame(width: m(28), height: m(3))
        }

        private var slot: some View {
            let length = m(Self.slotLength)
            let cap = m(Self.capHeight)
            let travel = length - cap
            return ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: m(1.5))
                    .fill(Color.black.opacity(0.85))
                    .frame(width: m(4), height: length)
                // Printed legend of the unit. Cosmetic: MIDI 0...127 stays linear over the travel.
                ForEach(0 ... 40, id: \.self) { tick in
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: m(8), height: 1)
                        .offset(x: m(10), y: cap / 2 + travel * CGFloat(tick) / 40)
                }
                ForEach(PanelLayout.faderScale, id: \.label) { mark in
                    Rectangle()
                        .fill(Color.white.opacity(0.32))
                        .frame(width: m(8), height: 1)
                        .offset(x: -m(8), y: cap / 2 + travel * mark.fromTop)
                    Text(mark.label)
                        .font(.system(size: m(6.5)))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .frame(width: m(16), alignment: .trailing)
                        .offset(x: -m(21), y: cap / 2 + travel * mark.fromTop - m(4))
                }
                if fader.hasCapPosition {
                    capView
                        .opacity(fader.mirrorsHardware && !fader.capFollowsTarget && fader.hardwareReading?.isCurrent == false ? 0.5 : isUndelivered ? 0.6 : 1)
                        .frame(width: m(26), height: cap)
                        .offset(y: travel * (1 - FaderTravel.fraction(for: fader.capPosition)))
                } else {
                    // Position unknown: keep a fader on screen without claiming where it is.
                    RoundedRectangle(cornerRadius: m(4))
                        .stroke(isTouched ? Theme.touch : Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .overlay {
                            Image(systemName: isTouched ? "hand.point.up.left.fill" : "questionmark")
                                .font(.system(size: m(10)))
                                .foregroundStyle(isTouched ? Theme.touch : Color.secondary)
                        }
                        .frame(width: m(26), height: cap)
                        .offset(y: travel / 2)
                }
                if let marker = fader.deviceMarker {
                    // Where the device last reported the fader. Drawn over the cap so it stays readable.
                    Capsule()
                        .fill(Theme.observed)
                        .frame(width: m(34), height: m(3))
                        .opacity(marker.isCurrent ? 1 : 0.55)
                        .offset(y: cap / 2 + travel * (1 - FaderTravel.fraction(for: marker.value)) - m(1.5))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: length)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onSelect()
                            onTouch?(true)
                        }
                        let value = FaderTravel.value(at: gesture.location.y, length: length, cap: cap)
                        // Compare with what a drag changes: in send mode that is the target.
                        if value != (fader.capFollowsTarget ? fader.target : fader.capPosition) {
                            onMove(value)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onTouch?(false)
                    }
            )
        }

        private var capView: some View {
            // Silver cap with a finger dip, like the unit's.
            RoundedRectangle(cornerRadius: m(4))
                .fill(LinearGradient(stops: [
                    .init(color: Color(white: 0.9), location: 0),
                    .init(color: Color(white: 0.62), location: 0.18),
                    .init(color: Color(white: 0.4), location: 0.48),
                    .init(color: Color(white: 0.78), location: 0.56),
                    .init(color: Color(white: 0.5), location: 0.86),
                    .init(color: Color(white: 0.72), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .overlay { Rectangle().fill(Color.black.opacity(0.55)).frame(height: m(1.5)) }
                .overlay {
                    RoundedRectangle(cornerRadius: m(4))
                        .stroke(isTouched ? Theme.touch : isUndelivered ? Theme.led : Color.black.opacity(0.6),
                                lineWidth: isTouched || isUndelivered ? 2 : 1)
                }
                .shadow(color: isTouched ? Theme.touch.opacity(0.7) : .clear, radius: 5)
                .overlay(alignment: .trailing) {
                    if fader.isMotorPending == true {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: m(8)))
                            .foregroundStyle(Theme.touch)
                            .offset(x: m(13))
                            .help(l.text("触摸期间电机指令已暂缓，松开后再对位"))
                    }
                }
        }
    }

    // MARK: - Encoder

    private struct EncoderCell: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        static let height: CGFloat = 92

        let encoder: EncoderPresentation
        let isDimmed: Bool
        let isSelected: Bool
        let onSelect: () -> Void
        let onTurn: (Int) -> Void
        let onPush: ((Bool) -> Void)?
        @Environment(\.panelMetrics) private var m
        @State private var dragSteps = 0
        @State private var isPushing = false

        private static let pointsPerStep: CGFloat = 3

        private var displayedValue: String {
            return encoder.observesInput ? encoder.observedValue.map { String($0) } ?? "—" : encoder.detail ?? "\(encoder.value)"
        }

        /// Split for the type checker: one long modifier chain timed out on CI's Swift 6.3.
        var body: some View {
            framedBody
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityName)
                .accessibilityValue(encoder.cellValue.map { String($0) } ?? l.text("Not reported"))
                .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                    turn(direction)
                }
                .help(l.text("上下拖动转动 %@", CompactControl.encoder(encoder.index).shortName))
        }

        private var accessibilityName: String {
            CompactControl.encoder(encoder.index).localizedName(using: l) + " " + (encoder.label ?? "")
        }

        private func turn(_ direction: AccessibilityAdjustmentDirection) {
            onSelect()
            let step: Int = direction == .increment ? 1 : -1
            onTurn(step)
        }

        private var framedBody: some View {
            let shape = RoundedRectangle(cornerRadius: m(8))
            let fill: Color = isSelected ? Theme.selection.opacity(0.16) : Color.black.opacity(0.16)
            let stroke: Color = isSelected ? Theme.selection : Color.clear
            let tag: Color = encoder.color.map(Theme.tag) ?? Color.clear
            return content
                .frame(maxWidth: .infinity)
                .frame(height: m(Self.height))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(tag).frame(width: m(6), height: m(6)).padding(m(4))
                }
                .opacity(isDimmed ? 0.35 : 1)
                .background(fill, in: shape)
                .overlay { shape.stroke(stroke, lineWidth: 1.5) }
        }

        private var content: some View {
            VStack(spacing: m(2)) {
                knob
                Text(encoder.label ?? "E\(encoder.index)")
                    .font(.system(size: m(9), weight: .semibold))
                    .foregroundStyle(encoder.label == nil ? .secondary : Theme.value)
                    .lineLimit(1)
                Text(displayedValue)
                    .font(.system(size: m(10), design: .monospaced))
                    .lineLimit(1)
                pushCap
            }
        }

        private var knob: some View {
            let lit = RingLEDs.lit(encoder.ring, style: encoder.style, localAppearance: encoder.localRingAppearance)
            return ZStack {
                RingView(lit: encoder.observesInput ? RingLEDs.lit(.off, style: nil) : lit)
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.3), Color(white: 0.1)],
                                         center: .topLeading, startRadius: 1, endRadius: m(26)))
                    .frame(width: m(26), height: m(26))
                    .overlay {
                        if let value = encoder.cellValue {
                            Capsule()
                                .fill(Color.white.opacity(0.85))
                                .frame(width: m(2), height: m(8))
                                .offset(y: -m(8))
                                .rotationEffect(.degrees(-135 + 270 * Double(value) / 127))
                        }
                    }
                    .scaleEffect((encoder.isPushed ?? isPushing) ? 0.92 : 1)
            }
            .frame(width: m(46), height: m(46))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragSteps == 0, gesture.translation == .zero {
                            onSelect()
                        }
                        let steps = Int((-gesture.translation.height / m(Self.pointsPerStep)).rounded())
                        if steps != dragSteps {
                            onTurn(steps - dragSteps)
                            dragSteps = steps
                        }
                    }
                    .onEnded { _ in dragSteps = 0 }
            )
        }

        @ViewBuilder
        private var pushCap: some View {
            let label = Text(l.text("PUSH"))
                .font(.system(size: m(7), weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: m(11))
                .background(Color.white.opacity((encoder.isPushed ?? isPushing) ? 0.3 : 0.07), in: Capsule())
                .padding(.horizontal, m(8))
            if let onPush {
                label
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isPushing else { return }
                                isPushing = true
                                onPush(true)
                            }
                            .onEnded { _ in
                                isPushing = false
                                onPush(false)
                            }
                    )
                    .accessibilityLabel("\(CompactControl.encoderPush(encoder.index).localizedName(using: l))")
                    .accessibilityAddTraits(.isButton)
            } else {
                label.foregroundStyle(.tertiary).help(l.text("编码器按下尚未接入后端"))
            }
        }
    }

    /// Thirteen LEDs on a 270° arc, from host intent or the labeled local simulation.
    private struct RingView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let lit: RingLEDs.Lit
        @Environment(\.panelMetrics) private var m

        var body: some View {
            if lit.isBlinking {
                TimelineView(.periodic(from: .now, by: 0.35)) { context in
                    dots(isOn: Int(context.date.timeIntervalSinceReferenceDate / 0.35).isMultiple(of: 2))
                }
            } else {
                dots(isOn: true)
            }
        }

        private func dots(isOn: Bool) -> some View {
            ZStack {
                ForEach(1 ... RingLEDs.count, id: \.self) { segment in
                    let active = isOn && lit.segments.contains(segment)
                    Circle()
                        .fill(active ? Theme.ring : Theme.ledOff)
                        .frame(width: m(4), height: m(4))
                        .shadow(color: active ? Theme.ring.opacity(0.8) : .clear, radius: 2)
                        .offset(y: -m(20))
                        .rotationEffect(.degrees(-135 + 270 * Double(segment - 1) / Double(RingLEDs.count - 1)))
                }
            }
        }
    }

    // MARK: - Button

    private struct ButtonCell: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        static let height: CGFloat = 30

        let button: ButtonPresentation
        let symbol: String?
        var observesInput = false
        let isSelected: Bool
        let onSelect: () -> Void
        let onPress: () -> Void
        let onRelease: (() -> Void)?
        @Environment(\.panelMetrics) private var m
        @State private var isPressing = false

        var body: some View {
            Group {
                if !observesInput, button.light == .blink {
                    TimelineView(.periodic(from: .now, by: 0.35)) { context in
                        face(isLit: Int(context.date.timeIntervalSinceReferenceDate / 0.35).isMultiple(of: 2))
                    }
                } else {
                    face(isLit: observesInput ? button.isDown == true : button.light == .on)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: m(Self.height))
            .scaleEffect((button.isDown ?? isPressing) ? 0.95 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressing else { return }
                        isPressing = true
                        onSelect()
                        onPress()
                    }
                    .onEnded { _ in
                        isPressing = false
                        onRelease?()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(PanelLayout.buttonName(button.index, using: l)) \(button.label ?? "")")
            .accessibilityValue(lightName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onSelect()
                onPress()
                onRelease?()
            }
            .help(l.text("操作 B%@", String(button.index)))
        }

        private var lightName: String {
            switch button.light {
            case .off: l.text("熄灭")
            case .on: l.text("点亮")
            case .blink: l.text("闪烁")
            }
        }

        private func face(isLit: Bool) -> some View {
            RoundedRectangle(cornerRadius: m(5))
                .fill(LinearGradient(colors: [Color(white: isLit ? 0.3 : 0.24), Color(white: 0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    VStack(spacing: m(2)) {
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: m(10), weight: .bold))
                                .foregroundStyle(isLit ? Theme.led : Color.secondary)
                        } else {
                            Capsule()
                                .fill(isLit ? Theme.led : Theme.ledOff)
                                .frame(width: m(22), height: m(4))
                                .shadow(color: isLit ? Theme.led.opacity(0.9) : .clear, radius: 4)
                        }
                        Text(button.label ?? "B\(button.index)")
                            .font(.system(size: m(8), weight: .medium, design: button.label == nil ? .monospaced : .default))
                            .foregroundStyle(button.label == nil ? Color.secondary.opacity(0.7) : Theme.value)
                            .lineLimit(1)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: m(5))
                        .stroke(isSelected ? Theme.selection : Color.black.opacity(0.5), lineWidth: isSelected ? 1.5 : 1)
                }
        }
    }

    // MARK: - Simulated pedals

    /// Rear-panel accessories in the mock: hold SW, drag EXP. Real pedals are physical input
    /// and get no on-screen control.
    private struct MockPedalControls: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let pedals: MockPedalPresentation
        let intents: PanelIntents
        @Environment(\.panelMetrics) private var m
        @State private var dragged: Double?

        var body: some View {
            HStack(spacing: m(6)) {
                Text("FOOT").font(.system(size: m(8), weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    .fixedSize()
                Text("SW")
                    .font(.system(size: m(9), weight: .heavy))
                    .frame(width: m(30), height: m(18))
                    .foregroundStyle(pedals.footswitchDown ? Color.black : .secondary)
                    .background(pedals.footswitchDown ? Theme.ring : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: m(4)))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged {
                            _ in if !pedals.footswitchDown {
                                intents.pressFootswitch?(true)
                            }
                        }
                        .onEnded { _ in intents.pressFootswitch?(false) })
                    .accessibilityLabel(l.text("脚踏开关"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { intents.pressFootswitch?(true); intents.pressFootswitch?(false) }
                    .help(l.text("Hold to press the simulated footswitch"))
                Text("EXP").font(.system(size: m(8), weight: .bold)).foregroundStyle(.secondary)
                    .fixedSize()
                Slider(value: Binding(get: { dragged ?? Double(pedals.expression ?? 0) },
                                      set: { value in
                                          dragged = value
                                          let raw = UInt8(value.rounded())
                                          if raw != pedals.expression {
                                              intents.moveExpression?(raw)
                                          }
                                      }),
                       in: 0 ... 127,
                       onEditingChanged: {
                           editing in if !editing {
                               dragged = nil
                           }
                       })
                       .frame(width: m(90))
                       .controlSize(.mini)
                       .accessibilityLabel(l.text("表情踏板"))
                Text(pedals.expression.map { String($0) } ?? "—")
                    .font(.system(size: m(9), design: .monospaced))
                    .foregroundStyle(pedals.expression == nil ? .secondary : Theme.value)
                    .frame(width: m(22), alignment: .trailing)
            }
            .padding(.horizontal, m(7))
            .padding(.vertical, m(3))
            .background(Color.black.opacity(0.18), in: Capsule())
            .help(l.text("Simulated pedals: CC 26 / 27 on layer A, CC 63 / 64 on layer B"))
        }
    }
#endif
