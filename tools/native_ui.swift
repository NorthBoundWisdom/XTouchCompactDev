import AppKit
import ApplicationServices
import Darwin
import Foundation

func emit(_ value: [String: Any], exit code: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
    Darwin.exit(code)
}

let arguments = CommandLine.arguments
if arguments == [arguments[0], "--preflight"] {
    emit(["status": AXIsProcessTrusted() ? "available" : "missing-permission"], exit: AXIsProcessTrusted() ? 0 : 77)
}
guard arguments.count >= 5, let pid = Int32(arguments[1]), pid > 0,
      UUID(uuidString: arguments[2]) != nil else { emit(["status": "invalid-arguments"], exit: 2) }
var info = proc_bsdinfo()
guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
      info.pbi_ppid == UInt32(getppid()), info.pbi_uid == getuid() else {
    emit(["status": "not-owned-child"], exit: 2)
}
var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
var size = 0
guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { emit(["status": "cannot-check-owner"], exit: 2) }
var bytes = [UInt8](repeating: 0, count: size)
guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size >= 4 else { emit(["status": "cannot-check-owner"], exit: 2) }
let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
var offset = 4
while offset < size, bytes[offset] != 0 { offset += 1 }
while offset < size, bytes[offset] == 0 { offset += 1 }
var argv: [String] = []
for _ in 0 ..< max(0, min(argc, 128)) {
    let begin = offset
    while offset < size, bytes[offset] != 0 { offset += 1 }
    argv.append(String(decoding: bytes[begin ..< offset], as: UTF8.self)); offset += 1
}
guard ["--offscreen", "--integration-test", "--ui-test-server"].allSatisfy(argv.contains),
      let sessionIndex = argv.firstIndex(of: "--ui-session-id"), argv.indices.contains(sessionIndex + 1),
      argv[sessionIndex + 1] == arguments[2] else { emit(["status": "not-owned-isolated-session"], exit: 2) }
guard AXIsProcessTrusted() else { emit(["status": "missing-permission"], exit: 77) }

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func record(_ element: AXUIElement) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, name) in [("id", kAXIdentifierAttribute), ("role", kAXRoleAttribute), ("value", kAXValueAttribute),
                        ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute), ("enabled", kAXEnabledAttribute)] {
        if let value = attribute(element, name), value is String || value is NSNumber { result[key] = value }
    }
    var actions: CFArray?
    if AXUIElementCopyActionNames(element, &actions) == .success { result["actions"] = actions as? [String] ?? [] }
    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success { result["valueSettable"] = settable.boolValue }
    return result
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)
let command = arguments[3], identifier = arguments[4]
if command == "frontmost" {
    emit(["status": "ok", "pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
}
var pending = [app], nodes: [[String: Any]] = [], visited = 0
while let element = pending.popLast(), visited < 10000 {
    visited += 1
    var owner: pid_t = 0
    guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { continue }
    let values = record(element)
    if command == "dump", values["id"] != nil { nodes.append(values) }
    if values["id"] as? String == identifier {
        AXUIElementSetMessagingTimeout(element, 10)
        switch command {
        case "inspect": emit(["status": "ok", "element": values])
        case "press", "confirm":
            guard values["enabled"] as? Bool != false else { emit(["status": "disabled", "element": values], exit: 4) }
            if ["AXPopUpButton", "AXMenuBarItem", "AXMenuItem"].contains(values["role"] as? String ?? "") {
                emit(["status": "manual-required", "reason": "native menus are not driven offscreen"], exit: 78)
            }
            let action = command == "press" ? kAXPressAction : kAXConfirmAction
            let error = AXUIElementPerformAction(element, action as CFString)
            guard error == .success else { emit(["status": "unsupported-action", "code": error.rawValue], exit: 78) }
            emit(["status": "ok"])
        case "set":
            guard arguments.count == 6 else { emit(["status": "invalid-arguments"], exit: 2) }
            var settable = DarwinBoolean(false)
            let canSet = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            if !canSet, values["role"] as? String == "AXSlider", let target = Double(arguments[5]), target.isFinite {
                let actions = values["actions"] as? [String] ?? []
                guard actions.contains(kAXIncrementAction), actions.contains(kAXDecrementAction) else {
                    emit(["status": "manual-required", "reason": "No AX slider value or adjustment action"], exit: 78)
                }
                for _ in 0 ..< 512 {
                    guard let current = attribute(element, kAXValueAttribute) as? NSNumber else { break }
                    if abs(current.doubleValue - target) < 0.000001 { emit(["status": "ok", "via": "AX adjustment actions"]) }
                    let action = current.doubleValue < target ? kAXIncrementAction : kAXDecrementAction
                    guard AXUIElementPerformAction(element, action as CFString) == .success else { break }
                }
                emit(["status": "adjustment-did-not-converge"], exit: 4)
            }
            guard canSet else { emit(["status": "manual-required", "reason": "AXValue is not settable"], exit: 78) }
            let value: CFTypeRef
            if ["AXSlider", "AXStepper"].contains(values["role"] as? String ?? "") {
                guard let number = Double(arguments[5]), number.isFinite else { emit(["status": "invalid-value"], exit: 2) }
                value = NSNumber(value: number)
            } else { value = arguments[5] as CFString }
            let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value)
            guard error == .success else { emit(["status": "unsupported-action", "code": error.rawValue], exit: 78) }
            emit(["status": "ok"])
        default: break
        }
    }
    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
}
if command == "dump" { emit(["status": "ok", "elements": nodes]) }
emit(["status": "identifier-absent", "id": identifier], exit: 3)
