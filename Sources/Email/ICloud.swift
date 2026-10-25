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

    /// A connection that went quiet this long is dead (the Mac slept, Wi-Fi changed). Without a limit a read waited
    /// forever, and since accounts sync one after another, all mail stopped until Keymail was quit.
    nonisolated(unsafe) static var silence: TimeInterval = 60

    init(host: String, port: UInt16 = 993) {
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
            queue.asyncAfter(deadline: .now() + Self.silence) { [conn] in
                guard !done else { return }
                done = true; conn.cancel(); c.resume(throwing: URLError(.timedOut))
            }
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
            var answered = false   // both closures run on `queue`, so this needs no lock
            queue.asyncAfter(deadline: .now() + Self.silence) { [conn] in if !answered { conn.cancel() } }   // ends the receive below with an error
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, err in
                answered = true
                if let err { c.resume(throwing: err) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if complete { c.resume(throwing: AppError("The mail server closed the connection.")) }
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
            guard cont.line.hasPrefix("+") else { throw AppError("The mail server refused: \(cont.line.prefix(120))") }
            try await send(literal + Data("\r\n".utf8))
        } else {
            try await send(Data("\(tag) \(cmd)\r\n".utf8))
        }
        var out: [IMAPResponse] = []
        while true {
            let r = try await readResponse()
            if r.line.hasPrefix(tag + " ") {
                if r.line.hasPrefix(tag + " OK") { return out }
                throw AppError("Mail server: \(r.line.dropFirst(tag.count + 1).prefix(160))")
            }
            out.append(r)
        }
    }
}

/// iCloud or Yahoo Mail over IMAP and SMTP with an app-specific password. Servers come from `imapServer(for:)`.
struct ICloud {
    let account: String
    var login: String   // IMAP username: usually the part before @, sometimes the full address
    var server: IMAPServer { imapServer(for: account) }
    static func keychainKey(_ a: String) -> String { "icloud:" + a }

    /// Tries the username/password forms Apple accepts and returns the first that works.
    /// Throws with iCloud's own reply if none do.
    static func findLogin(email: String, password: String) async throws -> (login: String, password: String) {
        let server = imapServer(for: email)
        // Yahoo only takes the full address; Apple usually takes the part before @.
        let local = server.name == "Yahoo" ? "" : String(email.split(separator: "@").first ?? "")
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        var lastReply = ""
        for user in [local, email] where !user.isEmpty {
            for pw in Array(NSOrderedSet(array: [trimmed, compact])) as! [String] {
                let c = IMAPConnection(host: server.imapHost)
                defer { c.close() }
                try await c.open() // a network failure here is a real error, not a wrong password
                do {
                    try await c.command("LOGIN \(imapQuote(user)) \(imapQuote(pw))")
                    return (user, pw)
                } catch { lastReply = error.localizedDescription }
            }
        }
        throw AppError("\(server.name) rejected the sign-in (\(lastReply)). Check the address, and create a fresh app password\(server.name == "Yahoo" ? " in Yahoo Account Security" : " at account.apple.com") if this one was revoked.")
    }

    private func password() throws -> String {
        guard let p = Keychain.get(Self.keychainKey(account)) else { throw AppError("\(account) needs its app-specific password again. Open Settings → Accounts.") }
        return p
    }

    /// Accounts whose password the server turned down. Keymail stops signing in to them until the password is
    /// re-entered: Apple locks an Apple Account after repeated failed sign-ins, and a sync every 30 seconds adds up fast.
    nonisolated(unsafe) private static var rejected = Set<String>()
    private static let rejectedLock = NSLock()
    static func isRejected(_ a: String) -> Bool { rejectedLock.withLock { rejected.contains(a) } }
    static func setRejected(_ a: String, _ on: Bool) { rejectedLock.withLock { if on { rejected.insert(a) } else { rejected.remove(a) }; refusalCount[a] = nil } }
    nonisolated(unsafe) private static var refusalCount: [String: Int] = [:]
    nonisolated(unsafe) private static var lastRefusal: [String: Date] = [:]
    /// Counts a refused sign-in and returns how many in a row; a successful sign-in resets it.
    /// At most one strike per 4 minutes: archiving or opening an attachment during one bad moment opens more sign-ins,
    /// and those used to add up to 3 strikes within seconds.
    static func refused(_ a: String, now: Date = Date()) -> Int {
        rejectedLock.withLock {
            if let last = lastRefusal[a], now.timeIntervalSince(last) < 240 { return refusalCount[a, default: 1] }
            lastRefusal[a] = now; refusalCount[a, default: 0] += 1; return refusalCount[a]!
        }
    }
    static func refusals(reset a: String) { rejectedLock.withLock { refusalCount[a] = nil; lastRefusal[a] = nil } }

