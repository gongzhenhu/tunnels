import Foundation

/// `tunnel` 命令行：把请求转给菜单栏 App，App 没开就先拉起来。
enum CLI {
    static let commands: Set<String> = ["forward", "reverse", "off", "rm", "hide", "unhide", "ls", "list", "help", "-h", "--help", "_snapshot"]

    static let usage = """
    用法:
      tunnel forward <主机> <本地端口> [服务器端口]   本地端口 → 服务器端口，服务器端口默认同本地
      tunnel reverse <主机> <服务器端口> [本地端口]   服务器端口 → 本地端口，本地端口默认 7890
      tunnel off [forward|reverse] [主机] [端口]      关闭匹配的隧道，不带参数则全部关闭
      tunnel rm [forward|reverse] [主机] [端口]       从列表中删除匹配的隧道
      tunnel ls                                      列出所有隧道
      tunnel hide <主机> / unhide <主机>             在新建隧道的主机列表里隐藏 / 恢复（跳板机自动隐藏）
    """

    static func run(_ args: [String]) -> Int32 {
        switch args[0] {
        case "forward", "reverse":
            guard args.count == 3 || args.count == 4,
                  let first = port(args[2]),
                  args.count == 3 || port(args[3]) != nil else {
                fputs(usage + "\n", stderr)
                return 2
            }
            let kind: TunnelKind = args[0] == "forward" ? .forward : .reverse
            let second = args.count == 4 ? port(args[3])!
                : kind == .forward ? first : TunnelSpec.defaultReverseLocalPort
            let req = ControlRequest(cmd: "up", host: args[1], kind: kind,
                                     local: kind == .forward ? first : second,
                                     remote: kind == .forward ? second : first)
            print("🚇 连接中…")
            return send(req)
        case "off", "rm":
            var req = ControlRequest(cmd: args[0] == "off" ? "down" : "remove")
            for arg in args.dropFirst() {
                if let kind = TunnelKind(rawValue: arg) { req.kind = kind }
                else if let p = port(arg) { req.local = p }
                else { req.host = arg }
            }
            return send(req)
        case "ls", "list":
            return send(ControlRequest(cmd: "list"))
        case "hide", "unhide":
            guard args.count == 2 else {
                fputs(usage + "\n", stderr)
                return 2
            }
            return send(ControlRequest(cmd: args[0], host: args[1]))
        case "_snapshot":
            // 开发用：把菜单界面渲染成 PNG。tunnel _snapshot <路径> [dark] [add] [expand]
            return send(ControlRequest(cmd: "snapshot", args: Array(args.dropFirst())))
        default:
            print(usage)
            return 0
        }
    }

    private static func port(_ s: String) -> Int? {
        guard let p = Int(s), (1...65535).contains(p) else { return nil }
        return p
    }

    private static func send(_ req: ControlRequest) -> Int32 {
        guard ensureAppRunning() else {
            fputs("❌ 无法启动 Tunnels.app（是否已安装到 ~/Applications？）\n", stderr)
            return 1
        }
        guard let resp = ControlClient.send(req) else {
            fputs("❌ App 没有响应\n", stderr)
            return 1
        }
        if resp.ok { print(resp.message) } else { fputs(resp.message + "\n", stderr) }
        return resp.ok ? 0 : 1
    }

    private static func ensureAppRunning() -> Bool {
        if ControlClient.send(ControlRequest(cmd: "ping"), timeout: 2) != nil { return true }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", AppPaths.bundleID]
        guard (try? open.run()) != nil else { return false }
        open.waitUntilExit()
        for _ in 0..<40 {
            usleep(200_000)
            if ControlClient.send(ControlRequest(cmd: "ping"), timeout: 2) != nil { return true }
        }
        return false
    }
}
