import Foundation

enum ExplanationStyle: String, CaseIterable, Identifiable {
    case technical, general, translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .technical: return "技术文档"
        case .general: return "通用阅读"
        case .translation: return "翻译"
        }
    }

    var prompt: String {
        switch self {
        case .technical: return LLMProviderSupport.systemPrompt
        case .general:
            return "解释选中的词语或短句，结合所给上下文选择最贴切的含义。使用中文，先给含义，再给一个简短用例。使用 Markdown，避免寒暄。"
        case .translation:
            return "仅翻译选中的文字。非中文翻译为简体中文，中文翻译为英语。根据上下文判断语义，保留专有名词、代码和原有结构。只输出翻译结果。"
        }
    }

    func userPrompt(term: String, context: String?) -> String {
        switch self {
        case .technical:
            return LLMProviderSupport.userPrompt(term: term, context: context)
        case .general, .translation:
            let request = self == .translation ? "请翻译选中文本" : "请解释选中文本"
            var prompt = "\(request)：\"\(term)\""
            if let context, !context.isEmpty {
                prompt += "\n\n上下文（仅供理解语义）：\n\"\"\"\n\(context)\n\"\"\""
            }
            return prompt
        }
    }
}