    func session<T>(_ body: (IMAPConnection) async throws -> T) async throws -> T {
        guard !Self.isRejected(account) else { throw SignInRejected(account: account, server: server.name) }
        let c = IMAPConnection(host: server.imapHost)
        defer { c.close() }
        try await c.open()
        do { try await c.command("LOGIN \(imapQuote(login)) \(imapQuote(try password()))") }
        catch let e as AppError where e.errorDescription?.hasPrefix("Mail server:") == true {   // the server said no
            let reply = e.errorDescription ?? ""
            let who = account
            await MainActor.run { AppStore.current?.log("\(who): sign-in refused: \(reply.prefix(200))") }   // the server's words only, never the password
            // "Busy, try later" is not "wrong password": only a real refusal stops sign-ins until a new password.
            guard imapLoginRefusal(reply) else { throw URLError(.cannotConnectToHost) }
            // iCloud now and then refuses a password that worked a minute ago. Give up only on the 3rd refusal in a row
            // (the sync waits a few minutes between tries), still far too few to lock the Apple Account.
            guard Self.refused(account) >= 3 else { throw URLError(.userAuthenticationRequired) }
            Self.setRejected(account, true)
            throw SignInRejected(account: account, server: server.name)
        }   // anything else (timeouts, dropped connections) is the network: rethrown as is and retried later
        Self.refusals(reset: account)
        return try await body(c)
    }


    private func folder(_ c: IMAPConnection, _ use: String, fallback: String) async throws -> String {
        imapSpecialUse(try await c.command("LIST \"\" \"*\"").map(\.line))[use] ?? fallback
    }

    /// Server folder for each Keymail folder: the special-use flag the server marks it with, and its usual name.
    /// iCloud's trash is "Deleted Messages", the same folder Apple Mail and iCloud.com use.
    static func mailbox(_ which: String) -> (use: String, fallback: String) {
        ["sent": ("\\Sent", "Sent Messages"), "drafts": ("\\Drafts", "Drafts"), "trash": ("\\Trash", "Deleted Messages"),
         "junk": ("\\Junk", "Junk")][which]
            ?? ("\\Archive", "Archive")
    }

    /// The newest `limit` emails in Sent ("sent"), Drafts ("drafts"), Trash ("trash") or Archive ("archive"). UIDs are per mailbox, so ids
    /// get a prefix ("sent:123") that INBOX numbers can never match; actions that act by UID only ever use plain INBOX ids.
    func recent(_ which: String, limit: Int = 50, skip: Set<String>) async throws -> [Message] {
        try await session { c in
            let (use, fallback) = Self.mailbox(which)
            let box = try await folder(c, use, fallback: fallback)
            try await c.command("SELECT \(imapQuote(box))")
            let uids = imapSearchUIDs(try await c.command("UID SEARCH ALL").map(\.line)).sorted().suffix(limit)
                .filter { !skip.contains("\(which):\($0)") }
            guard !uids.isEmpty else { return [] }
            var out: [Message] = []
            for r in try await c.command("UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID FLAGS BODY.PEEK[])") {
                guard let i = imapFetchInfo(r.line), let raw = r.literals.first else { continue }
                var m = messageFromRaw(raw, uid: i.uid, flags: i.flags, account: account, inInbox: false)
                m.id = "\(which):\(i.uid)"
                m.labelIds = m.labelIds.filter { $0 != "IMPORTANT" } + (which == "sent" ? ["SENT"] : [])
                if which == "sent" { m.labelIds.removeAll { $0 == "UNREAD" } }
                if which == "drafts" { m.labelIds = m.labelIds.filter { $0 != "UNREAD" } + ["DRAFT"] }
                if which == "trash" { m.labelIds.append("TRASH") }
                if which == "junk" { m.labelIds.append("SPAM") }
                out.append(m)
            }
            return out
        }
    }

