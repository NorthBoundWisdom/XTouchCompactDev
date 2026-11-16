#if os(macOS)
    import Foundation

    /// Final artifact validation, before AppKit/SwiftUI scene startup. No windows,
    /// UserDefaults, workspace, Keychain, CoreMIDI client or runtime scheduler.
    @MainActor enum NativeStartupSmoke {
        static func run() {
            let model = ConsoleModel(startsMIDI: false, isolated: true)
            guard !model.hardwareMode, !model.mcp.isRunning, !model.mcpEnabled,
                  !model.mcpWritesAllowed, !model.mcpMotorWritesAllowed, !model.oscEnabled
            else {
                FileHandle.standardError.write(Data("Isolated startup safety state is invalid.\n".utf8))
                exit(1)
            }
            FileHandle.standardOutput.write(Data("{\"type\":\"xtouch.native_startup\",\"mode\":\"headless\",\"hardwareAccessed\":false,\"windowCreated\":false,\"firstFramePresented\":false}\n".utf8))
        }
    }
#endif
