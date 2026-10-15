import Foundation
import EmailCore

// keymail-mcp: the MCP server AI agents launch (Claude Desktop, Claude Code, Codex, Gemini…).
// It speaks MCP over stdin/stdout and forwards every tool call to the running Keymail app, which holds the accounts
// and decides what's allowed. This process never sees passwords or tokens.

let demo = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
    || CommandLine.arguments[0].contains("Keymail Demo.app")
let path = ProcessInfo.processInfo.environment["KEYMAIL_SOCKET"] ?? AgentSocket.path(demo: demo)
let notRunning = "Keymail isn't reachable. Open Keymail and turn on Settings → MCP → Allow AI agents."

setvbuf(stdout, nil, _IOLBF, 0)
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let reply = await mcpReply(to: line, tools: {
        (AgentSocket.request(["op": "list"], path: path)?["tools"] as? [[String: Any]]) ?? []
    }, call: { name, args in
        guard let r = AgentSocket.request(["op": "call", "name": name, "args": args], path: path) else { return (notRunning, true) }
        return (r["text"] as? String ?? "", r["isError"] as? Bool ?? false)
    })
    if let reply { print(reply) }
}
