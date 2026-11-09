import Foundation
import Observation

enum TunnelPhase: Equatable {
    case off
    case connecting
    case connected(since: Date)
    case retrying(reason: String, at: Date)
    /// 不再自动重试（认证失败等重试无意义的情况）
    case failed(String)
}

/// 监管一条隧道对应的 ssh 进程：启动、解析 -v 输出判断状态、断开后退避重连。
@MainActor @Observable
final class TunnelRunner {
    /// 写进 ssh 参数，便于在 ps 里认出本 App 起的进程（崩溃后清理孤儿）
    nonisolated static let tag = "tunnels-app"

    let spec: TunnelSpec
    private(set) var phase: TunnelPhase = .off
    /// 反向隧道的本地目标端口没在监听（比如 Clash 没开）
    private(set) var upstreamDown = false
    private(set) var log: [String] = []
    private(set) var pid: Int32?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var reason: String?
    @ObservationIgnored private var fatal: String?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init(spec: TunnelSpec) {
        self.spec = spec
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    var needsAttention: Bool {
        switch phase {
        case .retrying, .failed: return true
        case .connected: return upstreamDown
        default: return false
        }
    }

    func start() {
        retryTask?.cancel()
        retryTask = nil
        guard process == nil else { return }
        attempt = 0
        launch()
        if spec.kind == .reverse && probeTask == nil { startProbe() }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        probeTask?.cancel()
        probeTask = nil
        generation += 1
        process?.terminate()
        process = nil
        pid = nil
        upstreamDown = false
        phase = .off
    }

    /// 网络恢复时：正在等待重试的立即重连
    func retryNowIfWaiting() {
        guard case .retrying = phase, process == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        launch()
    }

    /// 睡眠唤醒后：旧连接大概率已失效，直接重建
    func restart() {
        guard phase != .off else { return }
        generation += 1
        process?.terminate()
        process = nil
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        launch()
    }

    private var arguments: [String] {
        ["-v", "-N", "-T",
         "-o", "BatchMode=yes",
         "-o", "ExitOnForwardFailure=yes",
         "-o", "ServerAliveInterval=15",
         "-o", "ServerAliveCountMax=3",
         "-o", "ConnectTimeout=10",
         "-o", "Tag=\(Self.tag)"] + spec.sshArguments + [spec.host]
    }

    private func launch() {
        generation += 1
        let gen = generation
        reason = nil
        fatal = nil
        phase = .connecting

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            phase = .failed("无法启动 ssh：\(error.localizedDescription)")
            return
        }
        process = p
        pid = p.processIdentifier

        // 同一线程顺序读 stderr 再等退出，保证“退出”一定排在最后一批日志之后处理
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                var lines: [String] = []
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                if !lines.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(lines, gen) } }
                }
            }
            p.waitUntilExit()
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status, gen) } }
        }
    }

    private func handle(_ lines: [String], _ gen: Int) {
        guard gen == generation else { return }
        for line in lines where !line.isEmpty {
            record(line)
            classify(line)
        }
    }

    private static let keyDebug = [
        "forwarding listening", "remote forward", "Entering interactive",
        "connect_to", "open failed", "Exit status",
    ]

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 只留有信息量的行，丢掉 -v 的协议细节
    private func record(_ line: String) {
        guard !line.hasPrefix("debug1:") || Self.keyDebug.contains(where: line.contains) else { return }
        let text = line.hasPrefix("debug1: ") ? String(line.dropFirst(8)) : line
        log.append("\(Self.clock.string(from: Date()))  \(text)")
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    private func classify(_ line: String) {
        if !isConnected {
            if line.contains("Permission denied") {
                fatal = "认证失败，需要免密的密钥登录"
            } else if line.contains("Host key verification failed") {
                fatal = "主机密钥校验失败"
            } else if line.contains("Address already in use") {
                reason = "本地端口 \(spec.localPort) 已被占用"
            } else if line.contains("remote port forwarding failed") {
                reason = "服务器端口 \(spec.remotePort) 已被占用"
            } else if line.contains("Could not resolve hostname") {
                reason = "无法解析主机名"
            } else if line.contains("timed out") {
                reason = "连接超时"
            } else if line.contains("Network is unreachable") || line.contains("No route to host") {
                reason = "网络不可达"
            } else if line.contains("Connection refused") {
                reason = "连接被拒绝"
            }
        } else if line.contains("Timeout, server") {
            reason = "服务器无响应"
        }

        let ready = spec.kind == .forward
            ? line.contains("Entering interactive session")
            : line.contains("remote forward success")
        if ready && !isConnected {
            attempt = 0
            reason = nil
            phase = .connected(since: Date())
        }
    }

    private func exited(_ status: Int32, _ gen: Int) {
        guard gen == generation else { return }
        process = nil
        pid = nil
        if let fatal {
            probeTask?.cancel()
            probeTask = nil
            phase = .failed(fatal)
            return
        }
        let why = reason ?? (isConnected ? "连接断开" : "连接失败（ssh 退出码 \(status)）")
        attempt += 1
        let delay = min(60, 1 << min(attempt - 1, 6))
        phase = .retrying(reason: why, at: Date().addingTimeInterval(TimeInterval(delay)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    private func startProbe() {
        let port = spec.localPort
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                let up = await PortProbe.isListening(port)
                guard let self, !Task.isCancelled else { return }
                if self.upstreamDown == up { self.upstreamDown = !up }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

enum PortProbe {
    static func isListening(_ port: Int) async -> Bool {
        await Task.detached { connectLocal(port) }.value
    }

    private static func connectLocal(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
