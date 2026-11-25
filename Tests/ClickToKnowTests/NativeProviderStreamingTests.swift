import XCTest

@testable import ClickToKnow

@MainActor
final class NativeProviderStreamingTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func stub(_ events: [String], validate: @escaping (URLRequest) throws -> Void = { _ in }) {
        MockURLProtocol.responder = { request in
            try validate(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(events.map { "data: \($0)\r\n\r\n" }.joined().utf8))
        }
    }

    func test_responsesStreamsOnlyOutputTextAndUsesSelectedTemplate() async throws {
        stub([
            #"{"type":"response.reasoning_summary_text.delta","delta":"hidden"}"#,
            #"{"type":"response.output_text.delta","delta":"Hello "}"#,
            #"{"type":"response.output_text.delta","delta":"world"}"#,
            #"{"type":"response.completed"}"#,
        ]) { request in
            let body = try XCTUnwrap(TestHelpers.bodyData(of: request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["stream"] as? Bool, true)
            XCTAssertEqual(payload["instructions"] as? String, ExplanationStyle.translation.prompt)
            XCTAssertEqual(payload["input"] as? String, "请翻译选中文本：\"你好\"")
        }
        let provider = OpenAIResponsesProvider(config: .init(
            baseURL: "https://api.openai.com/v1", apiKey: "test", model: "model", explanationStyle: .translation
        ), session: session())
        var deltas: [String] = []
        let result = try await provider.interpretStreaming("你好", context: nil) { deltas.append($0) }
        XCTAssertEqual(deltas, ["Hello ", "Hello world"])
        XCTAssertEqual(result.content, "Hello world")
    }

    func test_anthropicHandlesMessageDeltaWithoutBlockType() async throws {
        stub([
            #"{"type":"content_block_start","content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"释义"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let provider = AnthropicProvider(config: .init(
            baseURL: "https://api.anthropic.com", apiKey: "test", model: "model"
        ), session: session())
        let result = try await provider.interpretStreaming("word", context: nil) { _ in }
        XCTAssertEqual(result.content, "释义")
    }

    func test_geminiUsesSSEEndpointAndIgnoresThoughts() async throws {
        stub([
            #"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"词"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"义"}]},"finishReason":"STOP"}]}"#,
        ]) { request in
            XCTAssertEqual(request.url?.path, "/v1beta/models/model:streamGenerateContent")
            XCTAssertEqual(request.url?.query, "alt=sse")
        }
        let provider = GeminiProvider(config: .init(
            baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: "test", model: "model"
        ), session: session())
        let result = try await provider.interpretStreaming("word", context: nil) { _ in }
        XCTAssertEqual(result.content, "词义")
    }

    func test_incompleteResponsesStreamFails() async throws {
        stub([#"{"type":"response.output_text.delta","delta":"partial"}"#])
        let provider = OpenAIResponsesProvider(config: .init(
            baseURL: "https://api.openai.com/v1", apiKey: "test", model: "model"
        ), session: session())
        do {
            _ = try await provider.interpretStreaming("word", context: nil) { _ in }
            XCTFail("Expected an incomplete response to fail")
        } catch InterpretationError.badResponse {
            // A partial response cannot be saved as a completed explanation.
        }
    }
}
