import Foundation
import Network
import EmailCore

struct IMAPResponse { var line: String; var literals: [Data] }

/// Minimal IMAP client over TLS: tagged commands, literals, nothing else.
/// Never logs commands, since LOGIN carries the password.
final class IMAPConnection {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "imap")
    private var buffer = Data()
    private var tagN = 0

    init(host: String = "imap.mail.me.com", port: UInt16 = 993) {
        conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tls)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { s in
                guard !done else { return }
                switch s {
                case .ready: done = true; c.resume()
                case .failed(let e), .waiting(let e): done = true; c.resume(throwing: e)
                default: break
                }
            }
            conn.start(queue: queue)
        }
        _ = try await readResponse() // server greeting
    }

    func close() {
        conn.send(content: Data("Z LOGOUT\r\n".utf8), completion: .contentProcessed { _ in })
        conn.cancel()
    }

    private func send(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }

    private func fill() async throws {
        let d: Data = try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, err in
                if let err { c.resume(throwing: err) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if complete { c.resume(throwing: AppError("iCloud closed the connection.")) }
                else { c.resume(returning: Data()) }
            }
        }
        buffer.append(d)
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer = buffer.subdata(in: r.upperBound..<buffer.endIndex)
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = buffer.subdata(in: buffer.startIndex..<buffer.startIndex + n)
        buffer = buffer.subdata(in: buffer.startIndex + n..<buffer.endIndex)
        return out
    }

    /// One logical response. A line ending in {N} is followed by N raw bytes, then the rest of the line.
    private func readResponse() async throws -> IMAPResponse {
        var r = IMAPResponse(line: try await readLine(), literals: [])
        while let m = r.line.range(of: "\\{(\\d+)\\}$", options: .regularExpression), let n = Int(r.line[m].dropFirst().dropLast()) {
            r.literals.append(try await readBytes(n))
            r.line = String(r.line[..<m.lowerBound]) + "{}" + (try await readLine())
        }
        return r
    }

    @discardableResult
    func command(_ cmd: String, literal: Data? = nil) async throws -> [IMAPResponse] {
        tagN += 1
        let tag = "A\(tagN)"
        if let literal {
            try await send(Data("\(tag) \(cmd) {\(literal.count)}\r\n".utf8))
            let cont = try await readResponse()
            guard cont.line.hasPrefix("+") else { throw AppError("iCloud refused: \(cont.line.prefix(120))") }
            try await send(literal + Data("\r\n".utf8))
        } else {
            try await send(Data("\(tag) \(cmd)\r\n".utf8))
        }
        var out: [IMAPResponse] = []
        while true {
            let r = try await readResponse()
            if r.line.hasPrefix(tag + " ") {
                if r.line.hasPrefix(tag + " OK") { return out }
                throw AppError("iCloud: \(r.line.dropFirst(tag.count + 1).prefix(160))")
            }
            out.append(r)
        }
    }
}

/// iCloud Mail over IMAP (imap.mail.me.com) and SMTP (smtp.mail.me.com) with an app-specific password.
struct ICloud {
    let account: String
    var login: String   // IMAP username: usually the part before @, sometimes the full address
    static func keychainKey(_ a: String) -> String { "icloud:" + a }

    /// Tries the username/password forms Apple accepts and returns the first that works.
    /// Throws with iCloud's own reply if none do.
    static func findLogin(email: String, password: String) async throws -> (login: String, password: String) {
        let local = String(email.split(separator: "@").first ?? "")
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        var lastReply = ""
        for user in [local, email] where !user.isEmpty {
            for pw in Array(NSOrderedSet(array: [trimmed, compact])) as! [String] {
                let c = IMAPConnection()
                defer { c.close() }
                try await c.open() // a network failure here is a real error, not a wrong password
                do {
                    try await c.command("LOGIN \(imapQuote(user)) \(imapQuote(pw))")
                    return (user, pw)
                } catch { lastReply = error.localizedDescription }
            }
        }
        throw AppError("iCloud rejected the sign-in (\(lastReply)). Check the address, and create a fresh app-specific password at account.apple.com if this one was revoked.")
    }

