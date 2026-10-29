import XCTest
import MomentCoreScenarios

final class MomentCoreTests: XCTestCase {
    @MainActor
    func testAllScenarios() async {
        let failures = await Scenarios.runAll()
        XCTAssertEqual(failures, 0, "see the FAIL lines in the log")
    }
}
