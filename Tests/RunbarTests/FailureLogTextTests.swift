import XCTest
@testable import Runbar

final class FailureLogTextTests: XCTestCase {
    func testStripsANSIEscapeSequences() {
        XCTAssertEqual(
            FailureLogText.stripANSI("\u{1B}[31mFAIL\u{1B}[0m src/index.test.ts"),
            "FAIL src/index.test.ts"
        )
        XCTAssertEqual(FailureLogText.stripANSI("plain line"), "plain line")
    }

    func testStripsGitHubTimestampPrefixAndTrailingWhitespace() {
        XCTAssertEqual(
            FailureLogText.stripTimestamp("2026-07-16T12:34:56.7890123Z npm ERR! code 1\r"),
            "npm ERR! code 1"
        )
        XCTAssertEqual(
            FailureLogText.stripTimestamp("2026-07-16T12:34:56Z done"),
            "done"
        )
        XCTAssertEqual(
            FailureLogText.stripTimestamp("no timestamp here"),
            "no timestamp here"
        )
    }

    func testTailKeepsLastLinesAndDropsTrailingBlanks() {
        let text = (1...40).map { "2026-07-16T00:00:00Z line \($0)" }.joined(separator: "\n") + "\n\n\n"
        let tail = FailureLogText.tail(text, maxLines: 5)
        XCTAssertEqual(tail, ["line 36", "line 37", "line 38", "line 39", "line 40"])
    }

    func testTailOfLineArrayNormalizesEachLine() {
        let lines = ["\u{1B}[32mok\u{1B}[0m", "2026-01-01T00:00:00.000Z error: boom", ""]
        XCTAssertEqual(FailureLogText.tail(lines, maxLines: 10), ["ok", "error: boom"])
    }

    func testFailureTailCutsAtLastErrorMarkerAndPrettifiesCommands() {
        let text = """
        2026-07-16T12:00:00Z ##[group]Run pnpm --filter landing deploy
        2026-07-16T12:00:00Z pnpm --filter landing deploy
        2026-07-16T12:00:00Z ##[endgroup]
        2026-07-16T12:00:01Z  ERR_PNPM_INVALID_DEPLOY_TARGET  This command requires one parameter
        2026-07-16T12:00:01Z ##[error]Process completed with exit code 1.
        2026-07-16T12:00:02Z Post job cleanup.
        2026-07-16T12:00:02Z [command]/usr/bin/git config --local --unset-all
        2026-07-16T12:00:03Z Cleaning up orphan processes
        2026-07-16T12:00:03Z ##[warning]Node.js 20 is deprecated.
        """
        XCTAssertEqual(
            FailureLogText.failureTail(text, maxLines: 10),
            [
                "Run pnpm --filter landing deploy",
                "pnpm --filter landing deploy",
                " ERR_PNPM_INVALID_DEPLOY_TARGET  This command requires one parameter",
                "Error: Process completed with exit code 1."
            ]
        )
    }

    func testFailureTailWithoutErrorMarkerFallsBackToPlainTail() {
        let text = "2026-07-16T12:00:00Z line one\n2026-07-16T12:00:01Z line two\n"
        XCTAssertEqual(FailureLogText.failureTail(text, maxLines: 1), ["line two"])
    }
}
