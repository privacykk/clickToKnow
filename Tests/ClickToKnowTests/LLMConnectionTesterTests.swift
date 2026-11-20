import XCTest

@testable import ClickToKnow

/// 拦截全部请求并按 responder 返回，用于覆盖连接测试各分支（不发真实网络请求）
final class MockURLProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LLMConnectionTesterTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    /// 给被测 Provider 注入 mock session（两个协议的 Provider 构造器都自带 session 注入口）
    private func makeTester() -> LLMConnectionTester {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return LLMConnectionTester { config, apiProtocol in
            switch apiProtocol {
            case .openAICompatible:
                return OpenAICompatProvider(config: config, session: session)
            case .anthropic:
                return AnthropicProvider(config: config, session: session)
            }
        }
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testSuccessReportsLatency() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "test-model"
        )
        guard case .success(let latencyMs) = result else {
            return XCTFail("预期成功，实际 \(result)")
        }
        XCTAssertGreaterThanOrEqual(latencyMs, 0)
    }

    func testSuccessSendsMinimalChatCompletionBody() async {
        var capturedBody: Data?
        MockURLProtocol.responder = { request in
            capturedBody = TestHelpers.bodyData(of: request)
            return (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        _ = await makeTester().test(
            baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "m1"
        )
        guard let body = capturedBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("未捕获到请求体")
        }
        XCTAssertEqual(json["model"] as? String, "m1")
        XCTAssertEqual(json["max_tokens"] as? Int, 1)
    }

    func testUnauthorizedIsClassifiedAsInvalidKey() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 401, url: request.url!),
             Data(#"{"error":{"message":"invalid api key"}}"#.utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://api.example.com/v1", apiKey: "sk-bad", model: "m"
        )
        guard case .failure(let reason) = result else {
            return XCTFail("预期失败，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("密钥无效"), "实际文案：\(reason)")
    }

    func testNotFoundIsClassifiedAsModelOrPath() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 404, url: request.url!),
             Data(#"{"error":"model not found"}"#.utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "nope"
        )
        guard case .failure(let reason) = result else {
            return XCTFail("预期失败，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("模型或路径不存在"), "实际文案：\(reason)")
    }

    func testNetworkErrorUsesHumanHint() async {
        MockURLProtocol.responder = { _ in throw URLError(.cannotFindHost) }
        let result = await makeTester().test(
            baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "m"
        )
        guard case .failure(let reason) = result else {
            return XCTFail("预期失败，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("找不到主机"), "实际文案：\(reason)")
    }

    func testMissingFieldsFailFastWithoutRequest() async {
        // responder 返回 200：若校验未短路，结果会是 success 而非 failure
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let result = await makeTester().test(baseURL: "", apiKey: "", model: "")
        guard case .failure(let reason) = result else {
            return XCTFail("预期校验拦截，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("请先填写"), "实际文案：\(reason)")
    }

    func testInvalidBaseURLFailsAsBadConfiguration() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let result = await makeTester().test(baseURL: "ftp://bad", apiKey: "sk", model: "m")
        guard case .failure(let reason) = result else {
            return XCTFail("预期失败，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("配置无效"), "实际文案：\(reason)")
    }

    /// Anthropic 协议应打到 /v1/messages，并用 x-api-key + anthropic-version 头鉴权（而非 Bearer）
    func testAnthropicProtocolUsesMessagesEndpointAndHeaders() async {
        var captured: URLRequest?
        MockURLProtocol.responder = { request in
            captured = request
            return (self.httpResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://api.anthropic.com", apiKey: "sk-ant-test", model: "claude-haiku-4-5",
            apiProtocol: .anthropic
        )
        guard case .success = result else {
            return XCTFail("预期成功，实际 \(result)")
        }
        let request = try? XCTUnwrap(captured)
        XCTAssertEqual(request?.url?.path, "/v1/messages")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
    }

    /// Anthropic 协议下 401 同样归类为「密钥无效」
    func testAnthropicUnauthorizedIsClassifiedAsInvalidKey() async {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: 401, url: request.url!),
             Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://api.anthropic.com", apiKey: "bad", model: "claude-haiku-4-5",
            apiProtocol: .anthropic
        )
        guard case .failure(let reason) = result else {
            return XCTFail("预期失败，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("密钥无效"), "实际文案：\(reason)")
    }
}
