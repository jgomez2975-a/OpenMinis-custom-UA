import XCTest
@testable import Minis

final class BrowserUserAgentTests: XCTestCase {
    func testParsesNamedUserAgentProfileAsRawValue() {
        let input = BrowserActionInput.parse(from: """
        {"action":"set_user_agent","user_agent":"desktop_safari"}
        """)

        XCTAssertEqual(input?.action, .setUserAgent)
        XCTAssertEqual(input?.userAgent, "desktop_safari")
    }

    func testPreservesLiteralCustomUserAgent() {
        let literal = "Mozilla/5.0 CustomBrowser/1.0"
        let input = BrowserActionInput.parse(from: """
        {"action":"set_user_agent","user_agent":"\(literal)"}
        """)

        XCTAssertEqual(input?.action, .setUserAgent)
        XCTAssertEqual(input?.userAgent, literal)
    }
}
