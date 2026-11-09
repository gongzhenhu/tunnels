// 开发用：每 0.2 秒打印一次 Tunnels 在屏幕上的窗口位置和尺寸，共 N 次。
// 用法：windows [次数]
import CoreGraphics
import Foundation

let rounds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20 : 20
for _ in 0..<rounds {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Tunnels" }
        .compactMap { info -> String? in
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Height"] ?? 0) > 40 else { return nil }  // 排除菜单栏图标
            return "\(Int(b["X"]!)),\(Int(b["Y"]!)) \(Int(b["Width"]!))x\(Int(b["Height"]!))"
        }
    print(mine.isEmpty ? "（菜单未显示）" : mine.joined(separator: " | "))
    usleep(200_000)
}
