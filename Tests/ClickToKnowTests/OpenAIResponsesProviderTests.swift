import XCTest

@testable import ClickToKnow

/// OpenAI Responses API：请求打 /responses、instructions 为顶层字段；
/// 响应从 output[] 中取第一个 message 项的 output_text（前面可能混有 reasoning 项）。
final class OpenAIResponsesProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    /// 构造走 MockURLProtocol 的被测 Provider
    private func makeProvider() -> OpenAIResponsesProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OpenAIResponsesProvider(
            config: .init(baseURL: "https://api.openai.com/v1", apiKey: "sk-test", model: "gpt-4o-mini"),
            session: URLSession(configuration: configuration)
        )
    }

    /// 构造指定状态码的 HTTP 响应（mock responder 用）
    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testInterpretHitsResponsesEndpointWithInstructions() async throws {
        var captured: URLRequest?
        MockURLProtocol.responder = { request in
            captured = request
            let body = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"释义"}]}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        _ = try await makeProvider().interpret("helm")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(TestHelpers.bodyData(of: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertNotNil(json["instructions"] as? String, "instructions 应为顶层字段")
        XCTAssertNotNil(json["input"] as? String)
    }

    func testInterpretSkipsReasoningItemsAndReadsOutputText() async throws {
        MockURLProtocol.responder = { request in
            let body = """
            {"output":[
              {"type":"reasoning","summary":[]},
              {"type":"message","content":[{"type":"output_text","text":"**含义**：包管理器"}]}
            ]}
            """
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        let result = try await makeProvider().interpret("helm")
        XCTAssertEqual(result.content, "**含义**：包管理器")
        XCTAssertEqual(result.source, .llm)
    }

    func testInterpretWithoutMessageItemIsBadResponse() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!),
             Data(#"{"output":[{"type":"reasoning","summary":[]}]}"#.utf8))
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

    func testPingTreats200AsSuccess() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let latency = try? await makeProvider().ping()
        XCTAssertNotNil(latency)
    }
}