    private func password() throws -> String {
        guard let p = Keychain.get(Self.keychainKey(account)) else { throw AppError("\(account) needs its app-specific password again. Open Settings → Accounts.") }
        return p
    }

    func session<T>(_ body: (IMAPConnection) async throws -> T) async throws -> T {
        let c = IMAPConnection()
        defer { c.close() }
        try await c.open()
        do { try await c.command("LOGIN \(imapQuote(login)) \(imapQuote(try password()))") }
        catch { throw AppError("iCloud sign-in failed for \(account): \(error.localizedDescription). Re-add it in Settings → Accounts.") }
        return try await body(c)
    }


    private func folder(_ c: IMAPConnection, _ use: String, fallback: String) async throws -> String {
        imapSpecialUse(try await c.command("LIST \"\" \"*\"").map(\.line))[use] ?? fallback
    }

    /// Flags for the last 30 days of INBOX (up to 300), plus full messages for UIDs we don't have yet.
    func syncInbox(cached: Set<Int>) async throws -> (flags: [Int: [String]], new: [Message]) {
        try await session { c in
            try await c.command("SELECT INBOX")
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d-MMM-yyyy"
            let since = f.string(from: Date().addingTimeInterval(-30 * 86400))
            let uids = Array(imapSearchUIDs(try await c.command("UID SEARCH SINCE \(since)").map(\.line)).sorted().suffix(300))
            guard !uids.isEmpty else { return ([:], []) }
            var flags: [Int: [String]] = [:]
            for r in try await c.command("UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID FLAGS)") {
                if let i = imapFetchInfo(r.line) { flags[i.uid] = i.flags }
            }
            var new: [Message] = []
            let missing = uids.filter { !cached.contains($0) }
            for start in stride(from: 0, to: missing.count, by: 25) {
                let chunk = missing[start..<min(start + 25, missing.count)].map(String.init).joined(separator: ",")
                for r in try await c.command("UID FETCH \(chunk) (UID FLAGS BODY.PEEK[])") {
                    guard let i = imapFetchInfo(r.line), let raw = r.literals.first else { continue }
                    new.append(messageFromRaw(raw, uid: i.uid, flags: i.flags, account: account, inInbox: true))
                }
            }
            return (flags, new)
        }
    }

    func setFlag(_ uids: [String], _ flag: String, on: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await session { c in
            try await c.command("SELECT INBOX")
            try await c.command("UID STORE \(uids.joined(separator: ",")) \(on ? "+" : "-")FLAGS (\(flag))")
        }
    }

    /// Moves out of INBOX into Archive (Done) or Trash.
    func move(_ uids: [String], toTrash: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await session { c in
            let dest = toTrash ? try await folder(c, "\\Trash", fallback: "Deleted Messages") : try await folder(c, "\\Archive", fallback: "Archive")
            let caps = try await c.command("CAPABILITY").map(\.line).joined()
            try await c.command("SELECT INBOX")
            let set = uids.joined(separator: ",")
            if caps.contains(" MOVE") {
                try await c.command("UID MOVE \(set) \(imapQuote(dest))")
            } else {
                try await c.command("UID COPY \(set) \(imapQuote(dest))")
                try await c.command("UID STORE \(set) +FLAGS (\\Deleted)")
                try await c.command("EXPUNGE")
            }
        }
    }

