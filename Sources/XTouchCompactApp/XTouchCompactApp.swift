#if os(macOS)
import SwiftUI

@main
@MainActor
struct XTouchCompactDevApp: App {
    @StateObject private var model = ConsoleModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1_200, minHeight: 760)
        }
        .defaultSize(width: 1260, height: 920)
    }
}
#else
// Permit protocol-only SwiftPM builds/tests on Linux CI without linking AppKit/CoreMIDI.
import Foundation
@main
struct XTouchCompactDevApp {
    static func main() { print("The XTouchCompactDev GUI requires macOS 14 or later.") }
}
#endif
