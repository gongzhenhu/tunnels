import AppKit
import Network
import Observation

@MainActor @Observable
final class TunnelStore {
    enum Overall { case idle, active, attention }

    private(set) var specs: [TunnelSpec] = []
    private(set) var runners: [UUID: TunnelRunner] = [:]
    private(set) var externals: [ExternalTunnel] = []
    /// ssh config 里的主机（已去掉跳板机）
    private var configHosts: [String] = []
    /// 用户手动隐藏的主机（如 Git 仓库地址）
    private(set) var hiddenHosts: [String] = []
    /// 新建隧道时可选的主机
    var hosts: [String] { configHosts.filter { !hiddenHosts.contains($0) } }
    var lastHost = "" {
        didSet { save() }
    }

    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init() {
        configHosts = SSHConfig.hosts()
        load()
    }

    // MARK: 生命周期

    func bootstrap() {
        for spec in specs { runners[spec.id] = TunnelRunner(spec: spec) }

        // 上次异常退出留下的 ssh 先清掉，否则端口会被占
        let scan = ProcessScanner.scan()
        scan.tagged.forEach { kill($0, SIGTERM) }
        externals = scan.externals
        if !scan.tagged.isEmpty { usleep(300_000) }

        for spec in specs where spec.enabled { runners[spec.id]?.start() }

        scanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExternals() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.runners.values.forEach { $0.retryNowIfWaiting() } }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runners.values.forEach { $0.restart() } }
        }
    }

    /// 退出 App：停掉进程但保留开关状态，下次启动时恢复
    func shutdown() {
        runners.values.forEach { $0.stop() }
    }

    private func refreshExternals() {
        Task {
            let scan = await Task.detached { ProcessScanner.scan() }.value
            let mine = Set(runners.values.compactMap(\.pid))
            for pid in scan.tagged where !mine.contains(pid) { kill(pid, SIGTERM) }
            if scan.externals != externals { externals = scan.externals }
        }
    }

    // MARK: 查询

    var overall: Overall {
        var active = false
        for spec in specs where spec.enabled {
            guard let runner = runners[spec.id] else { continue }
            if runner.needsAttention { return .attention }
            active = true
        }
        return active ? .active : .idle
    }

    /// 有隧道的主机，按 ssh config 中的顺序
    var menuHosts: [String] {
        let used = Set(specs.map(\.host))
        return configHosts.filter(used.contains) + used.subtracting(configHosts).sorted()
    }

    /// 重新读取 ssh config，打开新建表单时调用，改了配置不用重启 App
    func reloadHosts() {
        let fresh = SSHConfig.hosts()
        if fresh != configHosts { configHosts = fresh }
    }

    func setHidden(_ host: String, _ hidden: Bool) {
        hiddenHosts.removeAll { $0 == host }
        if hidden { hiddenHosts.append(host) }
        save()
    }

    /// 占着这条隧道端口的外部进程（只在端口冲突重试时有意义）
    func conflict(for spec: TunnelSpec) -> ExternalTunnel? {
        externals.first { ext in
            ext.forwards.contains { f in
                switch (spec.kind, f.kind) {
                case (.forward, .local), (.forward, .dynamic): return f.listenPort == spec.localPort
                case (.reverse, .remote): return ext.host == spec.host && f.listenPort == spec.remotePort
                default: return false
                }
            }
        }
    }

    func specs(for host: String) -> [TunnelSpec] {
        specs.filter { $0.host == host }.sorted {
            $0.kind != $1.kind ? $0.kind == .reverse : $0.localPort < $1.localPort
        }
    }

    // MARK: 修改

    @discardableResult
    func upsert(_ spec: TunnelSpec) -> TunnelSpec {
        if let existing = specs.first(where: { $0.sameEndpoint(as: spec) }) { return existing }
        specs.append(spec)
        runners[spec.id] = TunnelRunner(spec: spec)
        save()
        return spec
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = specs.firstIndex(where: { $0.id == id }) else { return }
        specs[i].enabled = on
        save()
        if on { runners[id]?.start() } else { runners[id]?.stop() }
    }

    /// 修改端口：保留 id 和开关状态，开着的隧道会用新端口重连。返回错误信息
    func update(_ id: UUID, local: Int, remote: Int) -> String? {
        guard let i = specs.firstIndex(where: { $0.id == id }) else { return "隧道不存在" }
        var spec = specs[i]
        spec.localPort = local
        spec.remotePort = remote
        if specs.contains(where: { $0.id != id && $0.sameEndpoint(as: spec) }) { return "已有相同的隧道" }
        guard !spec.sameEndpoint(as: specs[i]) else { return nil }
        runners[id]?.stop()
        specs[i] = spec
        runners[id] = TunnelRunner(spec: spec)
        save()
        if spec.enabled { runners[id]?.start() }
        return nil
    }

    func delete(_ id: UUID) {
        runners[id]?.stop()
        runners[id] = nil
        specs.removeAll { $0.id == id }
        save()
    }

    func terminate(_ external: ExternalTunnel) {
        guard external.canTerminate else { return }
        ProcessScanner.terminate(external)
        externals.removeAll { $0.pid == external.pid }
    }

    /// 结束占着端口的外部进程，然后立即重连
    func resolveConflict(_ spec: TunnelSpec, _ external: ExternalTunnel) {
        terminate(external)
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            runners[spec.id]?.retryNowIfWaiting()
        }
    }

    /// 关掉外部进程，改由 App 托管同样的端口映射
    func adopt(_ external: ExternalTunnel) {
        guard external.canAdopt else { return }
        let adopted = external.forwards.compactMap { f -> TunnelSpec? in
            guard let target = f.targetPort else { return nil }
            switch f.kind {
            case .local: return TunnelSpec(host: external.host, kind: .forward, localPort: f.listenPort, remotePort: target)
            case .remote: return TunnelSpec(host: external.host, kind: .reverse, localPort: target, remotePort: f.listenPort)
            case .dynamic: return nil
            }
        }
        terminate(external)
        Task {
            // 等旧进程释放端口
            try? await Task.sleep(for: .milliseconds(600))
            for spec in adopted { setEnabled(upsert(spec).id, true) }
        }
    }

    // MARK: 持久化

    private struct Saved: Codable {
        var specs: [TunnelSpec]
        var lastHost: String
        var hiddenHosts: [String]?
    }

    private func load() {
        if let data = try? Data(contentsOf: AppPaths.config),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            specs = saved.specs
            hiddenHosts = saved.hiddenHosts ?? []
            lastHost = saved.lastHost
            return
        }
        lastHost = hosts.first ?? ""
        // 首次启动：预置原来 tun70 的默认映射（Clash 代理），默认关闭
        if hosts.contains("banma-70") {
            lastHost = "banma-70"
            specs = [TunnelSpec(host: "banma-70", kind: .reverse, localPort: 7890, remotePort: 14725)]
        }
    }

    private func save() {
        let saved = Saved(specs: specs, lastHost: lastHost, hiddenHosts: hiddenHosts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(saved).write(to: AppPaths.config, options: .atomic)
    }
}

