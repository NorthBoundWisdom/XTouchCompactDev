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
            let observation = observationPresentation
            return PanelSnapshot(
                hardwareObservation: observation,
                listenOnly: listenOnly, capturePath: capturePath,
                notifications: notifications, runtimeError: error.map { localizedError($0) } ?? connection.error,
                events: events, connection: connection, inputChoice: inputChoice, outputChoice: outputChoice,
                transmitChannel: transmitChannel, feedbackChannel: feedbackChannel, observedLEDVariant: observedLEDVariant,
                layer: layer,
                isMock: !hardwareMode,
                faders: (1 ... CompactGeometry.faderCount).map { index in
                    faderPresentation(index, observation: observation)
                },
                encoders: (1 ... CompactGeometry.encoderCount).compactMap { index in
                    encoderPresentation(index, observation: observation)
                },
                buttons: (1 ... CompactGeometry.buttonCount).compactMap { index in
                    buttonPresentation(index, observation: observation)
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

        private var observationPresentation: HardwareObservationPresentation? {
            guard isObservingHardware else { return nil }
            return HardwareObservationPresentation(
                messageCount: hardwareObserver.messageCount,
                recent: hardwareObserver.recent.map {
                    ObservedHardwareInput(id: $0.id, timestamp: $0.timestamp, message: $0.message,
                                          input: $0.input, channel: Int($0.channel) + 1,
                                          matchesConfiguredChannel: $0.matchesConfiguredChannel)
                },
                faderPositions: hardwareObserver.faderPositions, faderTouches: hardwareObserver.faderTouches,
                encoderValues: hardwareObserver.encoderValues, encoderPushes: hardwareObserver.encoderPushes,
                buttonPresses: hardwareObserver.buttonPresses, seenControls: hardwareObserver.seenControls,
                inputLayer: hardwareObserver.inputLayer
            )
        }

        private func faderPresentation(_ index: Int, observation: HardwareObservationPresentation?) -> FaderPresentation {
            var result = FaderPresentation(
                index: index, target: bank.faders[index - 1], observed: session.state.observedFader(index),
                isTouched: session.state.isTouched(index), isMotorPending: session.state.isMotorPending(index)
            )
            if let observation {
                result.observed = observation.faderPositions[index]
                result.isTouched = observation.faderTouches[index]
                result.label = "F\(index)"
                result.detail = nil
                result.followsObservedPosition = true
            } else {
                result.label = parameterLabel(.fader(index))
                result.detail = parameterDetail(.fader(index))
            }
            return result
        }

        private func encoderPresentation(_ index: Int, observation: HardwareObservationPresentation?) -> EncoderPresentation? {
            // Rings describe host intent; they are never inferred from physical input.
            guard let ring = session.state.desiredRing(index) else { return nil }
            var result = EncoderPresentation(
                index: index, value: bank.encoders[index - 1], ring: ring,
                style: session.state.desiredRingStyle(index), isPushed: session.state.isEncoderPushed(index)
            )
            if let observation {
                result.isPushed = observation.encoderPushes[index]
                result.label = "E\(index)"
                result.detail = nil
                result.observedValue = observation.encoderValue(index)
                result.observesInput = true
            } else {
                result.label = parameterLabel(.encoder(index))
                result.detail = parameterDetail(.encoder(index))
            }
            return result
        }

        private func buttonPresentation(_ index: Int, observation: HardwareObservationPresentation?) -> ButtonPresentation? {
            guard let light = session.state.desiredButton(index) else { return nil }
            let isDown: Bool? = if let observation {
                observation.buttonPresses[index]
            } else {
                session.state.isButtonDown(index)
            }
            return ButtonPresentation(index: index, light: light, isDown: isDown)
        }

        var panelIntents: PanelIntents {
            PanelIntents(
                beginHardwareObservation: { [weak self] in self?.beginHardwareObservation() },
                endHardwareObservation: { [weak self] in self?.endHardwareObservation() },
                resetHardwareObservation: { [weak self] in self?.resetHardwareObservation() },
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
