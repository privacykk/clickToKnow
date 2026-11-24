import XCTest

@testable import ClickToKnow

/// 错误正文脱敏（评审问题 9）：服务端错误体可能回显密钥或用户输入，
/// 既不能原样进弹窗，也不能原样进日志。
final class ServerErrorRedactionTests: XCTestCase {
    private func detail(_ status: Int, _ body: String) -> String {
        LLMProviderSupport.serverDetail(status: status, data: Data(body.utf8))
    }

    /// OpenAI 风格错误：保留可定位问题的 type/code/message，但不透传其中的密钥
    func test_openAIErrorKeepsCodeButRedactsKey() {
        let body = """
        {"error":{"type":"invalid_request_error","code":"invalid_api_key",\
        "message":"Incorrect API key provided: sk-live-abcdef1234567890"}}
        """
        let result = detail(401, body)
        XCTAssertTrue(result.hasPrefix("HTTP 401 "))
        XCTAssertTrue(result.contains("invalid_api_key"), "状态码与错误码要保留，否则无法自查")
        XCTAssertTrue(result.contains("invalid_request_error"))
        XCTAssertFalse(result.contains("sk-live-abcdef1234567890"), "密钥不得出现在摘要里")
        XCTAssertTrue(result.contains("***"))
    }

    /// Bearer 头与长凭证同样打码
    func test_redactsBearerAndLongTokens() {
        let body = #"{"message":"bad header Authorization: Bearer abcdef1234567890.xyz"}"#
        let result = detail(403, body)
        XCTAssertFalse(result.contains("abcdef1234567890.xyz"))

        let longToken = String(repeating: "a1b2c3d4", count: 5) // 40 字符
        XCTAssertFalse(detail(500, longToken).contains(longToken))
    }

    /// HTML 错误页（第三方代理常见）：不留标签结构，长度受控
    func test_htmlBodyIsFlattenedAndBounded() {
        let html = "<html><script>alert(1)</script><body>" + String(repeating: "服务暂不可用 ", count: 60) + "</body></html>"
        let result = detail(502, html)
        XCTAssertTrue(result.hasPrefix("HTTP 502"))
        XCTAssertFalse(result.contains("<script>"), "控制字符与标签噪声不该原样展示")
        XCTAssertLessThanOrEqual(result.count, LLMProviderSupport.serverDetailLimit + "HTTP 502 ".count + 1)
    }

    /// 按 Character 截断：不得切出半个 UTF-8 字符（旧实现按字节 prefix(240) 会切出 U+FFFD）
    func test_truncatesByCharacterNotByte() {
        let body = String(repeating: "载荷均衡", count: 100)
        let result = detail(500, body)
        XCTAssertFalse(result.contains("\u{FFFD}"), "不应出现替换符")
        XCTAssertFalse(result.isEmpty)
        // 每个汉字 3 字节，按字节截断必然落在字符中间；这里应恰好是 limit 个字符 + 省略号
        let payload = result.replacingOccurrences(of: "HTTP 500 ", with: "")
        XCTAssertEqual(payload.count, LLMProviderSupport.serverDetailLimit + 1)
        XCTAssertTrue(payload.hasSuffix("…"))
    }

    /// 非 UTF-8 字节序列：不能崩，也不能把替换符塞进提示
    func test_invalidUTF8BytesDoNotLeakReplacementChars() {
        var data = Data([0xFF, 0xFE, 0x00, 0x41])
        data.append(Data("error: bad request".utf8))
        let result = LLMProviderSupport.serverDetail(status: 400, data: data)
        XCTAssertFalse(result.contains("\u{FFFD}"))
        XCTAssertTrue(result.contains("bad request"))
    }

    /// 空响应体：只给状态码，不出现「HTTP 500 」这种空尾巴
    func test_emptyBodyYieldsStatusOnly() {
        XCTAssertEqual(LLMProviderSupport.serverDetail(status: 500, data: Data()), "HTTP 500")
        XCTAssertEqual(LLMProviderSupport.serverDetail(status: 500, data: Data("   ".utf8)), "HTTP 500")
    }

    /// 纯文本 body（非 JSON）：走清洗分支而不是丢掉全部信息
    func test_plainTextBodyStillSurvives() {
        XCTAssertEqual(detail(429, "rate limited, retry in 5s"), "HTTP 429 rate limited, retry in 5s")
    }

    /// 日志分类只带状态码，不含正文
    func test_logCategoryKeepsStatusOnly() {
        let error = LLMProviderSupport.serverError(
            status: 401,
            data: Data(#"{"error":{"message":"key sk-abcdef123456 leaked"}}"#.utf8)
        )
        XCTAssertEqual(error.logCategory, "server(status=401)")
        XCTAssertFalse(error.logCategory.contains("sk-"))
        XCTAssertEqual(InterpretationError.badConfiguration.logCategory, "badConfiguration")
        XCTAssertEqual(InterpretationError.notFound.logCategory, "notFound")
        XCTAssertEqual(InterpretationError.badResponse.logCategory, "badResponse")
    }
}