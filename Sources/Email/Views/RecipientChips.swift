import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            if v == subviews.last { s.width = max(s.width, b.maxX - x) } // the text field takes the rest of the line
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// Recipients as chips. The underlying value stays a normal "a@b.com, Name <c@d.com>, " string.
struct RecipientChips: View {
    @EnvironmentObject var store: AppStore
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    let key: (RecipientKey, String) -> String?   // Tab/Return while suggestions show

    var committed: [Address] {
        parseAddresses(splitRecipientField(text).head)
    }

    var body: some View {
        let token = Binding<String>(
            get: { currentToken(text) },
            set: { new in
                let head = committed.map(\.formatted)
                if new.contains(",") || new.hasSuffix(" ") && new.contains("@") {
                    // A comma (or a space after a full address) turns what's typed into chips. A pasted list becomes one
                    // chip per person; stripping the commas used to merge "Ann <a@x>, Bob <b@y>" into one chip for Bob.
                    // A comma inside a quoted name ("Doe, Jane") waits for the closing quote.
                    let parts = splitRecipientField(new)
                    let done = parseAddresses(parts.head).filter { !$0.email.isEmpty }.map(\.formatted)
                    let rest = parts.token.trimmingCharacters(in: .whitespaces)
                    let finishRest = new.hasSuffix(" ") && rest.contains("@") && !rest.contains("\"")
                    text = (head + done + (finishRest ? [rest] : [])).map { $0 + ", " }.joined() + (finishRest ? "" : rest)
                } else {
                    text = (head.map { $0 + ", " }.joined()) + new
                }
            })
        FlowLayout(spacing: 6) {
            ForEach(Array(committed.enumerated()), id: \.offset) { i, a in
                HStack(spacing: 5) {
                    Avatar(address: a, size: 18)
                    Text(a.name.isEmpty ? a.email : a.name).lineLimit(1)
                    ChipRemoveButton { remove(i) }
                }
                .font(.scaled(.callout)).padding(.leading, 3).padding(.trailing, 3).padding(.vertical, 2)
                .background(Capsule().fill(a.email.contains("@") ? Color.primary.opacity(0.07) : Color.red.opacity(0.15)))
                .help(a.email)
            }
            TextField(committed.isEmpty ? placeholder : "", text: token)
                .textFieldStyle(.plain).focused(focus, equals: field)
                .frame(minWidth: 120)
                .onSubmit { if let c = key(.enter, text) { text = c } else { commit() } }
                .onKeyPress(.tab) {
                    if let c = key(.tab, text) { text = c; return .handled }
                    if !currentToken(text).isEmpty { commit(); return .handled }
                    return .ignored
                }
                // The text field swallows Backspace when it's empty, so .onKeyPress never sees it. The app's key
                // handler asks the focused recipient row instead (same approach as search tokens).
                .onChange(of: focus.wrappedValue) { _, now in registerBackspace(now == field) }
                .onAppear {
                    registerBackspace(focus.wrappedValue == field)
                    // Addresses Keymail filled in (a reply's To and Cc, a saved draft) show as chips, not as half-typed text.
                    if let done = chipsFilled(text) { text = done }
                }
                .onDisappear { registerBackspace(false) }
        }
    }

    func registerBackspace(_ on: Bool) {
        if on {
            let text = $text
            store.chipBackspace = {
                guard let shorter = removingLastRecipient(text.wrappedValue) else { return false }
                text.wrappedValue = shorter; return true
            }
        } else if focus.wrappedValue == nil || focus.wrappedValue == field {
            store.chipBackspace = nil
        }
    }

    func commit() {
        let t = currentToken(text)
        guard !t.isEmpty else { return }
        text = (committed.map(\.formatted) + [t]).map { $0 + ", " }.joined()
    }

    func remove(_ i: Int) {
        var list = committed.map(\.formatted)
        list.remove(at: i)
        text = list.map { $0 + ", " }.joined() + currentToken(text)
    }
}
