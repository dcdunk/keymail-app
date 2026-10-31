import Foundation

// MARK: Packages (shipping emails → a list of deliveries)
// Everything comes from the emails on this Mac: nothing is sent to a carrier or any tracking service.

public enum ShipStage: Int, Comparable, Codable, Sendable {
    case ordered = 1, shipped, outForDelivery, delivered
    public static func < (a: ShipStage, b: ShipStage) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["", "Ordered", "Shipped", "Out for delivery", "Delivered"][rawValue] }
}

public enum Carrier: String, CaseIterable, Sendable {
    case ups, fedex, usps, amazon, dhl
    public var name: String { ["ups": "UPS", "fedex": "FedEx", "usps": "USPS", "amazon": "Amazon", "dhl": "DHL"][rawValue]! }
    /// The carrier's own tracking page. Built from the number, never taken from a link in the email.
    public func trackURL(_ number: String) -> URL? {
        let n = number.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? number
        switch self {
        case .ups: return URL(string: "https://www.ups.com/track?tracknum=\(n)")
        case .fedex: return URL(string: "https://www.fedex.com/fedextrack/?trknbr=\(n)")
        case .usps: return URL(string: "https://tools.usps.com/go/TrackConfirmAction?tLabels=\(n)")
        case .dhl: return URL(string: "https://www.dhl.com/us-en/home/tracking.html?tracking-id=\(n)")
        case .amazon: return URL(string: "https://www.amazon.com/progress-tracker/package?trackingId=\(n)")
        }
    }
    /// Emails the carrier itself sends ("UPS Ship Notification").
    static func from(domain: String) -> Carrier? {
        ["ups.com": .ups, "fedex.com": .fedex, "usps.com": .usps, "dhl.com": .dhl][domain]
    }
}

/// What one email says about a delivery.
public struct ShipEvent: Equatable, Sendable {
    public var messageKey: String
    public var date: Date
    public var stage: ShipStage
    public var store: String          // sender's name ("Amazon.com", "Bonobos"); a carrier's name for carrier emails
    public var storeEmail: String
    public var domain: String         // sender's company site, groups one store's order emails
    public var carrier: Carrier?
    public var tracking: String?
    public var order: String?
    public var item: String?
    public var eta: Date?             // the day it's expected (start of day)
    public var fromCarrier: Bool
}

public struct Package: Identifiable, Equatable, Sendable {
    public var id: String
    public var events: [ShipEvent]    // oldest first
    public var stage: ShipStage
    public var store: String, storeEmail: String
    public var carrier: Carrier?
    public var tracking: String?
    public var order: String?
    public var item: String?
    public var eta: Date?
    public var updated: Date { events.last?.date ?? .distantPast }
    public var latest: ShipEvent { events[events.count - 1] }
    /// What the list shows as its name: the item, or the order number when the email never names it.
    public var title: String { item ?? order.map { "Order \($0)" } ?? "Package from \(store)" }
    public var trackURL: URL? {
        if let tracking, let carrier { return carrier.trackURL(tracking) }
        // Amazon's own order page, on amazon.com, for orders whose emails carry no tracking number.
        if let order, isAmazon {
            return URL(string: "https://www.amazon.com/gp/your-account/order-details?orderID=\(order)")
        }
        return nil
    }
    public func isLate(now: Date = Date(), calendar cal: Calendar = .current) -> Bool {
        stage < .delivered && eta.map { $0 < cal.startOfDay(for: now) } == true && !probablyDelivered(now: now, calendar: cal)
    }
    /// No "delivered" email ever came (Amazon often skips it), but it's 3 days past due: it almost certainly arrived.
    /// Due means the expected day, the out-for-delivery day, or a week after shipping when no date was given.
    public func probablyDelivered(now: Date = Date(), calendar cal: Calendar = .current) -> Bool {
        guard stage == .shipped || stage == .outForDelivery else { return false }
        let due = stage == .outForDelivery ? updated : eta ?? updated.addingTimeInterval(7 * 86400)
        return cal.startOfDay(for: now) > cal.startOfDay(for: due).addingTimeInterval(3 * 86400)
    }
    /// Amazon's own emails carry no tracking number: the order page on amazon.com is the way to track those.
    public var isAmazon: Bool { storeEmail.hasSuffix("@amazon.com") || storeEmail.hasSuffix(".amazon.com") }
    public func arrivesToday(now: Date = Date(), calendar cal: Calendar = .current) -> Bool {
        guard stage < .delivered else { return false }
        if let eta { return cal.isDate(eta, inSameDayAs: now) }
        return stage == .outForDelivery && cal.isDate(updated, inSameDayAs: now)
    }
}

