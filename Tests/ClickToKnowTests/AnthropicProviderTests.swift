import XCTest

@testable import ClickToKnow

/// Anthropic Messages API 的响应解析：content 是按类型分块的数组，文本在 type=text 块里
final class AnthropicProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func makeProvider() -> AnthropicProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return AnthropicProvider(
            config: .init(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", model: "claude-haiku-4-5"),
            session: URLSession(configuration: configuration)
        )
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testInterpretParsesFirstTextBlock() async throws {
        MockURLProtocol.responder = { request in
            let body = #"{"content":[{"type":"text","text":"**音标**：/helm/\n- **领域**：Kubernetes"}],"stop_reason":"end_turn"}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        let result = try await makeProvider().interpret("helm")
        XCTAssertEqual(result.term, "helm")
        XCTAssertEqual(result.source, .llm)
        XCTAssertTrue(result.content.contains("/helm/"), "实际内容：\(result.content)")
    }

    func testInterpretStripsCodeFence() async throws {
        MockURLProtocol.responder = { request in
            let body = #"{"content":[{"type":"text","text":"```markdown\n**含义**：包管理器\n```"}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        let result = try await makeProvider().interpret("helm")
        XCTAssertEqual(result.content, "**含义**：包管理器")
    }

    func testInterpretWithoutTextBlockIsBadResponse() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data(#"{"content":[]}"#.utf8))
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

    /// Anthropic 的 max_tokens 为必填，释义请求的 body 必须携带，且 system 是顶层字段
    func testInterpretSendsSystemAsTopLevelField() async throws {
        var capturedBody: Data?
        MockURLProtocol.responder = { request in
            capturedBody = TestHelpers.bodyData(of: request)
            let body = #"{"content":[{"type":"text","text":"ok"}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        _ = try await makeProvider().interpret("helm")
        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["system"] as? String)
        XCTAssertNotNil(json["max_tokens"] as? Int)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
    }
}
