import XCTest

@testable import ClickToKnow

/// Gemini generateContent API：路径带模型名、x-goog-api-key 鉴权、
/// systemInstruction 顶层字段、响应取 candidates[0].content.parts[].text。
final class GeminiProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    /// 构造走 MockURLProtocol 的被测 Provider
    private func makeProvider() -> GeminiProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return GeminiProvider(
            config: .init(
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                apiKey: "gkey", model: "gemini-2.5-flash"
            ),
            session: URLSession(configuration: configuration)
        )
    }

    /// 构造指定状态码的 HTTP 响应（mock responder 用）
    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testInterpretURLContainsModelAndGenerateContent() async throws {
        var captured: URLRequest?
        MockURLProtocol.responder = { request in
            captured = request
            let body = #"{"candidates":[{"content":{"parts":[{"text":"释义"}]}}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        _ = try await makeProvider().interpret("helm")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(
            request.url?.path,
            "/v1beta/models/gemini-2.5-flash:generateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gkey")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(TestHelpers.bodyData(of: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["systemInstruction"], "systemInstruction 应为顶层字段")
    }

    func testInterpretJoinsMultipleParts() async throws {
        MockURLProtocol.responder = { request in
            let body = #"{"candidates":[{"content":{"parts":[{"text":"**含义**"},{"text":"：包管理器"}]}}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        let result = try await makeProvider().interpret("helm")
        XCTAssertEqual(result.content, "**含义**：包管理器")
    }

    func testInterpretWithoutCandidatesIsBadResponse() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        do {
            _ = try await makeProvider().interpret("helm")
            XCTFail("预期抛 badResponse")
        } catch let error as InterpretationError {
            guard case .badResponse = error else {
                return XCTFail("预期 badResponse，实际 \(error)")
            }
        } catch {
            XCTFail("预期 InterpretationError，实际 \(error)")
        }
    }

    /// maxOutputTokens=1 截断时 candidates 可能为空，ping 只认 200，不按释义口径判 badResponse
    func testPingTreats200WithEmptyCandidatesAsSuccess() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let latency = try? await makeProvider().ping()
        XCTAssertNotNil(latency)
    }
}
