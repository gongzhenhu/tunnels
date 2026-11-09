import Foundation

/// App 与 `tunnel` 命令行之间的协议：一行 JSON 请求，一行 JSON 响应，走 Unix socket。
struct ControlRequest: Codable {
    var cmd: String
    var host: String?
    var kind: TunnelKind?
    var local: Int?
    var remote: Int?
    var args: [String]?
}

struct ControlResponse: Codable {
    var ok: Bool
    var message: String
}

enum UnixSocket {
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1)) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func readLine(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

final class ControlServer {
    private let handler: @MainActor (ControlRequest) async -> ControlResponse

    init(handler: @escaping @MainActor (ControlRequest) async -> ControlResponse) {
        self.handler = handler
    }

    func start() {
        let path = AppPaths.socket
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0,
              UnixSocket.withAddress(path, { bind(fd, $0, $1) }) == 0,
              listen(fd, 8) == 0 else {
            NSLog("Tunnels: 无法监听 \(path)")
            return
        }
        let handler = self.handler
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global().async {
                    let data = UnixSocket.readLine(client)
                    guard let req = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
                        close(client)
                        return
                    }
                    Task { @MainActor in
                        let resp = await handler(req)
                        var out = (try? JSONEncoder().encode(resp)) ?? Data()
                        out.append(0x0A)
                        DispatchQueue.global().async {
                            UnixSocket.writeAll(client, out)
                            close(client)
                        }
                    }
                }
            }
        }.start()
    }
}

enum ControlClient {
    static func send(_ req: ControlRequest, timeout: Int = 30) -> ControlResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard UnixSocket.withAddress(AppPaths.socket, { connect(fd, $0, $1) }) == 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard var data = try? JSONEncoder().encode(req) else { return nil }
        data.append(0x0A)
        UnixSocket.writeAll(fd, data)
        return try? JSONDecoder().decode(ControlResponse.self, from: UnixSocket.readLine(fd))
    }
}