// MARK: Reading one email

/// Subject phrases, strongest first. The subject decides whether an email is about a delivery at all: a body alone
/// ("tracking" in a billing email, "on the way" in an ad) is too weak.
private let stagePhrases: [(ShipStage, [String])] = [
    (.outForDelivery, ["out for delivery"]),
    (.delivered, ["^delivered", "\\bhas been delivered", "\\bwas delivered", "\\bis delivered", "\\bdelivered:", "\\bdelivery confirmation", "ups delivery notification"]),
    (.shipped, ["\\bshipped\\b", "\\bon (?:the|its) way", "\\bon the move\\b", "ship notification", "shipping confirmation", "\\bshipment\\b", "\\bin transit\\b", "tracking number", "has shipped"]),
    (.ordered, ["order (?:is )?confirm", "\\bconfirmed\\b", "thanks for your order", "thank you for your order", "order received", "received your order", "^ordered:", "order placed"]),
]

func stage(ofSubject s: String) -> ShipStage? {
    let low = s.lowercased()
    if low.contains("will be delivered") || low.contains("free shipping") { return nil }
    return stagePhrases.first { $0.1.contains { low.range(of: $0, options: .regularExpression) != nil } }?.0
}

private func first(_ pattern: String, in text: String, group: Int = 1, options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.range(at: group).location != NSNotFound else { return nil }
    return ns.substring(with: m.range(at: group))
}

/// A tracking number and its carrier. Patterns with a fixed prefix (1Z, TBA, JD, 92/93/94/95) stand on their own;
/// FedEx's plain 12 or 15 digits only count when the email says FedEx, since order numbers look the same.
func trackingNumber(in text: String) -> (String, Carrier)? {
    if let n = first("\\b(1Z(?:\\s?[0-9A-Z]){16})\\b", in: text, options: []) { return (n.filter { !$0.isWhitespace }, .ups) }
    if let n = first("\\b(TBA\\s?\\d{3}(?:\\s?\\d){9})\\b", in: text, options: []) { return (n.filter { !$0.isWhitespace }, .amazon) }
    if let n = first("\\b(JD\\s?\\d{2}(?:\\s?\\d){14,16})\\b", in: text, options: []) { return (n.filter { !$0.isWhitespace }, .dhl) }
    if let n = first("\\b(9[2-5]\\d{2}(?:\\s?\\d{4}){4}\\s?\\d{2,6})\\b", in: text, options: []) {
        let digits = n.filter(\.isNumber)
        if (20...26).contains(digits.count) { return (digits, .usps) }
    }
    let low = text.lowercased()
    if low.contains("fedex"), let n = first("(?:tracking|track)[^0-9\\n]{0,40}\\b(\\d{12}|\\d{15}|\\d{4} \\d{4} \\d{4})\\b", in: text) {
        return (n.filter(\.isNumber), .fedex)
    }
    if low.contains("dhl"), let n = first("(?:tracking|track)[^0-9\\n]{0,40}\\b(\\d{10})\\b", in: text) { return (n, .dhl) }
    return nil
}

