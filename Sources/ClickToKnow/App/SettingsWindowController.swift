import AppKit

/// 设置窗口：配置 OpenAI 兼容端点 / API Key / 模型，写入 UserDefaults。
@MainActor
final class SettingsWindowController: NSWindowController {
    private var baseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!

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

        let tip = NSTextField(labelWithString: "留空则使用 macOS 系统词典兜底")
        tip.textColor = .secondaryLabelColor
        tip.font = .systemFont(ofSize: 11)

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