import AppKit

/// 设置窗口：配置 OpenAI 兼容端点 / API Key / 模型，写入 UserDefaults。
@MainActor
final class SettingsWindowController: NSWindowController {
    private var baseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!
    private weak var tipTag: NSTextField?

    private static func tint(forEnv hasEnvKey: Bool) -> String {
        hasEnvKey
            ? "密钥已由环境变量 / .env 提供（此处无需填写）；其余项留空则使用 macOS 系统词典兜底"
            : "推荐用 .env 文件存密钥（cp .env.example .env）；此处也可填写。全部留空则使用 macOS 系统词典兜底"
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClickToKnow 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = buildViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// 窗口复用打开时刷新提示与字段（env 提供的密钥不回显到输入框，避免误导）
    override func showWindow(_ sender: Any?) {
        let hasEnvKey = AppConfig.shared.apiKeyFromEnvironment
        tipTag?.stringValue = Self.tint(forEnv: hasEnvKey)
        if hasEnvKey {
            apiKeyField.stringValue = ""
        }
        super.showWindow(sender)
    }

    private func buildViewController() -> NSViewController {
        let config = AppConfig.shared

        baseURLField = NSTextField()
        baseURLField.stringValue = config.baseURL
        baseURLField.placeholderString = "OpenAI 兼容端点，如 https://dashscope.aliyuncs.com/compatible-mode/v1"

        apiKeyField = NSSecureTextField()
        apiKeyField.stringValue = config.apiKey
        apiKeyField.placeholderString = "sk-..."

        modelField = NSTextField()
        modelField.stringValue = config.model
        modelField.placeholderString = "如 qwen-plus / deepseek-chat"

        let grid = NSGridView(views: [
            [label("Base URL"), baseURLField],
            [label("API Key"), apiKeyField],
            [label("Model"), modelField]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        // 提示会随 env/.env 是否提供密钥而变，保存时不写回，故在打开时重建
        let tip = NSTextField(labelWithString: Self.tint(forEnv: AppConfig.shared.apiKeyFromEnvironment))
        tip.textColor = .secondaryLabelColor
        tip.font = .systemFont(ofSize: 11)
        tipTag = tip

        let saveButton = NSButton(title: "保存并关闭", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [grid, tip, saveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])

        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    @objc private func save() {
        let config = AppConfig.shared
        config.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        config.apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        config.model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        close()
    }
}