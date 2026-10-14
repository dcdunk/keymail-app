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
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    let complete: (String) -> String?

    var committed: [Address] {
        var parts = text.components(separatedBy: ",")
        parts.removeLast()
        return parseAddresses(parts.joined(separator: ","))
    }

    var body: some View {
        let token = Binding<String>(
            get: { currentToken(text) },
            set: { new in
                let head = committed.map(\.formatted)
                if new.contains(",") || new.hasSuffix(" ") && new.contains("@") {
                    // Comma (or a space after a full address) turns the typed text into a chip.
                    let typed = new.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                    text = (head + (typed.isEmpty ? [] : [typed])).map { $0 + ", " }.joined()
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
                .font(.callout).padding(.leading, 3).padding(.trailing, 3).padding(.vertical, 2)
                .background(Capsule().fill(a.email.contains("@") ? Color.primary.opacity(0.07) : Color.red.opacity(0.15)))
                .help(a.email)
            }
            TextField(committed.isEmpty ? placeholder : "", text: token)
                .textFieldStyle(.plain).focused(focus, equals: field)
                .frame(minWidth: 120)
                .onSubmit { commit() }
                .onKeyPress(.tab) {
                    if let c = complete(text) { text = c; return .handled }
                    if !currentToken(text).isEmpty { commit(); return .handled }
                    return .ignored
                }
                .onKeyPress(.delete) {
                    guard currentToken(text).isEmpty, !committed.isEmpty else { return .ignored }
                    remove(committed.count - 1); return .handled
                }
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
