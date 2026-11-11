#if os(macOS)
import SwiftUI
import XTouchCompactCore

struct CompactConsoleView: View {
    @ObservedObject var model: ConsoleModel
    @State private var confirmMotorRecall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("X-TOUCH COMPACT").font(.title2.bold())
                    Text("Agent Console · Standard MIDI prototype").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Source", selection: Binding(get: { model.hardwareMode },
                                                    set: { model.useHardware($0) })) {
                    Text("Mock").tag(false)
                    Text("Hardware").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 230)
                Picker("Layer", selection: Binding(get: { model.layer },
                                                   set: { model.setLayer($0) })) {
                    Text("A").tag(CompactLayer.a)
                    Text("B").tag(CompactLayer.b)
                }.pickerStyle(.segmented).frame(width: 130)
                Button("Recall motors…") { confirmMotorRecall = true }
                    .disabled(!model.hardwareMode || !model.connection.isConnected)
            }
            .confirmationDialog("Move all nine physical faders?", isPresented: $confirmMotorRecall) {
                Button("Move nine motor faders") { model.recallMotors() }
            } message: {
                Text("Explicit motor recall is required after connecting or switching layers. Make sure the faders are unobstructed.")
            }

            HStack(spacing: 12) {
                Label(model.connection.isConnected ? "MIDI connected" : "MIDI disconnected", systemImage:
                    model.connection.isConnected ? "checkmark.circle.fill" : "cable.connector")
                    .foregroundStyle(model.connection.isConnected ? .green : .orange)
                Spacer()
                Text("RX feedback uses the separately configured Global channel")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("MIDI setup · factory Standard mode only") {
                HStack {
                    Picker("Input", selection: $model.inputChoice) {
                        Text("Auto X-TOUCH COMPACT").tag(Int32(0))
                        ForEach(model.connection.inputs) { endpoint in
                            Text(endpoint.name).tag(endpoint.id)
                        }
                    }
                    Picker("Output", selection: $model.outputChoice) {
                        Text("Auto X-TOUCH COMPACT").tag(Int32(0))
                        ForEach(model.connection.outputs) { endpoint in
                            Text(endpoint.name).tag(endpoint.id)
                        }
                    }
                    Button("Connect ports") { model.selectPorts() }
                }
                HStack {
                    Stepper("Transmit channel: \(model.transmitChannel)", value: $model.transmitChannel,
                            in: 1...16)
                    Stepper("Global RX channel: \(model.feedbackChannel)", value: $model.feedbackChannel,
                            in: 1...16)
                    Toggle("Observed firmware 1.14 LED values", isOn: $model.observedLEDVariant)
                    Button("Apply profile") { model.configure() }
                }
                .font(.caption)
                Text("Applying a profile resets temporary parameter values. Hardware presets are never modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("9 motor faders").font(.headline)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(1...9, id: \.self) { index in
                            VStack(spacing: 8) {
                                Text(index == 9 ? "MASTER" : "CH \(index)").font(.caption2.bold())
                                Slider(value: Binding(
                                    get: { Double(model.bank.faders[index-1]) },
                                    set: { model.faderChanged(index, value: $0) }
                                ), in: 0...127).frame(height: 140).rotationEffect(.degrees(-90))
                                    .frame(width: 48, height: 160)
                                Text("\(model.bank.faders[index-1])")
                                    .monospacedDigit().font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Divider()
                    Text("16 encoders · 13-segment LED rings").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 8), spacing: 12) {
                        ForEach(1...16, id: \.self) { index in
                            VStack(spacing: 6) {
                                Text("ENC \(index)").font(.caption2)
                                Text("\(model.bank.encoders[index-1])").font(.headline.monospacedDigit())
                                ProgressView(value: Double(model.bank.encoders[index-1]), total: 127)
                                Slider(value: Binding(
                                    get: { Double(model.bank.encoders[index-1]) },
                                    set: { model.encoderChanged(index, value: $0) }
                                ), in: 0...127)
                            }
                        }
                    }
                    Divider()
                    Text("39 illuminated buttons").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 8), spacing: 9) {
                        ForEach(1...39, id: \.self) { index in
                            Button { model.pressButton(index) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(model.bank.buttons[index-1] ? Color.green : Color.gray)
                                        .frame(width: 7, height: 7)
                                    Text("B\(index)").font(.caption.monospacedDigit())
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Divider()
                    Text("MIDI monitor (latest 120)").font(.headline)
                    ForEach(Array(model.logs.prefix(30).enumerated()), id: \.offset) { _, message in
                        Text(message).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
    }
}
#endif
