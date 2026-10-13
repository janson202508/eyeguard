import Foundation

/// 配置持久化。写入 ~/Library/Application Support/EyeGuard/config.json
final class ConfigStore: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            save()
        }
    }

    /// 为 true 时内存中的修改不落盘。
    ///
    /// 开发者测试模式（`--test-mode`）用它把间隔临时调到 1 分钟，而**不污染
    /// 用户真实配置**。这条不是洁癖 —— 早期版本会把 1 分钟间隔写进
    /// config.json，用户下次正常双击启动就会被 1 分钟提醒一次，且完全没有
    /// 线索指向「上次跑过测试」，排查成本很高。
    var persistenceSuspended = false

    init() {
        AppPaths.ensureDirectories()
        self.config = ConfigStore.load() ?? AppConfig()
    }

    private static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: AppPaths.configURL) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func save() {
        guard !persistenceSuspended else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: AppPaths.configURL, options: .atomic)
    }
}
