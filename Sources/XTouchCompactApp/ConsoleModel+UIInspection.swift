#if os(macOS) && DEBUG
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    extension ConsoleModel {
        /// Read-only facts for an owned isolated instance. No credentials or write callbacks.
        var integrationSummary: [String: String] {
            ["fader.target": String(bank.faders[0]), "fader.position": String(mock.faders[0]),
             "fader2.target": String(bank.faders[1]), "fader2.position": String(mock.faders[1]),
             "fader2.pending": String(session.state.isMotorPending(2)),
             "highlight.group": highlightedGroup ?? "none",
             "fader.touch": String(session.state.isTouched(1)), "fader.pending": String(session.state.isMotorPending(1)),
             "layer.mismatch": String(session.state.layerMismatch), "layer.host": layer.rawValue,
             "motor.sent": String(integrationMotorMessages.count),
             "mcp.enabled": String(mcpEnabled), "mcp.running": String(mcp.isRunning),
             "mcp.copyCount": String(mcpTokenCopyCount), "mcp.motors": String(mcpMotorWritesAllowed),
             "mcp.writes": String(mcpWritesAllowed), "mcp.simulation": String(mcpSimulationControlAllowed),
             "osc.enabled": String(oscEnabled),
             "mcp.tasks": String(mcpAgentControlAllowed), "mcp.auditCount": String(mcpAudit.count),
             "library.count": String(libraryEntries.count), "library.pending": pendingLibraryAction?.name ?? "none",
             "scenes.count": String(session.parameters.configuration.scenes?.count ?? 0),
             "macros.count": String(session.parameters.configuration.macros?.count ?? 0),
             "macro.results": session.lastMacroExecution?.steps.map(\.outcome.rawValue).joined(separator: ",") ?? "none",
             "arm.visible": String(workspacePanels.armVisible),
             "arm.pose": String(ArmPreviewSnapshot(configuration: session.parameters.configuration, values: session.parameters.values) != nil),
             "offline.device": offlineCaptureState.loaded?.inspection.deviceModel ?? "none",
             "offline.count": String(offlineCaptureState.loaded?.inspection.events.count ?? 0),
             "offline.audit": offlineCaptureState.loaded?.audit.assessment.rawValue ?? "none",
             "offline.cursor": String(offlineCaptureState.replay?.cursor ?? 0),
             "offline.target": String(offlineCaptureState.replay?.session.bank(.a).faders[0] ?? 0),
             "offline.position": String(offlineCaptureState.replay?.mock.faders[0] ?? 0),
             "offline.playing": String(offlineCaptureState.isPlaying),
             "snapshot.count": String(integrationCaptureCount),
             "error": errorText(using: Localizer(language: .english))]
        }

        var integrationMotorMessages: [[String: Any]] {
            integrationMotorLedger
        }

        func readIntegrationState() -> [String: Any] {
            ["summary": integrationSummary, "values": session.parameters.values,
             "audit": mcpAudit.map { ["id": $0.id.uuidString, "method": $0.method, "succeeded": $0.succeeded] as [String: Any] },
             "motors": integrationMotorMessages, "mockFaders": mock.faders,
             "library": libraryEntries.map { ["id": $0.id.uuidString, "name": $0.name] },
             "scenes": (session.parameters.configuration.scenes ?? []).map { ["id": $0.id, "name": $0.name] },
             "macros": (session.parameters.configuration.macros ?? []).map { ["id": $0.id, "name": $0.name] },
             "configuration": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(session.parameters.configuration))) ?? [:]]
        }
    }
#endif
