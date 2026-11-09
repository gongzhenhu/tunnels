import Foundation

enum TunnelKind: String, Codable {
    /// 本地端口 → 服务器端口（ssh -L）
    case forward
    /// 服务器端口 → 本地端口（ssh -R）
    case reverse
}

struct TunnelSpec: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var kind: TunnelKind
    /// forward: 本机监听端口；reverse: 本机被访问的端口
    var localPort: Int
    /// forward: 服务器目标端口；reverse: 服务器监听端口
    var remotePort: Int
    /// 用户期望的开关状态，App 重启时据此恢复
    var enabled = false

    /// 反向隧道最常见的用途是把本机 Clash 借给服务器
    static let defaultReverseLocalPort = 7890

    var sshArguments: [String] {
        switch kind {
        case .forward: return ["-L", "\(localPort):localhost:\(remotePort)"]
        case .reverse: return ["-R", "\(remotePort):127.0.0.1:\(localPort)"]
        }
    }

    func sameEndpoint(as other: TunnelSpec) -> Bool {
        host == other.host && kind == other.kind
            && localPort == other.localPort && remotePort == other.remotePort
    }

    /// 本机永远在左、服务器永远在右，箭头指向被访问的一方
    var arrow: String { kind == .forward ? "→" : "←" }

    /// 带主机名的完整描述，用于命令行输出
    var summary: String {
        "本机:\(localPort) \(arrow) \(host):\(remotePort)"
    }

    var url: URL? {
        kind == .forward ? URL(string: "http://localhost:\(localPort)") : nil
    }

    var shellCommand: String {
        (["ssh", "-N"] + sshArguments + [host]).joined(separator: " ")
    }
}

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tunnels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var config: URL { support.appendingPathComponent("tunnels.json") }
    static var socket: String { support.appendingPathComponent("control.sock").path }

    static let bundleID = "dev.tunnels.menubar"
}
