import AppKit
import Foundation
import Network
import Security
import EmailCore
import CryptoKit

// MARK: AI providers (command-line tools already signed in on this Mac, billed to your own plan)

struct AIProvider: Identifiable, Hashable {
    let id: String, name: String, maker: String, binary: String
    let installURL: String, signInHint: String
    /// Models offered in Settings, newest first, as (CLI model ID, display name). Blank in settings = the tool's own default.
    let models: [(id: String, name: String)]
    /// Arguments for a one-shot, read-only run. The prompt always goes in on stdin.
    let args: (_ model: String?) -> [String]

    static func == (a: AIProvider, b: AIProvider) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let all: [AIProvider] = [
        AIProvider(id: "claude", name: "Claude", maker: "Anthropic", binary: "claude",
                   installURL: "https://claude.com/claude-code", signInHint: "Run `claude` in Terminal and log in.",
                   // support.claude.com/en/articles/11940350 (checked Oct 2026)
                   models: [("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5")],
                   // --tools "" turns every tool off: email text can only produce text.
                   // Skips what a one-shot email task never needs but Claude Code loads on every start: MCP servers,
                   // plugins and hooks from your settings, skills and session saving. About 3s instead of 6-12s.
                   args: { m in ["-p", "--tools", "", "--output-format", "text",
                                 "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "",
                                 "--no-session-persistence", "--disable-slash-commands"] + (m.map { ["--model", $0] } ?? []) }),
        AIProvider(id: "codex", name: "Codex", maker: "OpenAI", binary: "codex",
                   installURL: "https://github.com/openai/codex", signInHint: "Run `codex login` in Terminal.",
                   // learn.chatgpt.com/docs/models (checked Oct 2026). Astra and 6.1 Sol need an API key, not a ChatGPT sign-in.
                   models: [("gpt-6-astra", "GPT-6 Astra"), ("gpt-6.1-sol", "GPT-6.1 Sol"), ("gpt-6-luna", "GPT-6 Luna")],
                   // Read-only sandbox: it can't write files or run commands that change anything.
                   // mcp_servers={}: don't start your Codex MCP servers for an email task (about 3s instead of 7s).
                   args: { m in ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "-c", "mcp_servers={}"] + (m.map { ["-m", $0] } ?? []) }),
        AIProvider(id: "gemini", name: "Gemini", maker: "Google", binary: "gemini",
                   installURL: "https://github.com/google-gemini/gemini-cli", signInHint: "Run `gemini` in Terminal and sign in, or set GEMINI_API_KEY.",
                   // geminicli.com/docs/reference/configuration (checked Oct 2026)
                   models: [("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"), ("gemini-3.8-flash", "Gemini 3.8 Flash"),
                            ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite"), ("gemini-2.5-pro", "Gemini 2.5 Pro")],
                   // plan = read-only approval mode; --skip-trust lets it run headless outside a trusted project folder.
                   args: { m in ["-p", "Respond to the request above. Output only the answer.", "--approval-mode", "plan", "--skip-trust"]
                       + (m.map { ["-m", $0] } ?? []) }),
    ]
}

enum AI {
    /// The usual install folders only: instant, so Settings can show what's installed as soon as it opens.
    static func knownBinary(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)",
                          "\(home)/.claude/local/\(name)", "\(home)/.npm-global/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func binary(_ name: String) -> String? {
        if let hit = knownBinary(name) { return hit }
        // Apps launched from Finder don't get your shell PATH, so ask a login shell.
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v \(name)"]; p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func run(_ prompt: String, with provider: AIProvider, model: String? = nil) async throws -> String {
        guard let bin = binary(provider.binary) else {
            throw AppError("\(provider.name) isn't installed. Install it, then: \(provider.signInHint)")
        }
        let model = model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return try await Task.detached {
            let p = Process(), input = Pipe(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = provider.args(model)
            // An empty scratch folder, so nothing in it is worth reading.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("email-ai")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["NO_COLOR"] = "1"
            p.environment = env
            p.standardInput = input; p.standardOutput = out; p.standardError = err
            try p.run()
            input.fileHandleForWriting.write(Data(prompt.utf8)); try? input.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0, !text.isEmpty else {
                let msg = String(decoding: errData + data, as: UTF8.self)
                // Surface the tool's own error line, which says what's wrong (login, model, plan).
                let line = msg.components(separatedBy: .newlines).last { $0.contains("rror") || $0.lowercased().contains("login") || $0.lowercased().contains("not supported") }
                    ?? msg.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "no output"
                throw AppError("\(provider.name) failed: \(line.trimmingCharacters(in: .whitespaces).prefix(220))")
            }
            return text
        }.value
    }
}
