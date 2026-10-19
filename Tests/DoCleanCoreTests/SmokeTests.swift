import XCTest
@testable import DoCleanCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(DoCleanCore.version.isEmpty)
    }

    func testRulesBundled() {
        XCTAssertNotNil(DoCleanCore.resourceBundle.url(forResource: "Rules", withExtension: nil))
    }
}
