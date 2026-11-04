import CantorCore
import XCTest

final class OperatorModeTests: XCTestCase {
    func testFullAnswersEveryKey() {
        for key in TransportKey.allCases {
            XCTAssertTrue(OperatorMode.full.answers(key), "\(key)")
        }
    }

    func testSimpleKeepsArmGoFadeDisarmAndTheWayOut() {
        let simple = OperatorMode.simple
        for key in [TransportKey.arm, .go, .fade, .disarm, .panic, .acknowledge] {
            XCTAssertTrue(simple.answers(key), "\(key)")
        }
        for key in [TransportKey.hold, .marker, .nudgeEnd, .audition] {
            XCTAssertFalse(simple.answers(key), "\(key) is an Advanced-only key")
        }
        XCTAssertFalse(simple.answers(.pointer), "the arrow keys go to the song list, which only selects")
    }
}