    /// Undo: finds messages in Trash or Archive by Message-ID and moves them back to INBOX.
    func restore(messageIds: [String], fromTrash: Bool) async throws {
        let ids = messageIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw AppError("Can't undo: these emails have no Message-ID.") }
        try await session { c in
            let src = fromTrash ? try await folder(c, "\\Trash", fallback: "Deleted Messages") : try await folder(c, "\\Archive", fallback: "Archive")
            let caps = try await c.command("CAPABILITY").map(\.line).joined()
            try await c.command("SELECT \(imapQuote(src))")
            var uids: [Int] = []
            for id in ids { uids += imapSearchUIDs(try await c.command("UID SEARCH HEADER Message-ID \(imapQuote(id))").map(\.line)) }
            guard !uids.isEmpty else { throw AppError("Couldn't find those emails in \(src) to restore.") }
            let set = uids.map(String.init).joined(separator: ",")
            if caps.contains(" MOVE") { try await c.command("UID MOVE \(set) INBOX") }
            else {
                try await c.command("UID COPY \(set) INBOX")
                try await c.command("UID STORE \(set) +FLAGS (\\Deleted)")
                try await c.command("EXPUNGE")
            }
        }
    }

    func attachment(uid: String, id: String) async throws -> Data {
        try await session { c in
            try await c.command("EXAMINE INBOX")
            let raw = try await c.command("UID FETCH \(uid) (UID BODY.PEEK[])").compactMap(\.literals.first).first
            guard let raw, let a = parseRaw(raw).attachments.first(where: { $0.ref.id == id }) else {
                throw AppError("That email is no longer in the iCloud inbox, so its attachment can't be downloaded here.")
            }
            return a.data
        }
    }

    /// Saves a draft in iCloud's Drafts folder, replacing the previous save with the same Message-ID.
    func saveDraft(_ d: Draft) async throws {
        guard let mid = d.messageId else { return }
        var visible = d; visible.bcc = ""
        let raw = Data(buildRaw(visible).utf8)
        try await session { c in
            let drafts = try await folder(c, "\\Drafts", fallback: "Drafts")
            try await deleteByMessageId(c, folder: drafts, mid)
            try await c.command("APPEND \(imapQuote(drafts)) (\\Draft \\Seen)", literal: raw)
        }
    }

    func deleteDraft(messageId: String) async throws {
        try await session { c in try await deleteByMessageId(c, folder: try await folder(c, "\\Drafts", fallback: "Drafts"), messageId) }
    }

    private func deleteByMessageId(_ c: IMAPConnection, folder: String, _ mid: String) async throws {
        try await c.command("SELECT \(imapQuote(folder))")
        let uids = imapSearchUIDs(try await c.command("UID SEARCH HEADER Message-ID \(imapQuote(mid))").map(\.line))
        guard !uids.isEmpty else { return }
        try await c.command("UID STORE \(uids.map(String.init).joined(separator: ",")) +FLAGS (\\Deleted)")
        try await c.command("EXPUNGE")
    }

    /// Sends with the system curl (handles SMTP + STARTTLS), then files a copy in Sent.
    func send(_ draft: Draft) async throws {
        let pw = try password()
        let rcpts = parseAddresses([draft.to, draft.cc, draft.bcc].joined(separator: ",")).map(\.email)
        guard !rcpts.isEmpty else { throw AppError("Add at least one recipient.") }
        var visible = draft; visible.bcc = "" // Bcc must not appear in the message itself
        let raw = Data(buildRaw(visible).utf8)
        // The password goes in a private temp config file, never on the command line where other apps could see it.
        let cfg = FileManager.default.temporaryDirectory.appendingPathComponent("email-smtp-\(UUID().uuidString).cfg")
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        FileManager.default.createFile(atPath: cfg.path, contents: Data("user = \"\(esc(login.contains("@") ? login : account)):\(esc(pw))\"\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: cfg) }
        let sender = parseAddresses(draft.from).first?.email ?? account
        try await Task.detached {
            let p = Process(), input = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--silent", "--show-error", "--url", "smtp://smtp.mail.me.com:587", "--ssl-reqd",
                           "--mail-from", sender] + rcpts.flatMap { ["--mail-rcpt", $0] } + ["--upload-file", "-", "-K", cfg.path]
            p.standardInput = input; p.standardError = err; p.standardOutput = Pipe()
            try p.run()
            input.fileHandleForWriting.write(raw); try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw AppError("iCloud couldn't send: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(200))")
            }
        }.value
        try? await session { c in
            let sent = try await folder(c, "\\Sent", fallback: "Sent Messages")
            try await c.command("APPEND \(imapQuote(sent)) (\\Seen)", literal: raw)
        }
    }
}
