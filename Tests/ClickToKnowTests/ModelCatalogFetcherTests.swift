import XCTest

@testable import ClickToKnow

/// 模型目录拉取：四种协议的路径 / 鉴权头 / 响应解析；不发真实网络请求。
final class ModelCatalogFetcherTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func makeFetcher() -> ModelCatalogFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ModelCatalogFetcher(session: URLSession(configuration: configuration))
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func respond(_ body: String, status: Int = 200) {
        MockURLProtocol.responder = { request in
            (self.httpResponse(status: status, url: request.url!), Data(body.utf8))
        }
    }

    func testOpenAICompatibleParsesDataIDs() async throws {
        respond(#"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#)
        let models = try await makeFetcher().fetch(
            baseURL: "https://api.deepseek.com", apiKey: "sk", apiProtocol: .openAICompatible
        )
        XCTAssertEqual(models, ["deepseek-chat", "deepseek-reasoner"])
    }

    func testAnthropicHitsV1ModelsWithAnthropicHeaders() async throws {
        var captured: URLRequest?
        MockURLProtocol.responder = { request in
            captured = request
            let body = #"{"data":[{"id":"claude-haiku-4-5"}]}"#
            return (self.httpResponse(status: 200, url: request.url!), Data(body.utf8))
        }
        let models = try await makeFetcher().fetch(
            baseURL: "https://api.anthropic.com", apiKey: "sk-ant", apiProtocol: .anthropic
        )
        XCTAssertEqual(models, ["claude-haiku-4-5"])
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    /// Gemini：去掉 models/ 前缀，且过滤不支持 generateContent 的模型（如嵌入模型）
    func testGeminiStripsPrefixAndFiltersNonGenerativeModels() async throws {
        respond(#"""
        {"models":[
          {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]}
        ]}
        """#)
        let models = try await makeFetcher().fetch(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gkey", apiProtocol: .gemini
        )
        XCTAssertEqual(models, ["gemini-2.5-flash", "gemini-2.5-pro"])
    }

    func testResultsAreSortedAndDeduplicated() async throws {
        respond(#"{"data":[{"id":"b-model"},{"id":"a-model"},{"id":"b-model"}]}"#)
        let models = try await makeFetcher().fetch(
            baseURL: "https://api.example.com/v1", apiKey: "sk", apiProtocol: .openAICompatible
        )
        XCTAssertEqual(models, ["a-model", "b-model"])
    }

    func testInvalidBaseURLFailsAsBadConfiguration() async {
        do {
            _ = try await makeFetcher().fetch(
                baseURL: "ftp://bad", apiKey: "sk", apiProtocol: .openAICompatible
            )
            XCTFail("预期抛 badConfiguration")
        } catch let error as InterpretationError {
            guard case .badConfiguration = error else {
                return XCTFail("预期 badConfiguration，实际 \(error)")
            }
        } catch {
            XCTFail("预期 InterpretationError，实际 \(error)")
        }
    }

    func testUnauthorizedPropagatesServerError() async {
        respond(#"{"error":{"message":"invalid key"}}"#, status: 401)
        do {
            _ = try await makeFetcher().fetch(
                baseURL: "https://api.example.com/v1", apiKey: "bad", apiProtocol: .openAICompatible
            )
            XCTFail("预期抛 server 错误")
        } catch let error as InterpretationError {
            guard case .server(let detail) = error else {
                return XCTFail("预期 server 错误，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("401"), "实际文案：\(detail)")
        } catch {
            XCTFail("预期 InterpretationError，实际 \(error)")
        }
    }
}
