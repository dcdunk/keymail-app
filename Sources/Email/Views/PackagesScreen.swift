import SwiftUI
import EmailCore

/// Packages (G P, ⌘K): deliveries found in your shipping emails. The list on the left, the chosen package on the right.
struct PackagesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout

    var body: some View {
        let sections = store.packageSections, shown = sections.flatMap(\.packages), current = store.currentPackage
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if shown.isEmpty {
                    Text(store.packageFilter == .delivered ? "Nothing delivered in the last 14 days."
                         : "No packages on the way. They show up here when a store or carrier emails that something shipped.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(sections) { s in
                                    HStack(spacing: 8) {
                                        Text(s.title).textCase(.uppercase).tracking(0.6)
                                        if let note = s.note { Text(note).foregroundStyle(.tertiary) }
                                    }
                                    .font(.scaled(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                                    ForEach(s.packages) { p in
                                        PackageRow(p: p, current: p.id == current?.id).id(p.id)
                                            .onTapGesture { store.packageIndex = shown.firstIndex { $0.id == p.id } ?? 0 }
                                    }
                                }
                            }
                            .padding(.horizontal, layout.margin)
                        }
                        .onChange(of: store.packageIndex) { _, i in if shown.indices.contains(i) { proxy.scrollTo(shown[i].id) } }
                    }
                    .frame(maxWidth: .infinity)
                    if let current, !layout.compact {
                        PackageDetail(p: current).frame(width: 330).padding(.trailing, layout.margin).padding(.bottom, 8)
                    }
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 4) { KeyHint("J"); KeyHint("K"); Text("move") }
                HStack(spacing: 4) { KeyHint("↵"); Text("open email") }
                HStack(spacing: 4) { KeyHint("T"); Text("track on carrier site") }
                HStack(spacing: 4) { KeyHint("C"); Text("copy tracking number") }
                HStack(spacing: 4) { KeyHint("E"); Text("mark received") }
                HStack(spacing: 4) { KeyHint("Tab"); Text("next tab") }
                Spacer()
            }
            .font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, layout.margin + 14).padding(.vertical, 12)
        }
    }
}

/// Green when delivered, orange when late, the app's blue otherwise.
func packageColor(_ p: Package) -> Color {
    p.stage == .delivered ? .green : p.probablyDelivered() ? .secondary : p.isLate() ? .orange : Theme.accent
}

@MainActor func packageStatus(_ p: Package, store: AppStore) -> String {
    if p.stage == .delivered { return store.state.packagesReceived[p.id] != nil ? "Received" : "Delivered" }
    if p.probablyDelivered() { return "Probably delivered" }
    return p.isLate() ? "Running late" : p.stage.label
}

/// Next to the store's name when no carrier is known.
func noCarrierNote(_ p: Package) -> String {
    p.stage == .ordered ? "not shipped yet" : p.isAmazon ? "tracked on Amazon" : "no tracking number"
}

