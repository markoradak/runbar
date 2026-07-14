import XCTest
@testable import Runbar

final class WorkflowYAMLParserTests: XCTestCase {
    private let parser = WorkflowYAMLParser()

    func testTopLevelNameAndTriggerShapesTable() throws {
        let cases: [(String, String, String, [String])] = [
            ("scalar.yml", "name: Build\non: push\n", "Build", ["push"]),
            ("flow.yaml", "name: Checks\non: [pull_request, push]\n", "Checks", ["pull_request", "push"]),
            (
                "mapping.yml",
                """
                name: Scheduled build
                on:
                  push:
                    branches: [main]
                  schedule:
                    - cron: '0 4 * * *'
                  workflow_dispatch:
                """,
                "Scheduled build",
                ["push", "schedule", "workflow_dispatch"]
            ),
            ("fallback.yml", "on: workflow_dispatch\n", "fallback", ["workflow_dispatch"])
        ]

        for (fileName, yaml, expectedName, expectedEvents) in cases {
            let metadata = try parser.parse(yaml: yaml, fileName: fileName)
            XCTAssertEqual(metadata.name, expectedName)
            XCTAssertEqual(metadata.events, expectedEvents)
        }
    }
}
