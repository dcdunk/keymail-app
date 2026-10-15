import Foundation

/// Keymail ↔ keymail-mcp: a Unix socket in Keymail's own Application Support folder (owner-only, mode 0600).
/// One JSON object per line each way. Requests: {"op":"list"} or {"op":"call","name":…,"args":{…}}.
public enum AgentSocket {
    public static func path(demo: Bool) -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(demo ? "Email-Demo" : "Email").appendingPathComponent("agents.sock").path
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        return addr
    }

    /// Client side: send one request line, read one reply line. nil when Keymail isn't running (or agents are off).
    public static func request(_ obj: [String: Any], path: String) -> [String: Any]? {
        guard var addr = address(path), let body = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { return nil }
        let out = body + Data([0x0A])
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        guard let line = readLine(fd) else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Reads up to the next newline (or end of stream).
    public static func readLine(_ fd: Int32) -> Data? {
        var data = Data(), byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return data }
            data.append(byte)
            if data.count > 20_000_000 { return nil }
        }
        return data.isEmpty ? nil : data
    }

    /// Server side: listen at `path`; each line read is answered by `handle` on a background thread per connection.
    public static func serve(path: String, handle: @escaping @Sendable ([String: Any]) -> [String: Any]) -> Int32? {
        unlink(path)
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return } // closed by stop()
                Thread.detachNewThread {
                    defer { close(client) }
                    while let line = readLine(client) {
                        let req = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
                        guard let reply = try? JSONSerialization.data(withJSONObject: handle(req)) else { return }
                        let out = reply + Data([0x0A])
                        _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
                    }
                }
            }
        }
        return fd
    }

    public static func stop(_ fd: Int32, path: String) { close(fd); unlink(path) }
}