/// "Order #113-2992205-4573827", "Order BNBS592938", "order #5214006815". Needs a digit, so "Order summary" isn't one.
func orderNumber(in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: "\\border\\s*(?:#|no\\.?|number)?\\s*:?\\s*\\n?\\s*#?([A-Z0-9][A-Z0-9-]{3,24})\\b", options: [.caseInsensitive]) else { return nil }
    let ns = text as NSString
    for m in re.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 20_000))) {
        let n = ns.substring(with: m.range(at: 1))
        if n.contains(where: \.isNumber), n.filter(\.isNumber).count >= 3 { return n }
    }
    return nil
}

/// The item, from subjects like `Shipped 1 item: Jackets` or `Shipped: "Kirkland Signature..." and 1 more item`,
/// else the first "Name × 1" line of the body (Shopify's shipping emails).
func itemName(subject: String, body: String) -> String? {
    if let colon = subject.range(of: ": ") {
        let head = subject[..<colon.lowerBound].lowercased()
        if ["shipped", "delivered", "out for delivery", "ordered", "arriving"].contains(where: { head.hasPrefix($0) }) {
            var s = String(subject[colon.upperBound...]).replacingOccurrences(of: "&quot;", with: "\"")
            let more = first(#"\s+and (\d+) more items?$"#, in: s)
            if let r = s.range(of: #"\s+and \d+ more items?$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
            s = s.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return more.map { "\(s) + \($0) more" } ?? s }
        }
    }
    for line in body.split(whereSeparator: \.isNewline).prefix(400) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let name = first("^(.{3,80}?)\\s+[×x]\\s*\\d{1,3}$", in: t, options: []), name.contains(where: \.isLetter) { return name }
    }
    return nil
}

private let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
private let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

/// When it's expected, read relative to the email's own date ("Arriving Saturday" in an email from Thursday).
func expectedDate(in text: String, sent: Date, calendar cal: Calendar = .current) -> Date? {
    guard let phrase = first("(?:arriving|arrives|estimated delivery|expected delivery|delivery date|expected by|deliver(?:ed|y)? by|scheduled delivery)\\s*(?:date)?\\s*:?\\s*([^\\n]{0,40}(?:\\n\\s*[^\\n]{0,40})?)", in: text) else { return nil }
    let p = phrase.lowercased().replacingOccurrences(of: "\n", with: " ")
    let day = cal.startOfDay(for: sent)
    // A date written out wins over a weekday: "Tuesday 11/03/2026".
    if let m = first("\\b(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\b", in: p, group: 0, options: []) {
        let parts = m.split(separator: "/").compactMap { Int($0) }
        var c = DateComponents(); c.month = parts[0]; c.day = parts[1]
        c.year = parts.count > 2 ? (parts[2] < 100 ? 2000 + parts[2] : parts[2]) : cal.component(.year, from: sent)
        if let d = cal.date(from: c) { return parts.count > 2 || d >= day.addingTimeInterval(-86400 * 30) ? d : cal.date(byAdding: .year, value: 1, to: d) }
    }
    for (i, name) in months.enumerated() {
        if let dayNum = first("\\b\(name)[a-z]*\\.?\\s+(\\d{1,2})\\b", in: p, options: []).flatMap(Int.init) {
            var c = DateComponents(); c.month = i + 1; c.day = dayNum; c.year = cal.component(.year, from: sent)
            if let d = cal.date(from: c) { return d < day.addingTimeInterval(-86400 * 60) ? cal.date(byAdding: .year, value: 1, to: d) : d }
        }
    }
    if p.hasPrefix("today") { return day }
    if p.hasPrefix("tomorrow") { return cal.date(byAdding: .day, value: 1, to: day) }
    if let w = weekdays.firstIndex(where: { p.hasPrefix($0) || p.hasPrefix(String($0.prefix(3)) + " ") }) {
        let ahead = (w + 1 - cal.component(.weekday, from: day) + 7) % 7
        return cal.date(byAdding: .day, value: ahead, to: day)
    }
    return nil
}

