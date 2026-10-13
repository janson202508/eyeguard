import Foundation

/// 应用数据目录。全部落在 ~/Library/Application Support/EyeGuard 下。
enum AppPaths {

    /// 数据根目录。
    ///
    /// 支持用环境变量 `EYEGUARD_HOME` 重定向到一个隔离目录。这不是给用户用的
    /// 开关，而是给自动化验证用的接缝：导入图片、删除素材这些操作会真的写盘，
    /// 没有隔离目录就没法在自检里端到端跑一遍 —— 只能靠手工点 NSOpenPanel，
    /// 而「靠人记得点一遍」的验收等于没有验收。
    ///
    /// 用 `getenv` 而不是 `ProcessInfo.environment`：后者在部分 Foundation
    /// 版本里会被缓存，运行中途 `setenv` 改不动，测试里正好需要中途改。
    static var supportDirectory: URL {
        if let raw = getenv("EYEGUARD_HOME"), let path = String(validatingUTF8: raw), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EyeGuard", isDirectory: true)
    }

    /// 素材目录：**用户**导入与下载的图片放这里，配合 manifest.json 索引。
    ///
    /// 预置素材不在这里 —— 见 `bundledSceneDirectory`。
    static var sceneDirectory: URL {
        supportDirectory.appendingPathComponent("Scenes", isDirectory: true)
    }

    /// 预置素材目录：随 App 一起分发，位于 bundle 内的 `Contents/Resources/Scenes/`。
    ///
    /// 为什么不放进 `sceneDirectory`：
    ///   `SceneLibrary.save` 写 manifest 时只序列化**用户导入**的素材
    ///   （`source.isUserImport`）。如果预置素材的清单也写在同一个
    ///   `Scenes/manifest.json` 里，用户导入第一张自己的图时，
    ///   `save` 会把整个清单覆盖成只剩那一张 —— 50 张预置素材当场消失。
    ///   预置内容必须和用户可写目录分开，这是目录结构的约束，不是偏好。
    static var bundledSceneDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Scenes", isDirectory: true)
    }

    /// 某个素材对应的图片文件位置。**所有**读图的地方都要走这里。
    ///
    /// 之前三处（休息层、缩略图缓存、占位渲染）各自拼
    /// `sceneDirectory + fileName`，多一类素材来源就得记得改三处，
    /// 漏一处就表现成「设置里能看到缩略图，休息时却是程序化画面」。
    static func imageURL(for asset: SceneAsset) -> URL? {
        guard let fileName = asset.fileName else { return nil }
        switch asset.source {
        case .bundled:
            if let directory = bundledSceneDirectory {
                let url = directory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            // 兜底：允许把预置素材手工放到用户目录来替换（调试用）
            return sceneDirectory.appendingPathComponent(fileName)
        case .imported, .downloaded, .placeholder:
            return sceneDirectory.appendingPathComponent(fileName)
        }
    }

    static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [supportDirectory, sceneDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
