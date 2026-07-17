import Foundation
import XCTest
@testable import Runbar

final class ExternalProviderClientTests: XCTestCase {
    func testVercelDiscoversPersonalAndTeamDeploymentsAndNormalizesStates() async throws {
        let transport = ProviderMockTransport(responses: [
            .json(#"{"user":{"username":"marco","email":"m@example.com"}}"#),
            .json(#"{"teams":[{"id":"team_1","slug":"studio","name":"Studio"}]}"#),
            .json(
                #"{"deployments":[{"uid":"dpl_build","name":"site","url":"site-a.vercel.app","inspectorUrl":"https://vercel.com/marco/site/dpl_build","created":1000000,"buildingAt":1001000,"state":"BUILDING","readyState":"BUILDING","projectId":"prj_site","target":"production","meta":{"githubCommitOrg":"owner","githubCommitRepo":"site","githubCommitSha":"abc","githubCommitRef":"main","githubCommitMessage":"Ship it"}}]}"#,
                headers: ["X-RateLimit-Remaining": "998", "X-RateLimit-Reset": "2000"]
            ),
            .json(
                #"{"deployments":[{"uid":"dpl_ready","name":"docs","url":"docs.vercel.app","created":900000,"buildingAt":901000,"ready":905000,"state":"READY","readyState":"READY","projectId":"prj_docs","target":"preview","meta":{"githubCommitOrg":"owner","githubCommitRepo":"docs","githubCommitSha":"def","githubCommitRef":"feature"}}]}"#
            )
        ])
        let client = VercelClient(
            transport: transport,
            baseURL: URL(string: "https://vercel.test")!,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let result = try await client.fetch(token: "secret-vercel-token")

        XCTAssertEqual(result.provider, .vercel)
        XCTAssertEqual(result.accountLabel, "marco")
        XCTAssertEqual(result.projectCount, 2)
        XCTAssertEqual(result.executions.count, 2)
        let building = try XCTUnwrap(result.executions.first(where: { $0.externalID == "dpl_build" }))
        XCTAssertEqual(building.status, "in_progress")
        XCTAssertNil(building.conclusion)
        XCTAssertEqual(building.repository.fullName, "owner/site")
        XCTAssertEqual(building.headSHA, "abc")
        XCTAssertEqual(building.environment, "Production")
        XCTAssertEqual(building.displayTitle, "Ship it")
        let ready = try XCTUnwrap(result.executions.first(where: { $0.externalID == "dpl_ready" }))
        XCTAssertEqual(ready.status, "completed")
        XCTAssertEqual(ready.conclusion, "success")

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-vercel-token"
        })
        XCTAssertNil(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "teamId" }))
        XCTAssertEqual(
            URLComponents(url: requests[3].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "teamId" })?.value,
            "team_1"
        )
    }

    func testVercelDropsAutoSkippedCancellationsButKeepsRealCancels() async throws {
        // Two CANCELED deployments: one auto-skipped (no buildingAt — Vercel's
        // ignored build step, hidden from its dashboard) and one canceled after
        // it started building. Only the latter should surface.
        let transport = ProviderMockTransport(responses: [
            .json(#"{"user":{"username":"marco","email":"m@example.com"}}"#),
            .json(#"{"teams":[]}"#),
            .json(#"{"deployments":[{"uid":"dpl_skipped","name":"landing","created":1000000,"state":"CANCELED","readyState":"CANCELED","projectId":"prj_landing","target":"production","meta":{"githubCommitOrg":"owner","githubCommitRepo":"monorepo","githubCommitRef":"main","githubCommitMessage":"unrelated change"}},{"uid":"dpl_realcancel","name":"landing","created":2000000,"buildingAt":2001000,"ready":2002000,"state":"CANCELED","readyState":"CANCELED","projectId":"prj_landing","target":"production","meta":{"githubCommitOrg":"owner","githubCommitRepo":"monorepo","githubCommitRef":"main","githubCommitMessage":"canceled mid-build"}}]}"#)
        ])
        let client = VercelClient(
            transport: transport,
            baseURL: URL(string: "https://vercel.test")!,
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        let result = try await client.fetch(token: "secret-vercel-token")

        XCTAssertEqual(result.executions.count, 1)
        XCTAssertNil(
            result.executions.first(where: { $0.externalID == "dpl_skipped" }),
            "an auto-skipped (never-built) cancellation should be dropped"
        )
        let real = try XCTUnwrap(result.executions.first(where: { $0.externalID == "dpl_realcancel" }))
        XCTAssertEqual(real.conclusion, "cancelled")
    }

    func testCloudflareDiscoversLatestPageDeploymentWithReadOnlyBearerToken() async throws {
        let transport = ProviderMockTransport(responses: [
            .json(#"{"success":true,"result":{"status":"active"}}"#),
            .json(#"{"success":true,"result":[{"id":"acc_1","name":"Acme"}]}"#),
            .json(
                #"{"success":true,"result":[{"name":"landing","source":{"config":{"owner":"owner","repo_name":"landing"}},"latest_deployment":{"id":"cf_dpl_1","url":"https://landing.pages.dev","environment":"production","created_on":"2026-07-15T18:00:00Z","modified_on":"2026-07-15T18:01:00Z","is_skipped":false,"latest_stage":{"name":"build","status":"active","started_on":"2026-07-15T18:00:05Z","ended_on":null},"deployment_trigger":{"metadata":{"branch":"main","commit_hash":"cafebabe","commit_message":"Deploy Pages"}}}}]}"#
            )
        ])
        let client = CloudflarePagesClient(
            transport: transport,
            baseURL: URL(string: "https://cloudflare.test/client/v4")!,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let result = try await client.fetch(token: "secret-cloudflare-token")

        XCTAssertEqual(result.provider, .cloudflarePages)
        XCTAssertEqual(result.accountLabel, "Acme")
        XCTAssertEqual(result.projectCount, 1)
        let deployment = try XCTUnwrap(result.executions.first)
        XCTAssertEqual(deployment.status, "in_progress")
        XCTAssertEqual(deployment.repository.fullName, "owner/landing")
        XCTAssertEqual(deployment.headSHA, "cafebabe")
        XCTAssertEqual(deployment.displayTitle, "Deploy Pages")
        XCTAssertEqual(deployment.environment, "Production")

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-cloudflare-token"
        })
        XCTAssertTrue(requests[2].url!.path.contains("/accounts/acc_1/pages/projects"))
    }

    func testProviderAuthenticationFailureIsExplicit() async {
        let transport = ProviderMockTransport(responses: [.status(401)])
        let client = VercelClient(transport: transport, baseURL: URL(string: "https://vercel.test")!)

        do {
            _ = try await client.fetch(token: "bad")
            XCTFail("Expected authentication failure")
        } catch let error as ProviderClientError {
            XCTAssertEqual(error, .authentication)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct ProviderMockResponse: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    static func json(_ value: String, headers: [String: String] = [:]) -> ProviderMockResponse {
        ProviderMockResponse(statusCode: 200, data: Data(value.utf8), headers: headers)
    }

    static func status(_ statusCode: Int) -> ProviderMockResponse {
        ProviderMockResponse(statusCode: statusCode, data: Data(), headers: [:])
    }
}

private actor ProviderMockTransport: ProviderTransport {
    private var queuedResponses: [ProviderMockResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [ProviderMockResponse]) {
        queuedResponses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queuedResponses.isEmpty else { throw ProviderClientError.transport }
        let value = queuedResponses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: value.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: value.headers
        )!
        return (value.data, response)
    }

    func requests() -> [URLRequest] { recordedRequests }
}
