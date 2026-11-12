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

        private func applyOrganization(_ control: CompactControl, to id: inout String?, _ color: inout ParameterColor?,
                                       _ group: inout String?)
        {
            guard case let .parameter(bound) = session.parameters.assignment(control, layer: layer),
                  let definition = session.parameters.definition(bound) else { return }
            id = bound; color = definition.color; group = definition.group
        }

        private func linkRole(_ id: String) -> LinkRole? {
            for link in session.parameters.configuration.links ?? [] {
                if link.leader == id {
                    return .leader(link.name)
                }
                if link.members.contains(id) {
                    return .member(link.name)
                }
            }
            return nil
        }

        private func parameterDetail(_ control: CompactControl) -> String? {
            guard case let .parameter(id) = session.parameters.assignment(control, layer: layer),
                  let value = session.parameters.values[id], let definition = session.parameters.definition(id) else { return nil }
            return "\(value.formatted()) \(definition.unit)"
        }

        var panelSnapshot: PanelSnapshot {
            let observation = observationPresentation
            return PanelSnapshot(
                surfaceStatus: surfaceStatusPresentation,
                mockPedals: hardwareMode ? nil : MockPedalPresentation(expression: mock.expression, footswitchDown: mock.footswitchDown),
                hardwareDisplayLayer: matchingLiveValues?.lastInputLayer ?? matchingCachedValues?.lastInputLayer,
                hardwareLayerIsCurrent: matchingLiveValues?.lastInputLayer != nil,
                nonMotorTests: nonMotorTestPresentation,
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
                mcpEnabled: mcpEnabled, mcpWritesAllowed: mcpWritesAllowed, mcpSimulationControlAllowed: mcpSimulationControlAllowed,
                mcpMotorWritesAllowed: mcpMotorWritesAllowed,
                oscEnabled: oscEnabled, oscHost: oscHost, oscPort: oscPort,
                oscParameter: oscParameter, oscOutput: oscOutput,
                agents: agents.slots, businessPlugins: plugins.businessPresentations,
                parameterValues: session.parameters.values,
                canUndo: session.canUndo, canRedo: session.canRedo,
                highlightedGroup: highlightedGroup
            )
        }

        private func matchesCurrentInput(_ values: HardwareValueCache?) -> Bool {
            values?.inputID == connection.connectedInput?.id && connection.connectedInput != nil &&
                values?.transmitChannel == session.state.map.transmitChannel
        }

        private var matchingCachedValues: HardwareValueCache? {
            matchesCurrentInput(hardwareValueCache) ? hardwareValueCache : nil
        }

        private var matchingLiveValues: HardwareValueCache? {
            matchesCurrentInput(liveHardwareValues) ? liveHardwareValues : nil
        }

        private func hardwareReading(_ control: CompactControl) -> HardwareValuePresentation? {
            let inputLayer = matchingLiveValues?.lastInputLayer ?? matchingCachedValues?.lastInputLayer ?? layer
            func reading(_ values: HardwareValueCache?) -> HardwareValueCache.Reading? {
                switch control {
                case let .fader(index): values?.faders[index]
                case let .encoder(index): values?.encoders[inputLayer]?[index]
                default: nil
                }
            }
            let current = reading(matchingLiveValues)
            guard let value = current ?? reading(matchingCachedValues) else { return nil }
            return HardwareValuePresentation(value: value.value, timestamp: value.timestamp, isCurrent: current != nil)
        }

        private var surfaceStatusPresentation: SurfaceStatusPresentation {
            guard !hardwareMode else { return SurfaceStatusPresentation() }
            // Simulated device directions: host feedback is MIDI IN; a gesture is MIDI OUT.
            // Simulated pedals: SW lit while held, EXP pulses on movement. The supported mock
            // mode is Standard. These are UI conventions, not measured device LED behavior.
            return SurfaceStatusPresentation(
                usb: .on,
                midiIn: mockMIDIInAt.map { .pulse(until: $0.addingTimeInterval(0.2)) } ?? .off,
                midiOut: mockMIDIOutAt.map { .pulse(until: $0.addingTimeInterval(0.2)) } ?? .off,
                footSwitch: mock.footswitchDown ? .on : .off,
                footExpression: mockExpressionAt.map { .pulse(until: $0.addingTimeInterval(0.2)) } ?? .off,
                mcMode: .off
            )
        }

        private var nonMotorTestPresentation: NonMotorTestPresentation {
            let preview: NonMotorPreviewPresentation? = if let command = nonMotorTests.previewCommand, let message = nonMotorTests.previewMessage,
                                                           let channel = nonMotorTests.previewChannel
            {
                NonMotorPreviewPresentation(command: command, message: message, receiveChannel: Int(channel) + 1)
            } else {
                nil
            }
            let latest = nonMotorTests.attempts.first
            return NonMotorTestPresentation(
                approval: nonMotorTests.approval,
                attempts: nonMotorTests.attempts.map {
                    NonMotorAttemptPresentation(id: $0.id, timestamp: $0.timestamp, command: $0.request.command,
                                                message: $0.request.message, delivery: $0.delivery, reportedResponse: $0.observation, note: $0.note)
                },
                preview: preview, lastLockReason: nonMotorTests.lastLockReason,
                canRequestPermission: isObservingHardware && hardwareMode && connection.isConnected && capturePath != nil,
                canRecordObservation: isObservingHardware && hardwareMode && capturePath != nil && latest?.delivery == .sent &&
                    latest?.request.approval.inputID == connection.connectedInput?.id && latest?.request.approval.outputID == connection.connectedOutput?.id && latest?.request.approval.generation == connection.generation
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
                buttonPresses: hardwareObserver.buttonPresses,
                expressionValue: hardwareObserver.expressionValue, footswitchDown: hardwareObserver.footswitchDown,
                seenControls: hardwareObserver.seenControls,
                inputLayer: hardwareObserver.inputLayer,
                reviewLayers: CompactLayer.allCases.map { layer in
                    LayerInputReviewPresentation(layer: layer, rows: CompactInputGroup.allCases.flatMap { group in
                        group.controls.map { control in
                            InputReviewRowPresentation(control: control, group: group,
                                                       review: hardwareObserver.reviews[layer]?[control] ?? .init())
                        }
                    })
                },
                crossLayerReleases: hardwareObserver.crossLayerReleases.map { transition, count in
                    CrossLayerReleasePresentation(control: transition.control, pressedLayer: transition.pressedLayer,
                                                  releasedLayer: transition.releasedLayer, interveningLayer: transition.interveningLayer, count: count)
                }.sorted { $0.id < $1.id },
                exportedReview: lastReviewExport.map { EvidenceExportPresentation(path: $0.path, sha256: $0.sha256, captureSnapshotPath: $0.captureSnapshotPath) }
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
                applyOrganization(.fader(index), to: &result.parameterID, &result.color, &result.group)
                result.linkRole = result.parameterID.flatMap(linkRole)
                if hardwareMode {
                    result.mirrorsHardware = true
                    result.hardwareReading = hardwareReading(.fader(index))
                    result.observed = matchingLiveValues?.faders[index]?.value
                    result.isTouched = reportedHardwarePresses[.faderTouch(index)]
                }
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
                applyOrganization(.encoder(index), to: &result.parameterID, &result.color, &result.group)
                if hardwareMode {
                    result.mirrorsHardware = true
                    result.hardwareReading = hardwareReading(.encoder(index))
                    result.isPushed = reportedHardwarePresses[.encoderPush(index)]
                }
                // Operator reports: top encoders sometimes light adjacent pairs; side encoders
                // empty the left half before filling the right. Keep protocol style nil unless
                // the host has explicitly selected one; do not rewrite any hardware profile.
                if let value = result.panelValue {
                    result.localRingAppearance = PanelLayout.sideEncoders.contains(index)
                        ? .bipolar(value: value) : .interpolated(value: value)
                }
            }
            return result
        }

        private func buttonPresentation(_ index: Int, observation: HardwareObservationPresentation?) -> ButtonPresentation? {
            guard let light = session.state.desiredButton(index) else { return nil }
            let isDown: Bool? = if let observation {
                observation.buttonPresses[index]
            } else {
                hardwareMode ? reportedHardwarePresses[.button(index)] : session.state.isButtonDown(index)
            }
            return ButtonPresentation(index: index, light: light, isDown: isDown)
        }

        var panelIntents: PanelIntents {
            PanelIntents(
                armNonMotorTests: { [weak self] in self?.armNonMotorTests($0) },
                lockNonMotorTests: { [weak self] in self?.lockNonMotorTests() },
                previewNonMotorTest: { [weak self] in self?.previewNonMotorTest($0, receiveChannel: $1) },
                performNonMotorTest: { [weak self] in self?.performNonMotorTest($0) },
                recordNonMotorObservation: { [weak self] in self?.recordNonMotorObservation($0, result: $1, note: $2) },
                beginHardwareObservation: { [weak self] in self?.beginHardwareObservation() },
                endHardwareObservation: { [weak self] in self?.endHardwareObservation() },
                resetHardwareObservation: { [weak self] in self?.resetHardwareObservation() },
                exportInputReview: { [weak self] in self?.chooseExportInputReview() },
                setListenOnly: { [weak self] in self?.setListenOnly($0) },
                enableHardwareWriteback: { [weak self] in self?.enableHardwareWriteback() },
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
                setMCPSimulationControlAllowed: { [weak self] in self?.mcpSimulationControlAllowed = $0 },
                setMCPMotorWritesAllowed: { [weak self] in self?.mcpMotorWritesAllowed = $0 },
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
                },
                renameControl: { [weak self] control, name in self?.renameControl(control, name: name) },
                setControlColor: { [weak self] control, color in self?.setControlColor(control, color: color) },
                setControlGroup: { [weak self] control, group in self?.setControlGroup(control, group: group) },
                highlightGroup: { [weak self] group in self?.highlightedGroup = group },
                saveLink: { [weak self] link in self?.saveLink(link) },
                deleteLink: { [weak self] id in self?.deleteLink(id) },
                captureScene: { [weak self] name in self?.captureScene(name: name) },
                recallScene: { [weak self] id in self?.recallScene(id) },
                renameScene: { [weak self] id, name in self?.renameScene(id, name: name) },
                deleteScene: { [weak self] id in self?.deleteScene(id) },
                undo: { [weak self] in self?.undo() },
                redo: { [weak self] in self?.redo() },
                setMode: { [weak self] mode in self?.setConsoleMode(mode) },
                moveExpression: hardwareMode ? nil : { [weak self] value in self?.moveExpression(value) },
                pressFootswitch: hardwareMode ? nil : { [weak self] down in self?.pressFootswitch(isDown: down) }
            )
        }
    }
#endif
