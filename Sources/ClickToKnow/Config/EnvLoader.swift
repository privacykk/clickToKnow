import Foundation

/// 从 .env 文件加载键值对到进程环境，便于本地配置密钥而不依赖 shell export。
/// 优先级（高→低）：shell 环境变量 > 当前目录 .env > ~/.clicktoknow/.env
enum EnvLoader {
    /// 依次加载当前目录与用户主目录下的 .env；两处都加载且不互相覆盖（见 loadFile）。
    static func load() {
        let cwd = FileManager.default.currentDirectoryPath + "/.env"
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicktoknow/.env").path
        loadFile(cwd)
        loadFile(home)
    }

    /// 解析单个 .env：跳过空行与 `#` 注释，按 `KEY=VALUE` 拆分（VALUE 内允许 `=`），
    /// 去除首尾空白并剥掉成对包裹的双引号；key 为空或非法的行静默忽略。
    private static func loadFile(_ path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            setenv(key, value, 0) // overwrite=0，不覆盖 shell 已 export 的值
        }
    }
}