/// "Today", "Tomorrow", "Mon, Nov 3".
func arrivalDay(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

struct PackageRow: View {
    @EnvironmentObject var store: AppStore
    let p: Package, current: Bool
    @State private var hovering = false

    var body: some View {
        let color = packageColor(p)
        HStack(spacing: 14) {
            Avatar(address: Address(name: p.store, email: p.storeEmail), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.scaled(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(p.store).lineLimit(1)
                    Text("·")
                    if let c = p.carrier { CarrierLogo(carrier: c, height: 15); Text(c.name) } else { Text(noCarrierNote(p)) }
                }
                .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach(1...4, id: \.self) { s in Capsule().fill(s <= p.stage.rawValue ? color : Color.primary.opacity(0.12)).frame(height: 4) }
                }
                Text(packageStatus(p, store: store)).font(.scaled(size: 12, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 150)
            ZStack(alignment: .trailing) {
                VStack(alignment: .trailing, spacing: 1) {
                    if p.stage == .delivered {
                        Text(store.deliveredDate(p).map(arrivalDay) ?? "Delivered").font(.scaled(size: 13, weight: .semibold))
                        Text(store.state.packagesReceived[p.id] != nil ? "marked by you" : "delivered").font(.scaled(.caption)).foregroundStyle(.secondary)
                    } else if p.probablyDelivered() {
                        Text(arrivalDay(p.eta ?? p.updated)).font(.scaled(size: 13, weight: .semibold))
                        Text("no delivered email").font(.scaled(.caption)).foregroundStyle(.secondary)
                    } else if let eta = p.eta {
                        Text(arrivalDay(eta)).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(p.isLate() ? Color.orange : .primary)
                        Text(p.isLate() ? "was expected" : "expected").font(.scaled(.caption)).foregroundStyle(.secondary)
                    } else {
                        Text("No date yet").font(.scaled(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .opacity(hovering ? 0 : 1)
                HStack(spacing: 2) {
                    if p.trackURL != nil { quick("arrow.up.right.square", "Track (T)") { store.trackPackage(p) } }
                    if p.tracking != nil { quick("doc.on.doc", "Copy tracking number (C)") { store.copyTracking(p) } }
                    quick("envelope", "Open email (↵)") { store.openPackageEmail(p) }
                    if p.stage < .delivered { quick("checkmark", "Mark received (E)") { store.toggleReceived(p) } }
                }
                .opacity(hovering ? 1 : 0)
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(p.stage == .delivered && !current ? 0.7 : 1)
        .background(RoundedRectangle(cornerRadius: 10).fill(current ? Theme.selection : hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    func quick(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).font(.scaled(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(ToolStyle()).help(help).accessibilityLabel(String(help.prefix { $0 != "(" }))
    }
}

struct PackageDetail: View {
    @EnvironmentObject var store: AppStore
    let p: Package

    var body: some View {
        let color = packageColor(p), received = store.state.packagesReceived[p.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Avatar(address: Address(name: p.store, email: p.storeEmail), size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.scaled(size: 14, weight: .semibold)).lineLimit(2)
                        Text("Ordered from \(p.store)").font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.scaled(size: 21, weight: .bold)).foregroundStyle(color)
                    Text(subline).font(.scaled(size: 13)).foregroundStyle(.secondary)
                }
                if let c = p.carrier, let t = p.tracking {
                    HStack(spacing: 10) {
                        CarrierLogo(carrier: c, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(c.name) tracking").font(.scaled(size: 11)).foregroundStyle(.secondary)
                            Text(t).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer(minLength: 4)
                        Button("Copy") { store.copyTracking(p) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.scaled(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
                } else if p.tracking == nil {
                    Text(p.stage == .ordered ? "The tracking number shows here once \(p.store) emails that it shipped."
                         : p.isAmazon ? "Amazon's emails don't include a tracking number. Track it on Amazon instead."
                         : "\(p.store)'s emails don't include a tracking number.")
                        .font(.scaled(size: 12)).foregroundStyle(.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
                }
                FlowButtons(p: p, received: received != nil)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Progress").textCase(.uppercase).tracking(0.6).font(.scaled(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    ForEach([ShipStage.ordered, .shipped, .outForDelivery, .delivered], id: \.self) { s in step(s, color: color, received: received) }
                }
                Divider()
                Text(freshness).font(.scaled(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .glass(RoundedRectangle(cornerRadius: 14))
    }

    var headline: String {
        if p.stage == .delivered { return store.state.packagesReceived[p.id] != nil ? "Received" : "Delivered" }
        if p.probablyDelivered() { return "Probably delivered" }
        if p.isLate() { return "Running late" }
        if p.arrivesToday() { return "Arriving today" }
        return p.stage == .ordered ? "Ordered" : "On the way"
    }

    var subline: String {
        if p.stage == .delivered { return store.deliveredDate(p).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "" }
        if p.probablyDelivered() { return "No delivered email came, but it was due \(arrivalDay(p.eta ?? p.updated).lowercased()). Press E if it's here." }
        if p.isLate(), let eta = p.eta { return "Expected \(arrivalDay(eta)). No update since \(arrivalDay(p.updated))." }
        if p.stage == .outForDelivery { return "Out for delivery" }
        if p.arrivesToday() { return "Shipped, due today" }
        if let eta = p.eta { return "Expected \(arrivalDay(eta))" }
        return p.stage == .ordered ? "Not shipped yet" : "No delivery date in the emails yet"
    }

    var freshness: String {
        var s = "From \(p.store)'s emails. Last update \(p.updated.formatted(date: .abbreviated, time: .shortened))."
        if p.stage < .delivered, let c = p.carrier, p.tracking != nil { s += " For live status, open \(c.name)'s page." }
        return s
    }

    /// One step of the timeline. Steps that happened link to the email that said so.
    func step(_ s: ShipStage, color: Color, received: Date?) -> some View {
        let e = p.events.last { $0.stage == s }
        let done = s <= p.stage, isNext = s.rawValue == p.stage.rawValue + 1
        let when: String? = s == .delivered && received != nil ? "Marked by you, \(arrivalDay(received!))" : e.map { arrivalDay($0.date) }
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(done ? color : .clear).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(done ? color : Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: isNext ? [2, 2] : [])))
                    .padding(.top, 2)
                if s != .delivered { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.label).font(.scaled(size: 12.5, weight: done ? .semibold : .regular)).foregroundStyle(done ? .primary : .secondary)
                HStack(spacing: 4) {
                    if done, let when { Text(when) }
                    if done, let e {
                        Text("·")
                        Button("from email") { openEvent(e) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    } else if isNext, s == .delivered, !p.isLate() { Text("Waiting for the delivered email") }
                }
                .font(.scaled(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func openEvent(_ e: ShipEvent) {
        guard let c = store.allConversations.first(where: { $0.messages.contains { $0.key == e.messageKey } }) else { return }
        store.closeTool(); store.open(c)
    }
}

private struct FlowButtons: View {
    @EnvironmentObject var store: AppStore
    let p: Package, received: Bool
    var body: some View {
        // Track gets its own row: three buttons side by side don't fit the panel's width.
        VStack(alignment: .leading, spacing: 6) {
            if p.trackURL != nil {
                Button { store.trackPackage(p) } label: {
                    HStack(spacing: 6) { Text("Track on \(p.carrier?.name ?? p.store)").lineLimit(1); KeyHint("T") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
            HStack(spacing: 6) {
                Button { store.openPackageEmail(p) } label: { Text("Open email").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                if p.stage < .delivered || received {
                    Button { store.toggleReceived(p) } label: { Text(received ? "Not received" : "Mark received").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
        }
        .controlSize(.large)
    }
}

/// A carrier's official mark on its brand-color tile. FedEx, DHL and USPS are lettering, so their tile is twice as
/// wide and the mark is cropped to it: in a square they'd be unreadable at row size.
struct CarrierLogo: View {
    let carrier: Carrier
    var height: CGFloat = 16
    static let tiles: [Carrier: Color] = [
        .ups: Color(red: 0.08, green: 0.02, blue: 0.0), .fedex: .white, .usps: Color(red: 0.20, green: 0.20, blue: 0.40),
        .amazon: Color(red: 0.14, green: 0.18, blue: 0.24), .dhl: Color(red: 1.0, green: 0.80, blue: 0.0),
    ]
    var body: some View {
        let wide = [Carrier.fedex, .dhl, .usps].contains(carrier), w = wide ? height * 2 : height
        let shape = RoundedRectangle(cornerRadius: height * 0.25)
        shape.fill(Self.tiles[carrier] ?? .gray).frame(width: w, height: height)
            .overlay(BrandLogo(brand: carrier.rawValue, size: wide ? w * 0.88 : height * 0.72))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
            .help(carrier.name).accessibilityLabel(carrier.name)
    }
}
