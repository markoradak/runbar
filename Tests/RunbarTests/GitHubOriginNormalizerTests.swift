import XCTest
@testable import Runbar

final class GitHubOriginNormalizerTests: XCTestCase {
    func testSupportedGitHubOriginsNormalizeTable() {
        let cases: [(String, String?)] = [
            ("git@github.com:Owner/Repo.git", "Owner/Repo"),
            ("https://github.com/owner/repo.git", "owner/repo"),
            ("https://github.com/owner/repo", "owner/repo"),
            ("ssh://git@github.com/owner/repo.git", "owner/repo"),
            ("git@gitlab.com:owner/repo.git", nil),
            ("https://github.com.evil.example/owner/repo.git", nil),
            ("http://github.com/owner/repo.git", nil),
            ("https://user@github.com/owner/repo.git", nil),
            ("https://github.com/owner/repo/extra", nil),
            ("git@github.com:owner", nil)
        ]

        for (origin, expected) in cases {
            XCTAssertEqual(
                GitHubOriginNormalizer.normalize(origin)?.fullName,
                expected,
                "Unexpected normalization for \(origin)"
            )
        }
    }
}
