import Foundation

/// The tail of a failed run's log, ready for compact display in the panel.
struct RunFailureLog: Equatable, Sendable {
    let jobName: String?
    let stepName: String?
    let lines: [String]
    let webURL: String
}

enum RunFailureLogState: Equatable, Sendable {
    case idle
    case loading
    case loaded(RunFailureLog)
    case failed(String)
}

/// Normalizes raw CI log text for display: strips ANSI escape sequences and
/// leading ISO timestamps, trims trailing whitespace, and keeps the last
/// `maxLines` non-empty-tail lines.
enum FailureLogText {
    static let defaultMaxLines = 30

    static func tail(_ text: String, maxLines: Int = defaultMaxLines) -> [String] {
        tail(text.components(separatedBy: "\n"), maxLines: maxLines)
    }

    /// Tail for GitHub job logs: the job log continues past the failing step
    /// with post-run/cleanup steps, so a plain tail shows teardown noise.
    /// GitHub marks failures with `##[error]` lines — cut the log at the last
    /// one so the tail ends exactly where the failure did, then prettify the
    /// workflow-command markers the way GitHub's own log viewer does.
    static func failureTail(_ text: String, maxLines: Int = defaultMaxLines) -> [String] {
        var lines = text.components(separatedBy: "\n").map { stripTimestamp(stripANSI($0)) }
        if let errorIndex = lines.lastIndex(where: { $0.hasPrefix("##[error]") }) {
            lines = Array(lines[...errorIndex])
        }
        var display = lines.compactMap(displayLine)
        while let last = display.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            display.removeLast()
        }
        return Array(display.suffix(maxLines))
    }

    /// Renders GitHub workflow-command lines the way the web UI does:
    /// `##[group]`/`[command]` prefixes are stripped, `##[error]`/`##[warning]`
    /// become readable labels, and pure structure lines are dropped.
    private static func displayLine(_ line: String) -> String? {
        if line.hasPrefix("##[endgroup]") || line.hasPrefix("##[debug]") { return nil }
        if line.hasPrefix("##[group]") { return String(line.dropFirst("##[group]".count)) }
        if line.hasPrefix("##[error]") { return "Error: " + line.dropFirst("##[error]".count) }
        if line.hasPrefix("##[warning]") { return "Warning: " + line.dropFirst("##[warning]".count) }
        if line.hasPrefix("[command]") { return String(line.dropFirst("[command]".count)) }
        return line
    }

    static func tail(_ rawLines: [String], maxLines: Int = defaultMaxLines) -> [String] {
        var lines = rawLines.map { stripTimestamp(stripANSI($0)) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return Array(lines.suffix(maxLines))
    }

    /// Removes ANSI CSI/OSC escape sequences (colors, cursor movement).
    static func stripANSI(_ line: String) -> String {
        line.replacing(#/\u{1B}(?:\[[0-9;?]*[A-Za-z]|\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\))/#, with: "")
    }

    /// Removes the leading ISO-8601 timestamp GitHub prefixes on every job
    /// log line ("2026-07-16T12:34:56.7890123Z ").
    static func stripTimestamp(_ line: String) -> String {
        var result = line
        if let match = result.prefixMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/#) {
            result.removeSubrange(match.range)
        }
        // Trailing whitespace/carriage returns make copied lines messy.
        while let last = result.unicodeScalars.last, last == "\r" || last == " " || last == "\t" {
            result.unicodeScalars.removeLast()
        }
        return result
    }
}
