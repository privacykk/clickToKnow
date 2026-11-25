import Foundation

/// 读取 SSE 数据帧，协议实现负责解释事件并决定何时结束。
enum EventStream {
    enum Update {
        case append(String)
        case done(String = "")
        case skip
    }

    static func interpret(
        term: String,
        request: URLRequest,
        session: URLSession,
        decode: (Data) throws -> Update,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> Interpretation {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw InterpretationError.badResponse }
            guard (200...299).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 16_384 { break }
                }
                throw LLMProviderSupport.serverError(status: http.statusCode, data: data)
            }

            var result = ""
            var completed = false
            // AsyncBytes.lines 会跳过空行。逐字节保留帧边界和多行 data 字段。
            var line = Data()
            var fields: [String] = []
            for try await byte in bytes {
                if byte != 10 {
                    line.append(byte)
                    continue
                }
                try Task.checkCancellation()
                if line.last == 13 { line.removeLast() }
                if line.isEmpty {
                    if try await apply(fields, to: &result, decode: decode, onDelta: onDelta) {
                        completed = true
                        break
                    }
                    fields.removeAll(keepingCapacity: true)
                } else if let field = dataField(in: line) {
                    fields.append(field)
                }
                line.removeAll(keepingCapacity: true)
            }
            if !completed {
                if let field = dataField(in: line) { fields.append(field) }
                completed = try await apply(fields, to: &result, decode: decode, onDelta: onDelta)
            }
            try Task.checkCancellation()
            let content = LLMProviderSupport.stripCodeFence(result.trimmingCharacters(in: .whitespacesAndNewlines))
            guard completed, !content.isEmpty else {
                throw InterpretationError.badResponse
            }
            return Interpretation(term: term, content: content, source: .llm)
        } catch let error as URLError {
            throw LLMProviderSupport.networkError(error)
        }
    }

    private static func dataField(in line: Data) -> String? {
        let line = String(decoding: line, as: UTF8.self)
        guard line.hasPrefix("data:") else { return nil }
        let field = line.dropFirst(5)
        return String(field.first == " " ? field.dropFirst() : field)
    }

    private static func apply(
        _ fields: [String], to result: inout String,
        decode: (Data) throws -> Update, onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> Bool {
        guard !fields.isEmpty else { return false }
        switch try decode(Data(fields.joined(separator: "\n").utf8)) {
        case .append(let fragment):
            if !fragment.isEmpty {
                result += fragment
                await onDelta(result)
            }
            return false
        case .done(let fragment):
            if !fragment.isEmpty { result += fragment }
            return true
        case .skip:
            return false
        }
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw InterpretationError.badResponse
        }
        return value
    }
}
