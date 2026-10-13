import Foundation

/// 运行时状态持久化。用于 FR-1.7：程序重启后恢复剩余计时，
/// 否则「退出程序」会成为规避提醒的捷径。
final class StateStore {
    func load() -> RuntimeState? {
        guard let data = try? Data(contentsOf: AppPaths.stateURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeState.self, from: data)
    }

    func save(_ state: RuntimeState) {
        AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: AppPaths.stateURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: AppPaths.stateURL)
    }
}
