import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Command palette

struct PaletteView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool
    var body: some View {
        let list = store.filteredCommands
        VStack(spacing: 0) {
            TextField("Type a command, or \"remind friday 3pm\"…", text: $store.paletteText)
                .textFieldStyle(.plain).font(.system(size: 18)).focused($focused)
                .padding(18)
                .onChange(of: store.paletteText) { _, _ in store.paletteIndex = 0 }
                .onAppear { focused = true }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            HStack {
                                Text(c.title)
                                Spacer()
                                if !c.key.isEmpty { Text(c.key).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(i == store.paletteIndex ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { store.runPalette(i) }
                            .id(i)
                        }
                        if list.isEmpty { Text("No matching command").foregroundStyle(.secondary).padding(20) }
                    }.padding(8)
                }
                .onChange(of: store.paletteIndex) { _, i in proxy.scrollTo(i) }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 600)
        .floatingPanel(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .fixedSize(horizontal: false, vertical: true)
    }
}
