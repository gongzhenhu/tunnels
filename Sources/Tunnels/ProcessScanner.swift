import Foundation

struct ExternalForward: Hashable {
    enum Kind { case local, remote, dynamic }
    let kind: Kind
    let listenPort: Int
    let targetPort: Int?

    /// 与 TunnelSpec 同一套表达：本机在左，服务器在右
    var localSide: String { kind == .remote ? "\(targetPort ?? 0)" : "\(listenPort)" }
    var remoteSide: String {
        switch kind {
        case .local: return "\(targetPort ?? 0)"
        case .remote: return "\(listenPort)"
        case .dynamic: return "SOCKS"
        }
    }
    var towardServer: Bool { kind != .remote }

    var label: String {
        kind == .dynamic
            ? "本机:\(localSide) → 服务器 SOCKS"
            : "本机:\(localSide) \(towardServer ? "→" : "←") 服务器:\(remoteSide)"
    }
}

/// 外部隧道是谁起的、谁在维护
enum ProcessOrigin: Hashable {
    /// launchd 服务（KeepAlive 之类），杀了会被拉起
    case launchAgent(String)
    /// 由某个应用维护（如 VS Code Remote-SSH），杀了会被重建
    case app(String)
    case terminal
    /// 父进程已退出，被 launchd 收养
    case detached
    case process(String)

    /// 有守护者：结束或接管都没有意义
    var isSupervised: Bool {
        switch self {
        case .launchAgent, .app: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .launchAgent(let label): return "开机服务 \(label)"
        case .app(let name): return "由 \(name) 维护"
        case .terminal: return "终端启动"
        case .detached: return "后台进程"
        case .process(let name): return "由 \(name) 启动"
        }
    }
}

/// 不是本 App 起的 ssh/autossh 隧道进程
struct ExternalTunnel: Identifiable, Hashable {
    /// 顶层进程；由 autossh 托管时是 autossh 的 pid
    let pid: Int32
    let childPID: Int32?
    let tool: String
    let host: String
    let forwards: [ExternalForward]
    let origin: ProcessOrigin

    var id: Int32 { pid }
    var label: String { forwards.map(\.label).joined(separator: "，") }
    var canTerminate: Bool { !origin.isSupervised }
    var canAdopt: Bool { canTerminate && forwards.contains { $0.kind != .dynamic } }

    /// 用在“端口被…占用”里
    var ownerPhrase: String {
        switch origin {
        case .launchAgent(let label): return "开机服务 \(label) "
        case .app(let name): return " \(name) "
        case .terminal: return "终端里的 \(tool) \(pid) "
        case .detached: return "后台 \(tool) \(pid) "
        case .process(let name): return " \(name) 启动的 \(tool) "
        }
    }
}

enum ProcessScanner {
    struct Result {
        var externals: [ExternalTunnel] = []
        /// 带 Tag=tunnels-app 的进程（本 App 起的）
        var tagged: [Int32] = []
    }

    private struct Proc { let ppid: Int32; let command: String }

