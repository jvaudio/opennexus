// An accessibility audit of a running OpenNexus, as a real assistive client (so SwiftUI
// builds its whole tree). It runs the Accessibility Inspector checks that matter for
// the chrome: element with no description, unknown role, action missing.
//
//   swiftc -O App/tools/axaudit.swift -o /tmp/axaudit
//   /tmp/axaudit <pid> [window-title-substring]
//   PRESS=settings.pane.ai /tmp/axaudit <pid> Settings   # press an element by identifier first
//   TREE=1 /tmp/axaudit <pid> Home                      # also print the tree
//
// The terminal running it needs Accessibility access (System Settings › Privacy & Security).
// Exits 1 when any issue is found.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: axaudit <pid> [window-title-substring]")
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("axaudit: this process isn't trusted for accessibility")
    exit(2)
}
let windowFilter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let env = ProcessInfo.processInfo.environment
let app = AXUIElementCreateApplication(pid)

func attr<T>(_ e: AXUIElement, _ a: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v as? T
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") ?? [] }
func actions(_ e: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyActionNames(e, &v) == .success else { return [] }
    return (v as? [String]) ?? []
}
/// What VoiceOver would say the element is: description, title, or its title element.
func label(_ e: AXUIElement) -> String {
    let parts: [String?] = [attr(e, "AXDescription"), attr(e, "AXTitle"), attr(e, "AXPlaceholderValue")]
    var s = parts.compactMap { $0 }.joined()
    if s.isEmpty, let t: AXUIElement = attr(e, "AXTitleUIElement") { s = attr(t, "AXValue") ?? "" }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
func value(_ e: AXUIElement) -> String {
    guard let v: Any = attr(e, "AXValue") else { return "" }
    return "\(v)"
}

/// Roles that must say what they are.
let needsLabel: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField",
    "AXComboBox", "AXLink", "AXIncrementor", "AXDisclosureTriangle", "AXColorWell", "AXImage", "AXTextArea",
    "AXTabGroup", "AXScrollArea", "AXOutline", "AXTable", "AXList",
]
/// Roles whose current value can stand in for a label (a checkbox's state is not one).
let valueNames: Set<String> = ["AXPopUpButton", "AXMenuButton", "AXComboBox"]
let needsAction: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink"]
/// AppKit's own window and scroller parts, labelled by their role description.
let systemParts: Set<String> = [
    "AXCloseButton", "AXFullScreenButton", "AXMinimizeButton", "AXZoomButton", "AXIncrementArrow",
    "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
]

var issues: [String] = []
var count = 0

func walk(_ e: AXUIElement, _ path: String, _ depth: Int) {
    guard depth < 80 else { return }
    count += 1
    let role: String = attr(e, "AXRole") ?? "?"
    let sub: String = attr(e, "AXSubrole") ?? ""
    let name = label(e)
    let here = path + "/" + (name.isEmpty ? role : "\(role)[\(name.prefix(30))]")
    if env["TREE"] != nil {
        print(
            String(repeating: " ", count: depth) + role + (sub.isEmpty ? "" : "/" + sub) + " «\(name.prefix(40))» "
                + value(e).prefix(30) + " " + actions(e).joined(separator: ","))
    }
    // Toolbar item wrappers carry AppKit's customisation actions; their items are checked.
    let system = systemParts.contains(sub) || path.hasSuffix("/AXToolbar")
    if !system {
        if role == "AXUnknown" { issues.append("unknown role · \(here)") }
        if needsLabel.contains(role) && name.isEmpty && !(valueNames.contains(role) && !value(e).isEmpty) {
            issues.append("no description (\(role)\(sub.isEmpty ? "" : "/" + sub)) · \(here)")
        }
        if needsAction.contains(role) && actions(e).isEmpty { issues.append("action missing (\(role)) · \(here)") }
    }
    for c in children(e) { walk(c, here, depth + 1) }
}

func find(_ e: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
    if depth > 60 { return nil }
    if (attr(e, "AXIdentifier") as String?) == identifier { return e }
    for c in children(e) { if let f = find(c, identifier: identifier, depth: depth + 1) { return f } }
    return nil
}

// Asking for the windows wakes SwiftUI's tree; give it a moment to build.
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
let windows: [AXUIElement] = attr(app, "AXWindows") ?? []
usleep(800_000)
if let id = env["PRESS"] {
    for w in windows {
        if let b = find(w, identifier: id) {
            AXUIElementPerformAction(b, "AXPress" as CFString)
            usleep(900_000)
            break
        }
    }
}
var total = 0
for w in (attr(app, "AXWindows") as [AXUIElement]?) ?? [] {
    let title: String = attr(w, "AXTitle") ?? ""
    if let f = windowFilter, !title.contains(f) { continue }
    issues.removeAll()
    count = 0
    walk(w, "", 0)
    print("== \(title): \(count) elements, \(issues.count) issues")
    for i in issues { print("  " + i) }
    total += issues.count
}
exit(total == 0 ? 0 : 1)
