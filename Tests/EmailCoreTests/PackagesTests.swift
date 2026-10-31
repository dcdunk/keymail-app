import XCTest
@testable import EmailCore

/// Packages: shipping emails become deliveries. Shapes follow real store and carrier emails, with made-up details.
final class PackagesTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()
    func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))! }

    func m(_ id: String, _ from: String, _ subject: String, _ text: String, at: Date, labels: [String] = ["INBOX"], html: String? = nil) -> Message {
        var msg = Message(id: id, threadId: id, account: "me@example.com", from: from, to: "me@example.com", subject: subject,
                          date: at, labelIds: labels, html: html, text: text)
        msg.authFailed = false
        return msg
    }
    func event(_ msg: Message) -> ShipEvent? { shippingEvent(msg, calendar: cal) }

    // A Thursday, so "Arriving Saturday" means Oct 31.
    lazy var thu = day(2026, 10, 29)

    func testAmazonShippedEmailGivesItemOrderAndArrivalDay() throws {
        let e = try XCTUnwrap(event(m("a1", "\"Amazon.com\" <shipment-tracking@amazon.com>", "Shipped 1 item: Jackets",
            "Your package was shipped!\nOrdered\nShipped\nOut for delivery\nDelivered\n\nArriving Saturday\n\nSam - SAN DIEGO, CA\n\nOrder #\n113-1234567-7654321\n\nTrack package", at: thu)))
        XCTAssertEqual(e.stage, .shipped)
        XCTAssertEqual(e.item, "Jackets")
        XCTAssertEqual(e.order, "113-1234567-7654321", "the number on the line after \"Order #\"")
        XCTAssertEqual(e.eta, day(2026, 10, 31, 0), "Saturday after the Thursday it was sent")
        XCTAssertEqual(e.store, "Amazon.com")
    }

    func testAmazonSubjectsNameTheItemAndHowManyMore() {
        XCTAssertEqual(itemName(subject: "Out for delivery: \"Victoria Cast Iron Tortilla...\" and 3 more items", body: ""), "Victoria Cast Iron Tortilla… + 3 more")
        XCTAssertEqual(itemName(subject: "Shipped: \"Kirkland Signature H.K...\"", body: ""), "Kirkland Signature H.K…")
        XCTAssertEqual(itemName(subject: "Delivered 5 items: Electronics, Health Care, and more", body: ""), "Electronics, Health Care, and more")
    }

    func testStageComesFromTheSubject() {
        XCTAssertEqual(stage(ofSubject: "Out for delivery: \"Mug\""), .outForDelivery)
        XCTAssertEqual(stage(ofSubject: "Delivered 1 item: Pet Supplies"), .delivered)
        XCTAssertEqual(stage(ofSubject: "Your package has been delivered!"), .delivered)
        XCTAssertEqual(stage(ofSubject: "UPS Ship Notification, Tracking Number 1Z999AA10123456784"), .shipped)
        XCTAssertEqual(stage(ofSubject: "A shipment from order BNBS100200 is on the way"), .shipped)
        XCTAssertEqual(stage(ofSubject: "Order #66695 confirmed"), .ordered)
        XCTAssertEqual(stage(ofSubject: "Your order's on the move"), .shipped, "a store's own wording for shipped")
        XCTAssertNil(stage(ofSubject: "Important update on Bitbucket billing"))
        XCTAssertNil(stage(ofSubject: "Free shipping on everything this weekend"))
        XCTAssertNil(stage(ofSubject: "Your order will be delivered by a new partner"), "news about delivery isn't a delivery")
    }

    func testShopifyStoreEmailsAndTheCarriersOwnEmailBecomeOnePackage() {
        let ordered = m("s1", "Bonobos <guides@bonobos.com>", "Order BNBS100200 confirmed",
                        "Order BNBS100200\nThank you for your order! We're getting your order ready to be shipped.", at: day(2026, 9, 19))
        let shipped = m("s2", "Bonobos <guides@bonobos.com>", "A shipment from order BNBS100200 is on the way",
                        "Order BNBS100200\nYour order is on the way.\n\nUPS tracking number: 1ZGG87300253405954\n\nItems in this shipment\n----\n\nJetsetter Wool Dress Pant × 1\n\n33 / Tailored / 30",
                        at: day(2026, 9, 20))
        let ups = m("s3", "\"UPS\" <mcinfo@ups.com>", "UPS Ship Notification, Tracking Number 1ZGG87300253405954",
                    "Your package is on the way!\n\n   Estimated Delivery\n\n   Tuesday 09/22/2026\n by 9:00 PM\n\nUPS Ground\n1ZGG87300253405954", at: day(2026, 9, 20, 18))
        let delivered = m("s4", "\"UPS\" <mcinfo@ups.com>", "Your UPS Package was delivered", "Tracking Number 1ZGG87300253405954", at: day(2026, 9, 22, 15))
        let ps = packages(from: [delivered, ups, shipped, ordered].compactMap(event))
        XCTAssertEqual(ps.count, 1, "order number joins the store's emails, tracking number joins the carrier's")
        let p = ps[0]
        XCTAssertEqual(p.stage, .delivered)
        XCTAssertEqual(p.store, "Bonobos", "the store, not the carrier, even though UPS wrote last")
        XCTAssertEqual(p.carrier, .ups); XCTAssertEqual(p.tracking, "1ZGG87300253405954")
        XCTAssertEqual(p.item, "Jetsetter Wool Dress Pant", "from the \"Name × 1\" line")
        XCTAssertEqual(p.eta, day(2026, 9, 22, 0), "the date written out wins over the weekday")
        XCTAssertEqual(p.events.map(\.stage), [.ordered, .shipped, .shipped, .delivered], "oldest first")
        XCTAssertEqual(p.trackURL?.host, "www.ups.com", "tracking opens the carrier's own site")
    }

    func testCarrierEmailFirstThenTheStoresStillMakeOnePackage() {
        // Real order: the carrier's email arrived before the store's shipping email.
        let ordered = m("n1", "The Normal Brand <thebear@thenormalbrand.com>", "Your order is confirmed!", "Order #906005", at: day(2026, 10, 28))
        let ups = m("n2", "\"UPS\" <mcinfo@ups.com>", "UPS Ship Notification, Tracking Number 1Z6714930347554281", "1Z6714930347554281", at: day(2026, 10, 29, 20))
        let moving = m("n3", "The Normal Brand <thebear@thenormalbrand.com>", "Your order's on the move",
                       "Order #906005\nIn transit\n1Z6714930347554281", at: day(2026, 10, 29, 22))
        let ps = packages(from: [ordered, ups, moving].compactMap(event))
        XCTAssertEqual(ps.count, 1, "the store's email joins the order confirmation and the UPS email")
        XCTAssertEqual(ps.first?.events.count, 3)
        XCTAssertEqual(ps.first?.store, "The Normal Brand")
    }

    func testTrackingNumbersAndTheirCarriers() {
        XCTAssertEqual(trackingNumber(in: "UPS 1Z 999 AA1 01 2345 6784")?.1, .ups)
        XCTAssertEqual(trackingNumber(in: "UPS 1Z 999 AA1 01 2345 6784")?.0, "1Z999AA10123456784", "spaces dropped")
        XCTAssertEqual(trackingNumber(in: "USPS tracking: 9400 1112 0206 2345 6789 01")?.0, "9400111202062345678901")
        XCTAssertEqual(trackingNumber(in: "USPS tracking: 9400 1112 0206 2345 6789 01")?.1, .usps)
        XCTAssertEqual(trackingNumber(in: "Shipped with FedEx. Tracking number: 771234567890")?.1, .fedex)
        XCTAssertNil(trackingNumber(in: "Order number: 771234567890"), "12 digits without FedEx is an order number, not tracking")
        XCTAssertEqual(trackingNumber(in: "Amazon tracking ID TBA305177442900")?.1, .amazon)
        XCTAssertEqual(trackingNumber(in: "<a href=\"https://www.ups.com/WebTracking?trackNums=1ZGG87300253405954\">Track</a>")?.0, "1ZGG87300253405954",
                       "a number only inside a link still counts")
    }

    func testOrderNumbersNeedDigits() {
        XCTAssertEqual(orderNumber(in: "We shipped your order #5214006815."), "5214006815")
        XCTAssertEqual(orderNumber(in: "Order US6148606 shipped"), "US6148606")
        XCTAssertNil(orderNumber(in: "Order summary\nYour order is on the way"))
    }

    func testAdsSpamAndForgedSendersNeverBecomePackages() {
        XCTAssertNil(event(m("x1", "Shop <news@shop.example>", "Summer is on the way", "New arrivals for the season.", at: thu)),
                     "no order and no tracking number: an ad")
        XCTAssertNil(event(m("x2", "Atlassian <info@e.atlassian.com>", "Important update on Bitbucket billing", "usage tracking and billing", at: thu)))
        let scam = m("x3", "USPS <alerts@usps-redelivery.example>", "Your package is on the way: action needed",
                     "Tracking 9400 1112 0206 2345 6789 01. Pay $1.99 to release it.", at: thu, labels: ["SPAM"])
        XCTAssertNil(event(scam), "spam is skipped")
        var forged = scam; forged.labelIds = ["INBOX"]; forged.authFailed = true
        XCTAssertNil(event(forged), "a sender that failed SPF/DKIM/DMARC is skipped")
        XCTAssertNil(event(m("x4", "Me <me@example.com>", "Shipped your order #12345", "", at: thu, labels: ["SENT"])), "your own sent mail isn't a delivery")
    }

    func testArrivalDates() {
        let fri = day(2026, 10, 30)
        XCTAssertEqual(expectedDate(in: "Arriving today", sent: fri, calendar: cal), day(2026, 10, 30, 0))
        XCTAssertEqual(expectedDate(in: "Arriving tomorrow", sent: fri, calendar: cal), day(2026, 10, 31, 0))
        XCTAssertEqual(expectedDate(in: "Arriving Monday", sent: fri, calendar: cal), day(2026, 11, 2, 0), "the next Monday")
        XCTAssertEqual(expectedDate(in: "Expected delivery: Nov 3", sent: fri, calendar: cal), day(2026, 11, 3, 0))
        XCTAssertEqual(expectedDate(in: "Estimated delivery: January 4", sent: day(2026, 12, 28), calendar: cal), day(2027, 1, 4, 0),
                       "a January date in a December email is next year")
        XCTAssertNil(expectedDate(in: "A delivery driver may contact you", sent: fri, calendar: cal))
    }

    func testLateAndArrivingToday() {
        let shipped = m("l1", "\"Amazon.com\" <shipment-tracking@amazon.com>", "Shipped 1 item: Mug", "Arriving Saturday\nOrder #\n113-0000000-0000001", at: thu)
        let p = packages(from: [event(shipped)!])[0]
        XCTAssertTrue(p.arrivesToday(now: day(2026, 10, 31, 12), calendar: cal))
        XCTAssertFalse(p.isLate(now: day(2026, 10, 31, 23), calendar: cal), "not late on the day itself")
        XCTAssertTrue(p.isLate(now: day(2026, 11, 1, 8), calendar: cal), "late the day after, with no delivered email")
        XCTAssertEqual(p.trackURL?.host, "www.amazon.com", "no tracking number: Amazon's own order page")
        let done = m("l2", "\"Amazon.com\" <order-update@amazon.com>", "Delivered 1 item: Mug", "Order #\n113-0000000-0000001", at: day(2026, 11, 2))
        let both = packages(from: [event(shipped)!, event(done)!])
        XCTAssertEqual(both.count, 1, "shipment-tracking@ and order-update@ are the same store")
        XCTAssertFalse(both[0].isLate(now: day(2026, 11, 3), calendar: cal), "delivered is never late")
    }

    func testLongPastDueWithNoDeliveredEmailIsProbablyDelivered() {
        // Amazon sometimes never sends "Delivered". Out for delivery on Oct 17 and nothing since: it arrived.
        let out = m("p1", "\"Amazon.com\" <shipment-tracking@amazon.com>", "Out for delivery: \"Tortilla press\"",
                    "Arriving today\nOrder #\n113-0000000-0000002", at: day(2026, 10, 17))
        let p = packages(from: [event(out)!])[0]
        XCTAssertFalse(p.probablyDelivered(now: day(2026, 10, 19), calendar: cal), "two days on, still possible it's coming")
        XCTAssertTrue(p.isLate(now: day(2026, 10, 19), calendar: cal), "so it shows as late")
        XCTAssertTrue(p.probablyDelivered(now: day(2026, 10, 21), calendar: cal), "over three days past due: it came")
        XCTAssertFalse(p.isLate(now: day(2026, 10, 21), calendar: cal), "and it stops being called late")
        let ordered = m("p2", "Shop <orders@shop.example>", "Order #55501 confirmed", "Order #55501", at: day(2026, 10, 1))
        XCTAssertFalse(packages(from: [event(ordered)!])[0].probablyDelivered(now: day(2026, 10, 29), calendar: cal),
                       "never guessed for an order that hasn't shipped")
    }
}
