import XCTest
@testable import DoCleanCore

final class SelfTestTests: XCTestCase {
    func testSelfTestHasNoFailures() async {
        let t = await SelfTest.run()
        XCTAssertGreaterThan(t.checks.count, 200)
        XCTAssertTrue(t.failures.isEmpty, t.failures.map { "\($0.name) \($0.detail)" }.joined(separator: "\n"))
    }
}
