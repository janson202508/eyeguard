import Foundation

/// 素材库。
///
/// 两路来源，**并存**：
///   1. 用户导入的图片 —— 落在 `~/Library/Application Support/EyeGuard/Scenes/`，
///      由那里的 `manifest.json` 索引。这是唯一会被写入磁盘的素材。
///   2. 预置场景 —— 随 App 分发，位于 bundle 内的 `Contents/Resources/Scenes/`。
///      只读，用户删不掉也改不坏；想换素材就换 App。
///      如果 bundle 里没有（例如直接跑 SPM 产出的裸可执行文件），
///      退回程序化生成的 50 张占位素材，保证开发期也有东西可看。
///
/// 早期版本是「manifest 非空就完全替代占位素材」，那是素材下载功能还没做时的
/// 权宜设计。现在用户能自己导入图片，就必须两路并存：否则导入第一张图之后
/// 内置场景会凭空消失，用户想留着对比都做不到。
///
/// 哪一路参与轮播由 `AppConfig.isAssetEnabled(_:)` 决定，不在这里过滤 ——
/// 素材库只负责「有什么」，不负责「用不用」。
final class SceneLibrary: ObservableObject {

    /// 全部素材（导入的 + 预置的），未按启用状态过滤
    @Published private(set) var assets: [SceneAsset] = []

    /// 预置场景。初始化时确定一次，之后不变。
    private let builtInAssets: [SceneAsset]

    init() {
        builtInAssets = Self.builtInPool()
        reload()
    }

    func reload() {
        AppPaths.ensureDirectories()
        let imported = Self.loadManifest(at: AppPaths.sceneDirectory) ?? []
        assets = imported + builtInAssets
    }

    // MARK: - 分组

    var importedAssets: [SceneAsset] {
        assets.filter { $0.source.isUserImport }
    }

    var builtInSceneAssets: [SceneAsset] {
        assets.filter { !$0.source.isUserImport }
    }

    /// 是否还没有导入过任何图片（此时全靠程序化占位素材撑着）
    var hasNoImportedImages: Bool { importedAssets.isEmpty }

    /// 当前参与轮播的素材。
    ///
    /// 过滤条件集中在 `AppConfig.isAssetEnabled` —— 选片、设置页统计、自检
    /// 都走这一个入口，避免三处各写一份略有出入的判断（那种不一致最终会
    /// 表现成「设置里显示 8 张，实际只轮播 7 张」）。
    func enabledAssets(using config: AppConfig) -> [SceneAsset] {
        assets.filter { config.isAssetEnabled($0) }
    }

    /// 内置场景按类别分组，只保留有素材的类别
    var builtInByCategory: [(category: SceneCategory, assets: [SceneAsset])] {
        SceneCategory.allCases.compactMap { category in
            let list = builtInSceneAssets.filter { $0.category == category }
            return list.isEmpty ? nil : (category, list)
        }
    }

    var categoryBreakdown: [(category: SceneCategory, count: Int)] {
        SceneCategory.allCases.compactMap { category in
            let count = assets.filter { $0.category == category }.count
            return count == 0 ? nil : (category, count)
        }
    }

    var sourceBreakdown: [(source: AssetSource, count: Int)] {
        AssetSource.allCases.compactMap { source in
            let count = assets.filter { $0.source == source }.count
            return count == 0 ? nil : (source, count)
        }
    }

    var importedTotalBytes: Int {
        importedAssets.reduce(0) { $0 + $1.byteSize }
    }

    // MARK: - 写入

    func addImported(_ newAssets: [SceneAsset]) throws {
        var imported = importedAssets
        imported.append(contentsOf: newAssets)
        try save(imported)
        reload()
    }

    func removeImported(id: String) throws {
        guard let asset = importedAssets.first(where: { $0.id == id }) else { return }
        if let fileName = asset.fileName {
            try? FileManager.default.removeItem(
                at: AppPaths.sceneDirectory.appendingPathComponent(fileName)
            )
        }
        try save(importedAssets.filter { $0.id != id })
        reload()
    }

