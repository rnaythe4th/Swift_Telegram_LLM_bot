import XCTest
@testable import LLM_chat_bot

/// Callback routing: what a button carries, and what the dispatcher makes of
/// it. Before `MenuRoute` the only thing tying a button to its handler was a
/// string literal in two places — a typo produced a button that silently did
/// nothing, and nothing but a user could find it.
final class MenuRouteTests: XCTestCase {

    // MARK: - Parsing

    func testUnknownCommandDoesNotParse() {
        XCTAssertNil(MenuRoute(action: "definitely-not-a-command"))
        XCTAssertNil(MenuRoute(action: "NAV"), "commands are case-sensitive, as they are on the wire")
        XCTAssertNil(MenuRoute(action: ":"))
    }

    /// An empty payload is the bare `menu:` button — the main page.
    func testEmptyActionOpensTheMenu() {
        XCTAssertEqual(MenuRoute(action: "")?.command, .open)
    }

    func testArgumentsAreReadByPosition() throws {
        let route = try XCTUnwrap(MenuRoute(action: "stenant:ext:#4242"))
        XCTAssertEqual(route.command, .stenant)
        XCTAssertEqual(route.sub, "ext")
        XCTAssertEqual(route.userKey(2), UserKey.identified(4242))
        XCTAssertNil(route.arg(3))
    }

    func testIntArgumentRejectsGarbage() {
        XCTAssertEqual(MenuRoute(action: "pm:model:edit:3")?.int(3), 3)
        XCTAssertNil(MenuRoute(action: "pm:model:edit:x")?.int(3))
        XCTAssertNil(MenuRoute(action: "pm:model:edit")?.int(3))
    }

    /// A payload that lost its tail must read as missing, not as an argument
    /// that happens to be empty — `removeTenant("")` is not a request
    /// anyone made.
    func testEmptyArgumentReadsAsMissing() throws {
        let route = try XCTUnwrap(MenuRoute(action: "stenant:rmyes:"))
        XCTAssertNil(route.arg(2))
        XCTAssertEqual(MenuRoute(action: "nav:")?.sub, "")
        XCTAssertNil(MenuRoute(action: "nav:")?.page(1))
    }

    // MARK: - Round trip

    /// Every page must survive being turned into a link and parsed back. This
    /// is the half the compiler cannot check on its own: `navigation(to:)`
    /// writes the raw value, `page(1)` reads it.
    func testEveryPageRoundTripsThroughItsLink() throws {
        for page in MenuPage.allCases {
            let link = MenuRoute.navigation(to: page)
            let route = try XCTUnwrap(MenuRoute(action: link), "\(page) produced an unroutable link: \(link)")
            XCTAssertEqual(route.command, .nav)
            XCTAssertEqual(route.page(1), page, "\(page) did not survive the round trip")
        }
    }

    func testEveryPurchaseSourceRoundTrips() throws {
        for source in PurchaseSource.allCases {
            let link = MenuRoute.purchase(from: source)
            let route = try XCTUnwrap(MenuRoute(action: link))
            XCTAssertEqual(route.page(1), .pay)
            XCTAssertEqual(PurchaseSource.parse(route.arg(2)), source, "source lost on the way to the funnel")
        }
    }

    /// Preset categories reuse the settings pages. The mapping is spelled out
    /// in `MenuPage(category:)` precisely so a renamed page breaks the build —
    /// this checks the mapping still lands on a real page.
    func testPresetCategoriesMapToRealPages() throws {
        for category in [PresetCategory.model, .temp, .history, .role] {
            let link = MenuRoute.navigation(to: MenuPage(category: category))
            let route = try XCTUnwrap(MenuRoute(action: link))
            XCTAssertNotNil(route.page(1), "\(category) points at no page")
        }
    }
}
