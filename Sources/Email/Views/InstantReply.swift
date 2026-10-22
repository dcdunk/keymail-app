import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Instant reply

struct InstantReplyBar: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    let conversation: Conversation
    var body: some View {
        let options = store.instantReplies[conversation.id]
        HStack(spacing: 8) {
            if let options {
                ForEach(Array(options.enumerated()), id: \.offset) { i, text in
                    Button { store.useInstantReply(i) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(i + 1)").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                            Text(text).lineLimit(2).multilineTextAlignment(.leading)
                        }.font(.scaled(.callout)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if store.instantLoading == conversation.id {
                ProgressView().controlSize(.small)
                Text("\(store.ai.name) is writing replies…").font(.scaled(.callout)).foregroundStyle(.secondary)
                Spacer()
            }
            // The Instant reply button lives in the email's AI tools above; this row only holds the replies it writes.
        }
        .padding(.horizontal, layout.compact ? 16 : 40).padding(.bottom, options == nil && store.instantLoading != conversation.id ? 0 : 8)
    }
}
