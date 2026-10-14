import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Attachments

    func fetchAttachment(account: String, messageId: String, id: String) async throws -> Data {
        isICloud(account) ? try await icloud(account).attachment(uid: messageId, id: id)
                          : try await gmail(account).attachment(message: messageId, id: id)
    }

    /// Downloads images embedded in the body (cid:) so they render. Skips anything over 5 MB.
    func loadInlineImages(_ msgs: [Message]) async {
        for m in msgs where inlineData[m.key] == nil && (m.html?.contains("cid:") ?? false) {
            var map: [String: String] = [:]
            for a in m.attachments where a.isInline && a.size < 5_000_000 {
                if let data = try? await fetchAttachment(account: m.account, messageId: m.id, id: a.id), let cid = a.contentId {
                    map[cid] = "data:\(a.mimeType);base64,\(data.base64EncodedString())"
                }
            }
            inlineData[m.key] = map
        }
    }

    /// Saves to Downloads (never overwriting) and opens it.
    func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Gmail attachment IDs run ~500 characters; macOS file names max out at 255. Hash to a short, stable folder name.
    func shortKey(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Quick Look preview. Files are cached in Caches/Email so reopening is instant; macOS may clear them any time.
    func preview(account: String, messageId: String, attachmentId: String, name: String) {
        Task {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(AppFlavor.isDemo ? "Email-Demo" : "Email")/\(safeName(account))/\(shortKey(messageId))/\(shortKey(attachmentId))")
            let url = dir.appendingPathComponent(safeName(name))
            if !FileManager.default.fileExists(atPath: url.path) {
                busy = "Opening \(name)…"
                defer { busy = nil }
                do {
                    let data = try await fetchAttachment(account: account, messageId: messageId, id: attachmentId)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try data.write(to: url)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch { report(error); return }
            }
            previewURL = url
        }
    }

    /// Thumbnails for photos attached to an email (up to 15 MB each), loaded when the message is shown.
    func loadThumbnail(_ m: Message, _ a: AttachmentRef) {
        let key = m.key + "|" + a.id
        guard thumbnails[key] == nil, a.size < 15_000_000 else { return }
        thumbnails[key] = NSImage() // placeholder so it's only fetched once
        Task {
            if let data = try? await fetchAttachment(account: m.account, messageId: m.id, id: a.id), let img = NSImage(data: data) {
                thumbnails[key] = img
            }
        }
    }

    /// Saves to Downloads (never overwriting) and shows it in Finder.
    func download(account: String, messageId: String, attachmentId: String, name: String) {
        Task {
            busy = "Downloading \(name)…"
            defer { busy = nil }
            do {
                let data = try await fetchAttachment(account: account, messageId: messageId, id: attachmentId)
                let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let safe = safeName(name)
                var url = dir.appendingPathComponent(safe), n = 1
                while FileManager.default.fileExists(atPath: url.path) {
                    url = dir.appendingPathComponent("\((safe as NSString).deletingPathExtension) (\(n)).\((safe as NSString).pathExtension)"); n += 1
                }
                try data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                banner = "Saved \(url.lastPathComponent) to Downloads."
            } catch { report(error) }
        }
    }
}