    /// Flags for the newest 300 emails in INBOX, plus full messages for UIDs we don't have yet.
    /// `reset`: the server renumbered the mailbox (UIDVALIDITY changed), so every cached number now means a different
    /// email. Everything is fetched fresh and the caller drops the old copies.
    func syncInbox(cached: Set<Int>) async throws -> (flags: [Int: [String]], new: [Message], reset: Bool) {
        try await session { c in
            let selected = try await c.command("SELECT INBOX").map(\.line).joined(separator: " ")
            let validity = selected.range(of: #"UIDVALIDITY (\d+)"#, options: .regularExpression).map { String(selected[$0].dropFirst(12)) }
            let key = "imapUIDValidity." + account
            let reset = validity != nil && UserDefaults.standard.string(forKey: key).map { $0 != validity } == true
            if let validity { UserDefaults.standard.set(validity, forKey: key) }
            let cached = reset ? [] : cached
            // The newest 300 in the inbox, however old: a 30-day window showed nothing for a quiet inbox whose
            // remaining emails were older than that.
            let uids = Array(imapSearchUIDs(try await c.command("UID SEARCH ALL").map(\.line)).sorted().suffix(300))
            guard !uids.isEmpty else { return ([:], [], reset) }
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
            return (flags, new, reset)
        }
    }

    func setFlag(_ uids: [String], _ flag: String, on: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await session { c in
            try await c.command("SELECT INBOX")
            try await c.command("UID STORE \(uids.joined(separator: ",")) \(on ? "+" : "-")FLAGS (\(flag))")
        }
    }

    /// Moves out of INBOX into Archive ("archive", Done), Trash ("trash") or Junk ("junk").
    func move(_ uids: [String], to which: String) async throws {
        guard !uids.isEmpty else { return }
        try await session { c in
            let (use, fallback) = Self.mailbox(which)
            let dest = try await folder(c, use, fallback: fallback)
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

    /// Undo: finds messages in Trash, Junk or Archive by Message-ID and moves them back to INBOX.
    func restore(messageIds: [String], from which: String) async throws {
        let ids = messageIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw AppError("Can't undo: these emails have no Message-ID.") }
        try await session { c in
            let (use, fallback) = Self.mailbox(which)
            let src = try await folder(c, use, fallback: fallback)
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
            // Sent, Drafts and Archive copies have ids like "sent:12": open that folder and fetch by the plain UID.
            let parts = uid.split(separator: ":"), box = parts.count == 2 ? String(parts[0]) : "inbox"
            let folderName = box == "sent" ? try await folder(c, "\\Sent", fallback: "Sent Messages")
                : box == "drafts" ? try await folder(c, "\\Drafts", fallback: "Drafts")
                : box == "archive" ? try await folder(c, "\\Archive", fallback: "Archive") : "INBOX"
            try await c.command("EXAMINE \(imapQuote(folderName))")
            let raw = try await c.command("UID FETCH \(parts.last ?? "") (UID BODY.PEEK[])").compactMap(\.literals.first).first
            guard let raw, let a = parseRaw(raw).attachments.first(where: { $0.ref.id == id }) else {
                throw AppError("That email is no longer in the \(server.name) inbox, so its attachment can't be downloaded here.")
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
        let smtp = server.smtpURL, name = server.name
        try await Task.detached {
            let p = Process(), input = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // --max-time: a stalled mail server can't hold up sending (and scheduled sends, which run inside sync) forever.
            p.arguments = ["--silent", "--show-error", "--max-time", "180", "--url", smtp, "--ssl-reqd",
                           "--mail-from", sender] + rcpts.flatMap { ["--mail-rcpt", $0] } + ["--upload-file", "-", "-K", cfg.path]
            p.standardInput = input; p.standardError = err; p.standardOutput = Pipe()
            try p.run()
            // The throwing write: if curl quits early (password refused, offline) a large email can't kill Keymail.
            try? input.fileHandleForWriting.write(contentsOf: raw); try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw AppError("\(name) couldn't send: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(200))")
            }
        }.value
        do {
            try await session { c in
                let sent = try await folder(c, "\\Sent", fallback: "Sent Messages")
                try await c.command("APPEND \(imapQuote(sent)) (\\Seen)", literal: raw)
            }
        } catch {   // sent, but no copy in Sent: say so instead of a silent gap
            let who = account
            await MainActor.run { AppStore.current?.log("\(who): sent, but couldn't file a copy in Sent: \(error.localizedDescription.prefix(160))") }
        }
    }
}

/// The server turned down the saved app password. Keymail won't try again until it's re-entered.
/// A LOGIN "NO" that means the password itself was refused. Apple and Yahoo also say NO when they're busy, throttling
/// or briefly down ([UNAVAILABLE], [LIMIT], "try again"); those are retried later instead of signing the account out.
func imapLoginRefusal(_ reply: String) -> Bool {
    let r = reply.uppercased()
    if r.contains("AUTHENTICATIONFAILED") || r.contains("AUTHORIZATIONFAILED") { return true }
    let passing = ["UNAVAILABLE", "[LIMIT]", "TOO MANY", "TRY AGAIN", "TEMPORAR", "THROTTL", "LATER", "INUSE", "SERVERBUG", "BUSY"]
    return !passing.contains { r.contains($0) }
}

struct SignInRejected: LocalizedError {
    let account: String, server: String
    var errorDescription: String? {
        "\(server) turned down the app password for \(account), so Keymail stopped signing in to avoid locking your account. "
        + "Create a new app password\(server == "Yahoo" ? " in Yahoo Account Security" : " at account.apple.com") and re-add it in Settings → Accounts."
    }
}
