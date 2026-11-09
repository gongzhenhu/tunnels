// 开发用：读取 Tunnels 菜单的辅助功能树（VoiceOver 实际读到的标签）。
// 用法：ax [open] [press <标签前缀>]
//   open：先打开菜单，读完再关掉；press：先按下标签以该前缀开头的按钮（如展开某条隧道）
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}

func label(_ e: AXUIElement) -> String {
    if let s = attr(e, kAXDescriptionAttribute) as? String, !s.isEmpty { return s }
    if let a = attr(e, "AXAttributedDescription") as? NSAttributedString, !a.string.isEmpty { return a.string }
    if let s = attr(e, kAXTitleAttribute) as? String, !s.isEmpty { return s }
    return ""
}

func dump(_ e: AXUIElement, depth: Int = 0) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let interesting: Set = ["AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXTextField", "AXStaticText"]
    if interesting.contains(role) {
        var line = "\(role.dropFirst(2))  「\(label(e))」"
        if role == "AXStaticText" || role == "AXTextField", let v = attr(e, kAXValueAttribute) as? String {
            line += " = \(v.prefix(40))"
        }
        if let hint = attr(e, kAXHelpAttribute) as? String, !hint.isEmpty { line += "  提示：\(hint)" }
        print(line)
    }
    for child in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { dump(child, depth: depth + 1) }
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tunnels.menubar").first else {
    print("Tunnels 没在运行"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
let extra = (attr(root, "AXExtrasMenuBar") as! AXUIElement?).flatMap { (attr($0, kAXChildrenAttribute) as? [AXUIElement])?.first }
let shouldOpen = CommandLine.arguments.contains("open")
if shouldOpen, let extra { AXUIElementPerformAction(extra, kAXPressAction as CFString); usleep(1_200_000) }

func find(_ e: AXUIElement, prefix: String) -> AXUIElement? {
    if attr(e, kAXRoleAttribute) as? String == "AXButton", label(e).hasPrefix(prefix) { return e }
    for child in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let hit = find(child, prefix: prefix) { return hit }
    }
    return nil
}

if let i = CommandLine.arguments.firstIndex(of: "press"), i + 1 < CommandLine.arguments.count {
    let prefix = CommandLine.arguments[i + 1]
    let target = (attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).lazy.compactMap { find($0, prefix: prefix) }.first
    if let target {
        AXUIElementPerformAction(target, kAXPressAction as CFString)
        usleep(800_000)
        print("（已按下「\(label(target))」）")
    } else {
        print("（找不到「\(prefix)」开头的按钮）")
    }
}

let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
if windows.isEmpty { print("（菜单未打开）") }
windows.forEach { dump($0) }

// keep：保持菜单打开（之后用真实点击关闭，测试关闭行为）
if shouldOpen, !CommandLine.arguments.contains("keep"), let extra { AXUIElementPerformAction(extra, kAXPressAction as CFString) }
