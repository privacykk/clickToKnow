import Foundation

/// 从 .env 文件加载键值对到进程环境，便于本地配置密钥而不依赖 shell export。
/// 优先级（高→低）：shell 环境变量 > 当前目录 .env > ~/.clicktoknow/.env
enum EnvLoader {
    static func load() {
        let cwd = FileManager.default.currentDirectoryPath + "/.env"
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicktoknow/.env").path
        loadFile(cwd)
        loadFile(home)
    }

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