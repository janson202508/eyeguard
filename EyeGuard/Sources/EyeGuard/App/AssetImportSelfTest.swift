import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 素材导入链路的端到端自检。
///
/// ## 为什么要单独写这一块
///
/// 导入这条路径和状态机不一样：它会**真的写盘**（往素材目录拷图片、写
/// manifest.json、删文件）。没有隔离目录就没法自动化 —— 只能靠手工点
/// NSOpenPanel 走一遍，而「靠人记得点一遍」的验收等于没有验收。
///
/// `AppPaths` 支持 `EYEGUARD_HOME` 重定向后，这里就能在临时目录里把
/// 「选文件 → 去重 → 降采样 → 落盘 → 写 manifest → 重启后重新加载 →
/// 改类别 → 删除」整条链路跑完，且全程不碰用户的真实素材库。
///
/// 覆盖不到的部分只剩「NSOpenPanel 弹出来之后点了哪个按钮」这一层 ——
/// 而那是 AppKit 的事，不是本程序的逻辑。
enum AssetImportSelfTest {

    /// 返回未通过的项。空数组表示全部通过。
    static func run() -> [String] {
        var failures: [String] = []

        let tempHome = NSTemporaryDirectory() + "eyeguard-selftest-\(UUID().uuidString)"
        setenv("EYEGUARD_HOME", tempHome, 1)
        defer {
            unsetenv("EYEGUARD_HOME")
            try? FileManager.default.removeItem(atPath: tempHome)
        }

        let sourceDir = URL(fileURLWithPath: tempHome).appendingPathComponent("__sources")
        let subDir = sourceDir.appendingPathComponent("sub")
        guard (try? FileManager.default.createDirectory(at: subDir,
                                                        withIntermediateDirectories: true)) != nil else {
            return ["无法创建自检临时目录"]
        }

        // MARK: 造素材

        let smallPNG = makeImageData(width: 200, height: 100, format: .png, seed: 11)
        let bigJPEG = makeImageData(width: 3000, height: 1500, format: .jpeg, seed: 22)
        let nestedPNG = makeImageData(width: 640, height: 360, format: .png, seed: 33)

        guard let smallPNG, let bigJPEG, let nestedPNG else {
            return ["无法生成自检用的测试图片"]
        }

        let aURL = sourceDir.appendingPathComponent("a.png")
        let bigURL = sourceDir.appendingPathComponent("big.jpg")
        let dupURL = sourceDir.appendingPathComponent("副本-换个名字.png")
        let txtURL = sourceDir.appendingPathComponent("notes.txt")
        let nestedURL = subDir.appendingPathComponent("c.png")

        do {
            try smallPNG.write(to: aURL)
            try bigJPEG.write(to: bigURL)
            try smallPNG.write(to: dupURL)          // 字节完全相同的副本
            try "not an image".data(using: .utf8)?.write(to: txtURL)
            try nestedPNG.write(to: nestedURL)
        } catch {
            return ["无法写入自检用的测试图片：\(error.localizedDescription)"]
        }

        // MARK: 导入

        let outcome = SceneImporter.importItems(
            [aURL, bigURL, dupURL, txtURL, subDir],
            category: .custom,
            existingIDs: []
        )

        print("")
        print("导入链路（隔离目录：\(tempHome)）")
        print("  摘要（en）：\(outcome.summary(.english))")
        print("  摘要（zh）：\(outcome.summary(.simplifiedChinese))")
        print("  明细（en）：\(outcome.summaryDetail(.english))")
        print("  明细（zh）：\(outcome.summaryDetail(.simplifiedChinese))")

        // 两语言必须真的不同。
        //
        // ⚠️ 这里**刻意不检查「英文里有没有汉字」**。
        // 第一版就是那样写的，结果**假失败**了：明细里会嵌用户文件名，
        // 而自检的测试素材恰好叫「副本-换个名字.png」，于是英文句子里当然有汉字。
        // 判据问错了问题 —— 该问的是「**模板**里有没有漏汉字」，而运行时
        // 拿到的是**渲染后的句子**，用户数据混在里面，分不开。
        // 模板检查已经在生成器里对全部 258 条逐条做过（`gen_strings.py`）。
        let languagesDiffer = outcome.summary(.english) != outcome.summary(.simplifiedChinese)
        print("  两语言的摘要确实不同：\(languagesDiffer ? "通过" : "失败")")
        if !languagesDiffer { failures.append("两语言的导入摘要相同，语言表可能没生效") }

        let countsOK = outcome.added.count == 3
            && outcome.duplicates.count == 1
            && outcome.unsupported.count == 1
            && outcome.failed.isEmpty
        print("  逐类计数（3 新增 / 1 重复 / 1 非图片 / 0 失败）：\(countsOK ? "通过" : "失败")")
        if !countsOK {
            failures.append("导入计数不符：新增 \(outcome.added.count)、重复 \(outcome.duplicates.count)、"
                            + "非图片 \(outcome.unsupported.count)、失败 \(outcome.failed.count)")
        }

        // 内容哈希去重：改名不改内容必须被认出来
        let dedupOK = outcome.duplicates.first == "副本-换个名字.png"
        print("  改名后的同一张图被识别为重复：\(dedupOK ? "通过" : "失败")")
        if !dedupOK { failures.append("内容哈希去重失效") }

        // 大图降采样，小图不动
        let bigAsset = outcome.added.first { $0.originalName == "big.jpg" }
        let smallAsset = outcome.added.first { $0.originalName == "a.png" }
        let downscaleOK = bigAsset.map { max($0.width, $0.height) == SceneImporter.maxEdge } ?? false
        print("  3000×1500 降到 \(bigAsset.map { "\($0.width)×\($0.height)" } ?? "—")"
              + "（上限 \(SceneImporter.maxEdge)）：\(downscaleOK ? "通过" : "失败")")
        if !downscaleOK { failures.append("大图未按上限降采样") }

        let noUpscaleOK = smallAsset.map { $0.width == 200 && $0.height == 100 } ?? false
        print("  200×100 不被放大：\(noUpscaleOK ? "通过" : "失败")"
              + "（\(smallAsset.map { "\($0.width)×\($0.height)" } ?? "—")）")
        if !noUpscaleOK { failures.append("小图被意外放大") }

        // 文件夹只展开一层
        let folderOK = outcome.added.contains { $0.originalName == "c.png" }
        print("  选中文件夹时取到其中直接包含的图片：\(folderOK ? "通过" : "失败")")
        if !folderOK { failures.append("文件夹展开未取到直接包含的图片") }

        // 展示名用原始文件名，而不是内容哈希文件名
        let displayOK = smallAsset.map { $0.displayName(.developer) == "a.png" } ?? false
        print("  展示名使用原始文件名：\(displayOK ? "通过" : "失败")"
              + "（\(smallAsset?.displayName(.developer) ?? "—")）")
        if !displayOK { failures.append("展示名未使用原始文件名") }

        // 落盘文件名是内容哈希，扩展名统一为 jpg
        let fileOK = smallAsset.map { ($0.fileName ?? "").hasPrefix("user-") && $0.fileName?.hasSuffix(".jpg") == true } ?? false
        print("  落盘文件名使用内容哈希：\(fileOK ? "通过" : "失败")"
              + "（\(smallAsset?.fileName ?? "—")）")
        if !fileOK { failures.append("落盘文件名不是内容哈希") }

        // id 必须稳定：同样的字节再来一次得到同样的 id。
        // 这次用不同类别导入，落盘文件名应当仍是同一个内容哈希 ——
        // 也就是说同一张图不会在素材目录里留下两份拷贝。
        let again = SceneImporter.importItems([aURL], category: .mountain, existingIDs: [])
        let stableOK = again.added.first?.id == smallAsset?.id
        print("  同一张图重复导入得到相同 id：\(stableOK ? "通过" : "失败")")
        if !stableOK { failures.append("内容哈希 id 不稳定") }

        // MARK: 入库与持久化

        let library = SceneLibrary()
        // 内置素材张数**不能写死**：它随素材库扩容而变化（曾从 50 涨到 392）。
        // 这里要断言的是「导入 3 张后总数 = 原有内置数 + 3」，与库容量无关。
        let builtInCount = library.builtInSceneAssets.count
        do {
            try library.addImported(outcome.added)
        } catch {
            return failures + ["写入素材库失败：\(error.localizedDescription)"]
        }

        let addedOK = library.importedAssets.count == 3
            && library.builtInSceneAssets.count == builtInCount
            && library.assets.count == builtInCount + 3
        print("  入库后：导入 \(library.importedAssets.count) 张 + 内置 \(library.builtInSceneAssets.count) 张"
              + " = \(library.assets.count) 张：\(addedOK ? "通过" : "失败")")
        if !addedOK { failures.append("入库后素材数不符") }

        let manifestURL = AppPaths.sceneDirectory.appendingPathComponent("manifest.json")
        let manifestOK = FileManager.default.fileExists(atPath: manifestURL.path)
        print("  manifest.json 已写出：\(manifestOK ? "通过" : "失败")")
        if !manifestOK { failures.append("manifest.json 未写出") }

        // 重新构造素材库 = 模拟重启
        let reloaded = SceneLibrary()
        let reloadOK = reloaded.importedAssets.count == 3
            && reloaded.importedAssets.contains { $0.category == .custom }
            && reloaded.importedAssets.contains { $0.originalName == "big.jpg" }
        print("  重启后重新加载导入的图片：\(reloadOK ? "通过" : "失败")")
        if !reloadOK { failures.append("重启后未正确加载导入的图片") }

        // MARK: 启用过滤与选片

        var config = AppConfig()
        config.useBuiltInScenes = false
        let enabledOnlyImports = reloaded.enabledAssets(using: config)
        let filterOK = enabledOnlyImports.count == 3
            && enabledOnlyImports.allSatisfy { $0.source.isUserImport }
        print("  关掉内置场景后启用集只剩导入的图片：\(filterOK ? "通过" : "失败")")
        if !filterOK { failures.append("启用集过滤结果不正确") }

        // 用真实的导入素材跑一轮选片，确认它们能真的被选中
        var pickBag = ShuffleBagState()
        var pickedFromImports = 0
        for _ in 0..<9 {
            if let picked = AssetPicker.pick(pool: enabledOnlyImports, bag: &pickBag, isNight: false),
               picked.source.isUserImport {
                pickedFromImports += 1
            }
        }
        print("  导入的图片能正常被选片算法选中：\(pickedFromImports == 9 ? "通过" : "失败")"
              + "（9 次取到 \(pickedFromImports) 次）")
        if pickedFromImports != 9 { failures.append("导入的图片未被选片算法选中") }

        // MARK: 改类别

        guard let target = reloaded.importedAssets.first else {
            return failures + ["素材库为空，无法继续验证"]
        }
        do {
            try reloaded.reassign(id: target.id, to: .ocean)
        } catch {
            return failures + ["改类别失败：\(error.localizedDescription)"]
        }
        let afterReassign = SceneLibrary()
        let reassignOK = afterReassign.importedAssets.first { $0.id == target.id }?.category == .ocean
        print("  改类别并持久化：\(reassignOK ? "通过" : "失败")")
        if !reassignOK { failures.append("改类别未持久化") }

        // MARK: 删除

        let fileToDelete = target.fileName.map {
            AppPaths.sceneDirectory.appendingPathComponent($0)
        }
        do {
            try reloaded.removeImported(id: target.id)
        } catch {
            return failures + ["删除单张失败：\(error.localizedDescription)"]
        }
        let singleDeleteOK = reloaded.importedAssets.count == 2
            && fileToDelete.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        print("  删除单张（同时清掉素材库里的拷贝）：\(singleDeleteOK ? "通过" : "失败")")
        if !singleDeleteOK { failures.append("删除单张未清理文件或索引") }

        do {
            try reloaded.removeAllImported()
        } catch {
            return failures + ["全部移除失败：\(error.localizedDescription)"]
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: AppPaths.sceneDirectory.path
        ))?.filter { $0.hasPrefix("user-") } ?? []
        let clearOK = reloaded.importedAssets.isEmpty
            && reloaded.builtInSceneAssets.count == builtInCount
            && leftovers.isEmpty
        print("  全部移除后不残留文件，内置场景仍在：\(clearOK ? "通过" : "失败")"
              + "（残留 \(leftovers.count) 个）")
        if !clearOK { failures.append("全部移除后有残留") }

        return failures
    }

    // MARK: - 测试图片生成

    /// 用 CoreGraphics 现场画一张图并编码成指定格式。
    /// 颜色由 seed 决定，保证不同调用生成的字节不同（否则内容哈希会撞车）。
    ///
    /// 内部可见：`SettingsShot` 也用它来造几张图，好在隔离目录里渲染出
    /// 「素材页已有导入图片」的真实样子。
    static func makeImageData(width: Int,
                              height: Int,
                              format: UTType,
                              seed: UInt64) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var rng = SplitMix64(seed: seed)
        context.setFillColor(CGColor(red: 0.15, green: 0.18, blue: 0.26, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 画几条不同颜色的横带，让图像内容有实际差异
        for index in 0..<6 {
            let y = Double(index) / 6.0
            context.setFillColor(CGColor(red: rng.unit(),
                                         green: rng.unit(),
                                         blue: rng.unit(),
                                         alpha: 1))
            context.fill(CGRect(x: 0,
                                y: y * Double(height),
                                width: Double(width),
                                height: Double(height) / 12.0))
        }

        guard let image = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.identifier as CFString, 1, nil
        ) else { return nil }

        let options: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
