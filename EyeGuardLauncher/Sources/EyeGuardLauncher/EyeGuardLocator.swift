import AppKit

/// 定位 EyeGuard.app。
///
/// 按可靠性从高到低尝试：
///   1. 正在运行的实例 —— 直接问 LaunchServices 它自己从哪来，最准
///   2. 用户上次手动指定的位置（记住）
///   3. 从启动器自己的 bundle 位置逐级向上找同级的 EyeGuard.app
///      这一条同时覆盖两种部署：`/Applications/` 下并排安装，
///      以及开发时 `工作区/EyeGuardLauncher/build/` 与 `工作区/EyeGuard/build/` 并排
///   4. `/Applications`、`~/Applications` 兜底
///
/// 都找不到时不猜，交给界面引导用户手动选（`chooseManually`）。
/// 猜错路径的后果是「点了启动没反应」，比明确报错难查得多。
enum EyeGuardLocator {
    static let bundleID = "info.xiaolu.eyeguard"
    private static let defaultsKey = "EyeGuardAppPath"

    static var remembered: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    static func find() -> URL? {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first,
           let url = running.bundleURL {
            return url
        }

        if let remembered { return remembered }

        for candidate in searchPaths() where isAppBundle(candidate) {
            return candidate
        }
        return nil
    }

    /// 让用户手动指定。用户取消返回 nil。
    static func chooseManually() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 EyeGuard.app"
        panel.message = "找不到 EyeGuard，请手动指定它所在的位置"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remembered = url
        return url
    }

    // MARK: - 私有

    private static func isAppBundle(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func searchPaths() -> [URL] {
        var paths: [URL] = []

        // 从启动器自己的位置逐级向上找
        if let launcherBundle = Bundle.main.bundleURL as URL? {
            var level = launcherBundle.deletingLastPathComponent()
            for _ in 0..<6 {
                paths.append(level.appendingPathComponent("EyeGuard.app"))
                paths.append(level.appendingPathComponent("EyeGuard/build/EyeGuard.app"))
                let parent = level.deletingLastPathComponent()
                if parent.path == level.path { break }   // 到根了
                level = parent
            }
        }

        paths.append(URL(fileURLWithPath: "/Applications/EyeGuard.app"))
        paths.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/EyeGuard.app"))

        // 去重，保持顺序
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }
}