/// Reads one email. nil when it isn't about a delivery, or when it can't be trusted: spam and forged senders
/// ("your package is held, pay the fee") never make the list.
public func shippingEvent(_ m: Message, calendar cal: Calendar = .current) -> ShipEvent? {
    guard let stage = stage(ofSubject: m.subject), !m.labelIds.contains("SPAM"), !m.labelIds.contains("SENT"),
          !m.labelIds.contains("DRAFT"), m.authFailed != true,
          let from = parseAddresses(m.from).first, let domain = logoDomain(for: from.email) else { return nil }
    // Plain text plus the raw HTML: tracking numbers often sit only inside a link (…trackNums=1Z…).
    let body = String(m.plainText.prefix(60_000)), hay = m.subject + "\n" + body + "\n" + String((m.html ?? "").prefix(200_000))
    let track = trackingNumber(in: hay)
    let order = orderNumber(in: m.subject) ?? orderNumber(in: body)
    let carrierSender = Carrier.from(domain: domain)
    // An email that names no order and no tracking number is an ad ("Summer is on the way"), not a delivery.
    guard track != nil || order != nil || carrierSender != nil else { return nil }
    return ShipEvent(messageKey: m.key, date: m.date, stage: stage,
                     store: carrierSender?.name ?? (from.name.isEmpty ? domain : from.name), storeEmail: from.email.lowercased(), domain: domain,
                     carrier: track?.1 ?? carrierSender, tracking: track?.0, order: order,
                     item: itemName(subject: m.subject, body: body), eta: expectedDate(in: body, sent: m.date, calendar: cal).map(cal.startOfDay),
                     fromCarrier: carrierSender != nil)
}

// MARK: Grouping into packages

/// Joins one delivery's emails: the same tracking number, or the same order from the same store.
/// A store's "shipped" email and the carrier's own email meet through the tracking number.
/// ponytail: one package per order when no tracking number is shown; an order shipped in several boxes reads as one.
public func packages(from events: [ShipEvent]) -> [Package] {
    var groups: [[ShipEvent]] = [], byTrack: [String: Int] = [:], byOrder: [String: Int] = [:]
    for e in events.sorted(by: { $0.date < $1.date }) {
        let ok = e.order.map { e.domain + "|" + $0 }
        let byT = e.tracking.flatMap { byTrack[$0] }, byO = ok.flatMap { byOrder[$0] }
        let i = byT ?? byO ?? { groups.append([]); return groups.count - 1 }()
        // This email links two packages seen so far (the carrier's email by tracking number, the order confirmation
        // by order number): they're one package.
        if let j = byO, j != i {
            groups[i] += groups[j]; groups[j] = []
            for (k, v) in byTrack where v == j { byTrack[k] = i }
            for (k, v) in byOrder where v == j { byOrder[k] = i }
        }
        groups[i].append(e)
        if let t = e.tracking { byTrack[t] = byTrack[t] ?? i }
        if let ok { byOrder[ok] = byOrder[ok] ?? i }
    }
    return groups.filter { !$0.isEmpty }.map { $0.sorted { $0.date < $1.date } }.map { evs in
        let shop = evs.last { !$0.fromCarrier } ?? evs[evs.count - 1]
        let tracked = evs.last { $0.tracking != nil }
        let id = tracked?.tracking ?? shop.order.map { "\(shop.domain)|\($0)" } ?? evs[0].messageKey
        return Package(id: id, events: evs, stage: evs.map(\.stage).max()!,
                       store: shop.store, storeEmail: shop.storeEmail,
                       carrier: tracked?.carrier ?? evs.last { $0.carrier != nil }?.carrier,
                       tracking: tracked?.tracking, order: evs.last { $0.order != nil }?.order,
                       item: evs.first { $0.item != nil }?.item, eta: evs.last { $0.eta != nil }?.eta)
    }
}