// MARK: 命令行请求

extension TunnelStore {
    func handle(_ req: ControlRequest) async -> ControlResponse {
        switch req.cmd {
        case "ping":
            return ControlResponse(ok: true, message: "pong")
        case "list":
            return ControlResponse(ok: true, message: listing())
        case "up":
            guard let host = req.host, let kind = req.kind, let local = req.local, let remote = req.remote else {
                return ControlResponse(ok: false, message: "参数不完整")
            }
            return await up(TunnelSpec(host: host, kind: kind, localPort: local, remotePort: remote))
        case "down":
            return down(req)
        case "hide", "unhide":
            guard let host = req.host else { return ControlResponse(ok: false, message: "缺少主机名") }
            setHidden(host, req.cmd == "hide")
            let verb = req.cmd == "hide" ? "已隐藏" : "已恢复"
            return ControlResponse(ok: true, message: "✅ \(verb)：\(host)\n可选主机：\(hosts.joined(separator: "、"))")
        case "remove":
            let matched = matching(req, enabledOnly: false)
            guard !matched.isEmpty else { return ControlResponse(ok: false, message: "⚠️ 没有匹配的隧道") }
            matched.forEach { delete($0.id) }
            return ControlResponse(ok: true, message: matched.map { "🗑 已删除：\($0.summary)" }.joined(separator: "\n"))
        default:
            return ControlResponse(ok: false, message: "未知命令：\(req.cmd)")
        }
    }

