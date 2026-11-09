// 开发用：在屏幕坐标 (x, y)（左上角原点）发送一次真实的鼠标左键点击。
// 用法：click <x> <y>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write("用法: click <x> <y>\n".data(using: .utf8)!)
    exit(2)
}
let point = CGPoint(x: x, y: y)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(50_000)
}
