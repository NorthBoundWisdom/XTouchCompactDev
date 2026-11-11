#if os(macOS)
import Foundation
import XTouchCompactCore

/// Bridges today's `ConsoleModel` to the frontend contract in `PanelPresentation.swift`.
///
/// Mock gestures travel through device TX and session RX; inspector edits remain host writes.
/// Fields the session cannot yet report stay nil. TODO.md tracks the remaining gaps.
extension ConsoleModel {
    var panelSnapshot: PanelSnapshot {
        PanelSnapshot(
            layer: layer,
            isMock: !hardwareMode,
            faders: (1 ... CompactGeometry.faderCount).map { index in
                FaderPresentation(
                    index: index, target: bank.faders[index - 1],
                    observed: session.state.observedFader(index),
                    isTouched: session.state.isTouched(index),
                    isMotorPending: session.state.isMotorPending(index)
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
                    isPushed: session.state.isEncoderPushed(index)
                )
            },
            buttons: (1 ... CompactGeometry.buttonCount).compactMap { index in
                guard let light = session.state.desiredButton(index) else { return nil }
                return ButtonPresentation(index: index, light: light, isDown: session.state.isButtonDown(index))
            }
        )
    }

    var panelIntents: PanelIntents {
        PanelIntents(
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
            addressing: nil
        )
    }
}
#endif