    func removeAllImported() throws {
        for asset in importedAssets {
            if let fileName = asset.fileName {
                try? FileManager.default.removeItem(
                    at: AppPaths.sceneDirectory.appendingPathComponent(fileName)
                )
            }
        }
        try save([])
        reload()
    }

    /// 改某张导入图片的类别。类别决定它参与哪个轮次、以及会不会在夜间被排除。
    func reassign(id: String, to category: SceneCategory) throws {
        let updated = importedAssets.map { asset -> SceneAsset in
            guard asset.id == id else { return asset }
            var copy = asset
            copy.category = category
            return copy
        }
        try save(updated)
        reload()
    }

    // MARK: - manifest

    private static func loadManifest(at directory: URL) -> [SceneAsset]? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 只认用户导入的那一类。用户目录里的清单在语义上就只该描述用户素材；
        // 万一里面混进了 source: bundled 的条目，它的 fileName 会被解析到
        // 用户目录，出现「预置素材指向一个不存在的文件」。在这里挡掉。
        return try? JSONDecoder().decode([SceneAsset].self, from: data)
            .filter(\.source.isUserImport)
    }

    private func save(_ imported: [SceneAsset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(imported)
        try data.write(to: AppPaths.sceneDirectory.appendingPathComponent("manifest.json"),
                       options: .atomic)
    }

    // MARK: - 预置素材

    /// 预置素材池：优先用 bundle 里的真实素材，缺失时退回程序化占位素材。
    ///
    /// 自检、总览图、素材库三处都必须走这一个入口 —— 如果自检测的是程序化
    /// 占位素材、而 App 实际加载的是真实素材，那自检通过等于没测。
    static func builtInPool() -> [SceneAsset] {
        if let bundled = loadBundledManifest(), !bundled.isEmpty { return bundled }
        return makePlaceholderAssets()
    }

    /// 从 bundle 的 `Contents/Resources/Scenes/manifest.json` 读预置素材清单。
    private static func loadBundledManifest() -> [SceneAsset]? {
        guard let directory = AppPaths.bundledSceneDirectory else { return nil }
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SceneAsset].self, from: data)
    }

    /// 程序化占位素材：严格按规格书附录 A 的配额生成，共 50 张。
    ///
    /// depthScore 与 tone 都由素材 id 派生的确定性种子生成，保证可复现；
    /// 但两处关键分布是**确定性构造**的，不交给概率：
    ///
    ///   · FR-4.6 要求 depthScore >= 4 的占比 >= 70%。按配额取上整逐类安排
    ///     （配额 6 → 5 张、5 → 4 张、4 → 3 张），合计 40/50 = 80%。
    ///     早期版本用随机分档，50 个样本实测只有 60%，说明这类比例指标
    ///     不能靠概率满足。
    ///   · FR-4.7 要求夜间排除暖调。沙漠与峡谷默认是暖调，若整类无冷调/中性调
    ///     素材，夜间就会整类不可用。因此强制每类首张为中性调。
    ///
    /// `custom` 类别配额为 0，因此这里不会为它生成任何素材。
    static func makePlaceholderAssets() -> [SceneAsset] {
        var result: [SceneAsset] = []

        for category in SceneCategory.allCases where category.quota > 0 {
            let deepCount = Int((Double(category.quota) * 0.7).rounded(.up))

            for index in 0..<category.quota {
                let id = "placeholder-\(category.rawValue)-\(index)"
                var rng = SplitMix64(seed: stableSeed(id))

                let depth: Double
                if index < deepCount {
                    depth = rng.range(4.0, 5.0)
                } else {
                    depth = rng.range(3.0, 3.9)
                }

                let tone: Tone
                if category.defaultTone == .warm && index == 0 {
                    tone = .neutral
                } else {
                    tone = rng.unit() < 0.7 ? category.defaultTone : .neutral
                }

                result.append(SceneAsset(
                    id: id,
                    fileName: nil,
                    category: category,
                    source: .placeholder,
                    license: "程序化生成（开发期占位素材）",
                    depthScore: (depth * 10).rounded() / 10,
                    tone: tone
                ))
            }
        }
        return result
    }
}
