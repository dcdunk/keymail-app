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
        noSigPipe(fd)
        guard writeAll(fd, body + Data([0x0A])), let line = readReply(fd) else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// A peer that hung up is an error from write(), not a signal that ends the process.
    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// write() may take only part of a big reply, so keep going until it's all out. false when the peer is gone.
    @discardableResult static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n > 0 { sent += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// One reply line, in big reads: the client asks once per connection, so nothing past the newline is lost.
    /// Byte-at-a-time meant one system call per character of every email an agent read.
    static func readReply(_ fd: Int32) -> Data? {
        var data = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
        while data.count <= 20_000_000 {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return data.isEmpty ? nil : data }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) { data.append(contentsOf: chunk[0..<nl]); return data }
            data.append(contentsOf: chunk[0..<n])
        }
        return nil
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
                noSigPipe(client)
                Thread.detachNewThread {
                    defer { close(client) }
                    while let line = readLine(client) {
                        let req = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
                        guard let reply = try? JSONSerialization.data(withJSONObject: handle(req)) else { return }
                        guard writeAll(client, reply + Data([0x0A])) else { return }
                    }
                }
            }
        }
        return fd
    }

    public static func stop(_ fd: Int32, path: String) { close(fd); unlink(path) }
}
