import Foundation

enum SSHConfig {
    /// ~/.ssh/config 里可以建隧道的主机，保持原文顺序。
    /// 跳过通配符，以及被其他主机的 ProxyJump / ProxyCommand 引用的跳板机。
    static func hosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [String] = []
        var jumpHosts: Set<String> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count >= 2 else { continue }
            switch parts[0].lowercased() {
            case "host":
                for pattern in parts.dropFirst()
                where !pattern.contains(where: { "*?!".contains($0) }) && !result.contains(pattern) {
                    result.append(pattern)
                }
            case "proxyjump":
                for hop in parts[1].split(separator: ",") { jumpHosts.insert(hostName(of: hop)) }
            case "proxycommand":
                // 如 `ssh -q -W %h:%p nlu-dev`：命令里出现的主机别名就是跳板
                jumpHosts.formUnion(parts.dropFirst())
            default:
                break
            }
        }
        return result.filter { !jumpHosts.contains($0) }
    }

    /// ProxyJump 的一跳可能写成 user@host:port
    private static func hostName(of hop: Substring) -> String {
        var host = hop.split(separator: "@").last.map(String.init) ?? String(hop)
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }
}
