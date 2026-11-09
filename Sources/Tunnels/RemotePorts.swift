import Foundation

struct RemotePort: Identifiable, Hashable {
    let port: Int
    /// 只有当前用户自己的进程才能看到进程名
    let program: String?
    var id: Int { port }
}

enum RemotePorts {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 列出服务器上可以通过 localhost 访问的监听端口
    static func fetch(host: String) async throws -> [RemotePort] {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host,
                           "ss -Hltnp 2>/dev/null || netstat -ltnp 2>/dev/null"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let ports = parse(String(decoding: data, as: UTF8.self))
            if ports.isEmpty && p.terminationStatus != 0 {
                let last = String(decoding: errData, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init) ?? "ssh 退出码 \(p.terminationStatus)"
                throw FetchError(message: "读取失败：\(last)")
            }
            return ports
        }.value
    }

    static func parse(_ text: String) -> [RemotePort] {
        let reachable: Set<String> = ["127.0.0.1", "0.0.0.0", "::", "::1", "*", ""]
        var byPort: [Int: RemotePort] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 4 else { continue }
            let first = cols[0].lowercased()
            guard first.hasPrefix("tcp") || first == "listen" else { continue }
            // netstat 和 ss -H 的本地地址都在第 4 列
            let local = cols[3]
            guard let colon = local.lastIndex(of: ":"),
                  let port = Int(local[local.index(after: colon)...]) else { continue }
            let addr = local[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard reachable.contains(addr) else { continue }
            if byPort[port]?.program == nil {
                byPort[port] = RemotePort(port: port, program: programName(String(line)))
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    private static func programName(_ line: String) -> String? {
        if let r = line.range(of: "((\"") {
            return line[r.upperBound...].split(separator: "\"").first.map(String.init)
        }
        guard let last = line.split(separator: " ").last,
              let slash = last.firstIndex(of: "/"),
              Int(last[..<slash]) != nil else { return nil }
        return String(last[last.index(after: slash)...])
    }
}
