import Foundation

/// What a helper program (curl, an AI command-line tool) did.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
}

/// Output collected while the program runs, so a stuck program still gives back what it wrote.
private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: UnsafeRawBufferPointer) { lock.withLock { data.append(contentsOf: bytes) } }
    var value: Data { lock.withLock { data } }
}

private func drain(_ handle: FileHandle, into out: Output, _ done: DispatchGroup) {
    done.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer { done.leave() }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(handle.fileDescriptor, &buffer, buffer.count)
            if n > 0 { buffer.withUnsafeBytes { out.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) } }
            else if n < 0, errno == EINTR { continue }
            else { return }
        }
    }
}

/// Runs a program to completion without the ways that can go wrong with pipes: input, output and errors each move on
/// their own thread (one full pipe can't deadlock the others), a program that quits early can't crash Keymail, and one
/// that never finishes is stopped after `timeout`.
public func runProcessBlocking(_ path: String, _ arguments: [String], input: Data = Data(), environment: [String: String]? = nil,
                               directory: URL? = nil, timeout: TimeInterval) throws -> ProcessResult {
    signal(SIGPIPE, SIG_IGN)   // a closed pipe must be an error on the write below, not the end of the app
    let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    if let environment { p.environment = environment }
    if let directory { p.currentDirectoryURL = directory }
    p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
    try p.run()

    let out = Output(), err = Output(), readers = DispatchGroup()
    drain(stdout.fileHandleForReading, into: out, readers)
    drain(stderr.fileHandleForReading, into: err, readers)
    DispatchQueue.global(qos: .userInitiated).async {
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }

    let flag = NSLock(); nonisolated(unsafe) var timedOut = false
    let stop = DispatchWorkItem { flag.withLock { timedOut = true }; p.terminate() }
    let kill = DispatchWorkItem { if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 3, execute: kill)
    p.waitUntilExit()
    stop.cancel(); kill.cancel()
    // A program can leave a child behind that still holds the pipes open; don't wait on it for long.
    _ = readers.wait(timeout: .now() + 2)
    return ProcessResult(status: p.terminationStatus, stdout: out.value, stderr: err.value, timedOut: flag.withLock { timedOut })
}

/// The same, off Swift's small shared thread pool: several slow AI runs waiting there could otherwise starve all other background work.
public func runProcess(_ path: String, _ arguments: [String], input: Data = Data(), environment: [String: String]? = nil,
                       directory: URL? = nil, timeout: TimeInterval) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<ProcessResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            c.resume(with: Result { try runProcessBlocking(path, arguments, input: input, environment: environment, directory: directory, timeout: timeout) })
        }
    }
}

/// The arguments for sending through the system curl. `-q` comes first (curl requires that): it ignores ~/.curlrc, a file
/// that could otherwise turn off certificate checks or send mail, with its password, through a proxy.
public func smtpCurlArguments(url: String, sender: String, recipients: [String], configFile: String) -> [String] {
    ["-q", "--silent", "--show-error", "--max-time", "180", "--url", url, "--ssl-reqd", "--mail-from", sender]
        + recipients.flatMap { ["--mail-rcpt", $0] } + ["--upload-file", "-", "-K", configFile]
}
