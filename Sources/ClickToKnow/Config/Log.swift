import OSLog

/// 统一日志入口：os.Logger 分级 + 按模块分类。
/// 查看：`log show --predicate 'subsystem == "ClickToKnow"' --last 1h`
/// 注意：日志永不包含密钥明文（掩码后也不行——掩码拼接同样是指纹信息）。
enum Log {
    /// 取词链路（热键 / AX / 剪贴板）
    static let selection = Logger(subsystem: "ClickToKnow", category: "selection")
    /// LLM 请求与连接测试
    static let llm = Logger(subsystem: "ClickToKnow", category: "llm")
    /// 配置与密钥存储
    static let config = Logger(subsystem: "ClickToKnow", category: "config")
    /// 应用生命周期 / 菜单栏 / 窗口
    static let app = Logger(subsystem: "ClickToKnow", category: "app")
}