    static func scan() -> Result {
        guard let psOutput = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]) else { return Result() }

        struct Entry { let pid, ppid: Int32; let tool, host: String; let forwards: [ExternalForward] }
        var result = Result()
        var entries: [Entry] = []
        var procs: [Int32: Proc] = [:]
        for line in psOutput.split(separator: "\n") {
            let head = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard head.count == 3, let pid = Int32(head[0]), let ppid = Int32(head[1]) else { continue }
            procs[pid] = Proc(ppid: ppid, command: String(head[2]))

            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            let tool = (String(cols[2]) as NSString).lastPathComponent
            guard tool == "ssh" || tool == "autossh" else { continue }
            if line.contains("Tag=\(TunnelRunner.tag)") {
                result.tagged.append(pid)
                continue
            }
            let (host, forwards) = parse(cols.dropFirst(3).map(String.init), tool: tool)
            guard let host, !forwards.isEmpty else { continue }
            entries.append(Entry(pid: pid, ppid: ppid, tool: tool, host: host, forwards: forwards))
        }

        let services = entries.isEmpty ? [:] : launchdServices()
        let autosshPIDs = Set(entries.filter { $0.tool == "autossh" }.map(\.pid))
        for e in entries where !(e.tool == "ssh" && autosshPIDs.contains(e.ppid)) {
            let child = e.tool == "autossh" ? entries.first { $0.ppid == e.pid }?.pid : nil
            result.externals.append(ExternalTunnel(
                pid: e.pid, childPID: child, tool: e.tool, host: e.host, forwards: e.forwards,
                origin: origin(of: e.pid, procs: procs, services: services)))
        }
        return result
    }

    private static func origin(of pid: Int32, procs: [Int32: Proc], services: [Int32: String]) -> ProcessOrigin {
        if let label = services[pid] { return .launchAgent(label) }
        guard let parentPID = procs[pid]?.ppid, parentPID > 1, let parent = procs[parentPID] else {
            return .detached
        }
        if isShell(parent.command) { return .terminal }
        // 往上找第一个 .app 祖先，它就是维护者
        var current: Int32 = parentPID
        for _ in 0..<20 {
            guard let proc = procs[current] else { break }
            if let app = appName(proc.command) { return .app(app) }
            guard proc.ppid > 1 else { break }
            current = proc.ppid
        }
        return .process(executableName(parent.command))
    }

    private static func isShell(_ command: String) -> Bool {
        var name = executableName(command)
        if name.hasPrefix("-") { name.removeFirst() }
        return ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh"].contains(name)
    }

    private static func executableName(_ command: String) -> String {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    private static let appAliases = ["Visual Studio Code": "VS Code"]

    private static func appName(_ command: String) -> String? {
        guard let r = command.range(of: ".app/") else { return nil }
        let name = (String(command[..<r.lowerBound]) as NSString).lastPathComponent
        return appAliases[name] ?? name
    }

    /// 当前用户 launchd 中正在运行的服务：pid → label
    private static func launchdServices() -> [Int32: String] {
        guard let output = run("/bin/launchctl", ["list"]) else { return [:] }
        var services: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count == 3, let pid = Int32(cols[0]) else { continue }
            services[pid] = String(cols[2])
        }
        return services
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func terminate(_ tunnel: ExternalTunnel) {
        // 先杀 autossh，否则它会把 ssh 重新拉起来
        kill(tunnel.pid, SIGTERM)
        if let child = tunnel.childPID { kill(child, SIGTERM) }
    }

    private static let optionsWithValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    private static func parse(_ args: [String], tool: String) -> (String?, [ExternalForward]) {
        var forwards: [ExternalForward] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("-"), arg.count > 1 else { return (arg, forwards) }
            let chars = Array(arg.dropFirst())
            for (j, c) in chars.enumerated()
            where optionsWithValue.contains(c) || (tool == "autossh" && c == "M") {
                var value = String(chars[(j + 1)...])
                if value.isEmpty {
                    i += 1
                    value = i < args.count ? args[i] : ""
                }
                if let f = forward(c, value) { forwards.append(f) }
                break
            }
            i += 1
        }
        return (nil, forwards)
    }

    private static func forward(_ option: Character, _ value: String) -> ExternalForward? {
        let parts = value.split(separator: ":").map(String.init)
        switch option {
        case "L", "R":
            guard parts.count == 3 || parts.count == 4,
                  let listen = Int(parts[parts.count - 3]),
                  let target = Int(parts[parts.count - 1]) else { return nil }
            return ExternalForward(kind: option == "L" ? .local : .remote, listenPort: listen, targetPort: target)
        case "D":
            guard let port = parts.last.flatMap({ Int($0) }) else { return nil }
            return ExternalForward(kind: .dynamic, listenPort: port, targetPort: nil)
        default:
            return nil
        }
    }
}
