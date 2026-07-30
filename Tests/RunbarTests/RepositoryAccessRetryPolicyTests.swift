import Foundation
import XCTest
@testable import Runbar

final class RepositoryAccessRetryPolicyTests: XCTestCase {
    private let deniedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testBackoffEscalatesOneHourSixHoursThenDailyCap() {
        XCTAssertEqual(
            RepositoryAccessRetryPolicy.nextRetryAt(deniedAt: deniedAt, denialCount: 1),
            deniedAt.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            RepositoryAccessRetryPolicy.nextRetryAt(deniedAt: deniedAt, denialCount: 2),
            deniedAt.addingTimeInterval(6 * 60 * 60)
        )
        XCTAssertEqual(
            RepositoryAccessRetryPolicy.nextRetryAt(deniedAt: deniedAt, denialCount: 3),
            deniedAt.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(
            RepositoryAccessRetryPolicy.nextRetryAt(deniedAt: deniedAt, denialCount: 12),
            deniedAt.addingTimeInterval(24 * 60 * 60),
            "Repeated denials cap at the daily interval"
        )
    }

    func testRetryBecomesDueOnlyAfterTheWindowElapses() {
        let preference = RepositoryPreference(
            isExcluded: false,
            isAccessible: false,
            accessDeniedAt: deniedAt,
            accessDenialCount: 1
        )
        XCTAssertFalse(RepositoryAccessRetryPolicy.isRetryDue(
            preference: preference,
            now: deniedAt.addingTimeInterval(60 * 60 - 1)
        ))
        XCTAssertTrue(RepositoryAccessRetryPolicy.isRetryDue(
            preference: preference,
            now: deniedAt.addingTimeInterval(60 * 60)
        ))
    }

    func testAccessibleRepositoryIsNeverDue() {
        XCTAssertFalse(RepositoryAccessRetryPolicy.isRetryDue(
            preference: .defaults,
            now: .distantFuture
        ))
    }

    func testLegacyDenialWithoutTimestampIsDueImmediately() {
        let preference = RepositoryPreference(isExcluded: false, isAccessible: false)
        XCTAssertTrue(RepositoryAccessRetryPolicy.isRetryDue(preference: preference, now: deniedAt))
    }
}