    private func up(_ draft: TunnelSpec) async -> ControlResponse {
        let spec = upsert(draft)
        setEnabled(spec.id, true)
        guard let runner = runners[spec.id] else { return ControlResponse(ok: false, message: "内部错误") }

        let deadline = Date().addingTimeInterval(20)
        while runner.phase == .connecting && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        switch runner.phase {
        case .connected:
            var lines = ["✅ 已连接：\(spec.summary)"]
            if let url = spec.url { lines.append("🔗 \(url.absoluteString)") }
            if spec.kind == .reverse, !(await PortProbe.isListening(spec.localPort)) {
                lines.append("⚠️ 本机:\(spec.localPort) 未在监听，隧道已建立但暂时不可用")
            }
            return ControlResponse(ok: true, message: lines.joined(separator: "\n"))
        case .retrying(let reason, _):
            var lines = ["⚠️ \(reason)，App 会持续重试（tunnel off 可停止）"]
            if let ext = conflict(for: spec) {
                lines.append(ext.canTerminate
                    ? "   占用者：\(ext.origin.label)的 \(ext.tool) 进程 \(ext.pid)，可在菜单栏里结束"
                    : "   占用者：\(ext.origin.label)，结束了也会被重新拉起，请先停掉它或换个端口")
            }
            return ControlResponse(ok: false, message: lines.joined(separator: "\n"))
        case .failed(let reason):
            return ControlResponse(ok: false, message: "❌ \(reason)")
        case .connecting:
            return ControlResponse(ok: false, message: "⏳ 20 秒内未连上，App 仍在尝试，进度见菜单栏")
        case .off:
            return ControlResponse(ok: false, message: "❌ 隧道未启动")
        }
    }

    private func matching(_ req: ControlRequest, enabledOnly: Bool) -> [TunnelSpec] {
        specs.filter { s in
            (!enabledOnly || s.enabled)
                && (req.kind == nil || s.kind == req.kind)
                && (req.host == nil || s.host == req.host)
                && (req.local == nil || s.localPort == req.local || s.remotePort == req.local)
        }
    }

    private func down(_ req: ControlRequest) -> ControlResponse {
        let matched = matching(req, enabledOnly: true)
        guard !matched.isEmpty else {
            return ControlResponse(ok: false, message: "⚠️ 没有匹配的运行中隧道")
        }
        matched.forEach { setEnabled($0.id, false) }
        let lines = matched.map { "✅ 已关闭：\($0.summary)" }
        return ControlResponse(ok: true, message: lines.joined(separator: "\n"))
    }

    private func listing() -> String {
        var lines: [String] = []
        for host in menuHosts {
            lines.append(host)
            for spec in specs(for: host) {
                let status = runners[spec.id].map(Self.statusText) ?? "已关闭"
                lines.append("  \(spec.enabled ? "●" : "○") \(spec.summary)  \(status)")
            }
        }
        if !externals.isEmpty {
            lines.append("外部进程")
            for e in externals {
                lines.append("  ● \(e.label.replacingOccurrences(of: "服务器", with: e.host))  \(e.origin.label)（\(e.tool) \(e.pid)）")
            }
        }
        return lines.isEmpty ? "还没有隧道" : lines.joined(separator: "\n")
    }

    static func statusText(_ runner: TunnelRunner) -> String {
        switch runner.phase {
        case .off: return "已关闭"
        case .connecting: return "连接中"
        case .connected:
            return runner.upstreamDown ? "本机:\(runner.spec.localPort) 未在监听" : "已连接"
        case .retrying(let reason, _): return "\(reason)，重试中"
        case .failed(let reason): return reason
        }
    }
}
