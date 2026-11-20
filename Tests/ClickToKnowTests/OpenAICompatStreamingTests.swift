import XCTest

@testable import ClickToKnow

/// OpenAI 兼容 Provider 的 SSE 流式解析与上下文传递。
/// MockURLProtocol 一次返回全量 SSE 报文，bytes.lines 逐行解析路径与真实流式一致。
@MainActor
final class OpenAICompatStreamingTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func makeProvider() -> OpenAICompatProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OpenAICompatProvider(
            config: .init(baseURL: "https://api.deepseek.com", apiKey: "sk-test", model: "deepseek-chat"),
            session: URLSession(configuration: configuration)
        )
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testStreamingAccumulatesDeltas() async throws {
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"},"index":0}]}

        data: {"choices":[{"delta":{"content":"**音标**"},"index":0}]}

        data: {"choices":[{"delta":{"content":"：/helm/"},"index":0}]}

        data: [DONE]

        """
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data(sse.utf8))
        }

        var deltas: [String] = []
        let result = try await makeProvider().interpretStreaming("helm", context: nil) { partial in
            deltas.append(partial)
        }
        XCTAssertEqual(result.content, "**音标**：/helm/")
        // 首个 chunk 只有 role 无 content，不应产生 delta；之后每次回调都是累积正文
        XCTAssertEqual(deltas, ["**音标**", "**音标**：/helm/"])
    }

    func testStreamingRequestEnablesStreamAndCarriesContext() async throws {
        var capturedBody: Data?
        MockURLProtocol.responder = { request in
            capturedBody = TestHelpers.bodyData(of: request)
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
            return (self.httpResponse(status: 200, url: request.url!), Data(sse.utf8))
        }
        _ = try await makeProvider().interpretStreaming("helm", context: "在 Kubernetes 中用 helm 安装 chart") { _ in }

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let userMessage = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(userMessage.contains("\"helm\""), "实际：\(userMessage)")
        XCTAssertTrue(userMessage.contains("在 Kubernetes 中用 helm 安装 chart"), "实际：\(userMessage)")
    }

    /// 流式路径的非 2xx：收集错误响应体，抛出含状态码与片段的 server 错误（401 定位密钥问题靠它）
    func testStreamingNon200ThrowsServerError() async throws {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 401, url: request.url!), Data(#"{"error":{"message":"invalid key"}}"#.utf8))
        }
        do {
            _ = try await makeProvider().interpretStreaming("helm", context: nil) { _ in }
            XCTFail("预期抛 server 错误")
        } catch let error as InterpretationError {
            guard case .server(let detail) = error else {
                return XCTFail("预期 server，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("401"), "实际：\(detail)")
            XCTAssertTrue(detail.contains("invalid key"), "实际：\(detail)")
        }
    }

    /// 非流式整包路径同样携带上下文
    func testInterpretCarriesContext() async throws {
        var capturedBody: Data?
        MockURLProtocol.responder = { request in
            capturedBody = TestHelpers.bodyData(of: request)
            let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        _ = try await makeProvider().interpret("helm", context: "容器编排段落")
        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertTrue(messages.last?["content"]?.contains("容器编排段落") == true)
    }

    /// 空流（无任何 delta）视为坏响应
    func testStreamingEmptyThrowsBadResponse() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("data: [DONE]\n\n".utf8))
        }
        do {
            _ = try await makeProvider().interpretStreaming("helm", context: nil) { _ in }
            XCTFail("预期抛 badResponse")
        } catch let error as InterpretationError {
            guard case .badResponse = error else {
                return XCTFail("预期 badResponse，实际 \(error)")
            }
        } catch {
            XCTFail("预期 InterpretationError，实际 \(error)")
        }
    }
}
