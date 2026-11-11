#if os(macOS)
    import Foundation
    import XTouchCompactCore

    /// Bridges today's `ConsoleModel` to the frontend contract in `PanelPresentation.swift`.
    ///
    /// Mock gestures travel through device TX and session RX; inspector edits remain host writes.
    /// Fields the session cannot yet report stay nil. TODO.md tracks the remaining gaps.
    extension ConsoleModel {
        private func parameterLabel(_ control: CompactControl) -> String? {
            guard case let .parameter(id) = session.parameters.assignment(control, layer: layer) else { return nil }
            return session.parameters.definition(id)?.name
        }

        private func parameterDetail(_ control: CompactControl) -> String? {
            guard case let .parameter(id) = session.parameters.assignment(control, layer: layer),
                  let value = session.parameters.values[id], let definition = session.parameters.definition(id) else { return nil }
            return "\(value.formatted()) \(definition.unit)"
        }

        var panelSnapshot: PanelSnapshot {
            PanelSnapshot(
                listenOnly: listenOnly, capturePath: capturePath,
                notifications: notifications, runtimeError: error.map { localizedError($0) } ?? connection.error,
                events: events, connection: connection, inputChoice: inputChoice, outputChoice: outputChoice,
                transmitChannel: transmitChannel, feedbackChannel: feedbackChannel, observedLEDVariant: observedLEDVariant,
                layer: layer,
                isMock: !hardwareMode,
                faders: (1 ... CompactGeometry.faderCount).map { index in
                    FaderPresentation(
                        index: index, target: bank.faders[index - 1],
                        observed: session.state.observedFader(index),
                        isTouched: session.state.isTouched(index),
                        isMotorPending: session.state.isMotorPending(index),
                        label: parameterLabel(.fader(index)), detail: parameterDetail(.fader(index))
                    )
                },
                encoders: (1 ... CompactGeometry.encoderCount).compactMap { index in
                    // The connected session owns desired feedback. Omit an uninitialized
                    // control rather than inventing a command from its parameter value.
                    guard let ring = session.state.desiredRing(index) else { return nil }
                    let value = bank.encoders[index - 1]
                    return EncoderPresentation(
                        index: index, value: value,
                        ring: ring, style: session.state.desiredRingStyle(index),
                        isPushed: session.state.isEncoderPushed(index),
                        label: parameterLabel(.encoder(index)), detail: parameterDetail(.encoder(index))
                    )
                },
                buttons: (1 ... CompactGeometry.buttonCount).compactMap { index in
                    guard let light = session.state.desiredButton(index) else { return nil }
                    return ButtonPresentation(index: index, light: light, isDown: session.state.isButtonDown(index))
                },
                pendingPreset: pendingPreset,
                configuration: session.parameters.configuration,
                mcpPort: mcpPort,
                mcpEnabled: mcpEnabled, mcpWritesAllowed: mcpWritesAllowed,
                oscEnabled: oscEnabled, oscHost: oscHost, oscPort: oscPort,
                oscParameter: oscParameter, oscOutput: oscOutput,
                agents: agents.slots,
                parameterValues: session.parameters.values
            )
        }

        var panelIntents: PanelIntents {
            PanelIntents(
                setListenOnly: { [weak self] in self?.setListenOnly($0) },
                startCapture: { [weak self] in self?.chooseStartCapture() },
                stopCapture: { [weak self] in self?.stopCapture() },
                selectLayer: { [weak self] in self?.setLayer($0) },
                useHardware: { [weak self] in self?.useHardware($0) },
                recallMotors: { [weak self] in self?.recallMotors() },
                retrySave: { [weak self] in self?.retryWorkspaceSave() },
                dismissNotification: { [weak self] in self?.dismissNotification($0) },
                clearMonitor: { [weak self] in self?.clearMonitor() },
                selectPorts: { [weak self] input, output in
                    guard let self else { return }
                    inputChoice = input; outputChoice = output; selectPorts()
                },
                configureDevice: { [weak self] tx, rx, observed in
                    guard let self else { return }
                    transmitChannel = tx; feedbackChannel = rx; observedLEDVariant = observed; configure()
                },
                moveFader: { [weak self] index, value in self?.moveFader(index, value: value) },
                touchFader: hardwareMode ? nil : { [weak self] index, touched in
                    self?.touchFader(index, isTouched: touched)
                },
                turnEncoder: { [weak self] index, delta in self?.turnEncoder(index, delta: delta) },
                pushEncoder: hardwareMode ? nil : { [weak self] index, down in
                    self?.pushEncoder(index, isDown: down)
                },
                pressButton: { [weak self] index in self?.pressButton(index) },
                releaseButton: hardwareMode ? nil : { [weak self] index in self?.releaseButton(index) },
                setFader: { [weak self] index, value in self?.faderChanged(index, value: Double(value)) },
                setEncoder: { [weak self] index, value in self?.encoderChanged(index, value: Double(value)) },
                setMCPEnabled: { [weak self] in self?.setMCPEnabled($0) },
                setMCPWritesAllowed: { [weak self] in self?.mcpWritesAllowed = $0 },
                copyMCPToken: { [weak self] in self?.copyMCPToken() },
                setOSCEnabled: { [weak self] in self?.setOSCEnabled($0) },
                configureOSC: { [weak self] host, port, parameter in
                    self?.setOSCEnabled(false); self?.oscHost = host; self?.oscPort = port; self?.oscParameter = parameter
                },
                agentPrimary: { [weak self] slot in self?.agentPrimary(slot) },
                importConfiguration: { [weak self] in self?.chooseImportConfiguration() },
                exportConfiguration: { [weak self] in self?.chooseExportConfiguration() },
                realignLayer: { [weak self] in self?.realignCurrentLayer() },
                resetParameters: { [weak self] in self?.resetParameterValues() },
                setParameter: { [weak self] id, value in self?.setParameter(id, value: value) },
                applyConfiguration: { [weak self] config in self?.applyConfiguration(config) },
                loadPreset: { [weak self] config in self?.loadPreset(config) },
                confirmLoadPreset: { [weak self] in self?.confirmLoadPreset() },
                cancelLoadPreset: { [weak self] in self?.cancelLoadPreset() },
                addressing: { [weak self] control, layer in
                    guard let map = self?.session.state.map,
                          let input = map.inputAddress(for: control, layer: layer) else { return nil }
                    var feedback = map.feedbackAddress(for: control)?.description
                    if case let .encoder(index) = control,
                       let display = feedback, let style = map.encoderRingStyleAddress(encoder: index)
                    {
                        feedback = "\(display) [RingDisplay]; \(style) [RingStyle]"
                    }
                    return ControlAddressing(input: input.description, feedback: feedback)
                }
            )
        }
    }
#endif
