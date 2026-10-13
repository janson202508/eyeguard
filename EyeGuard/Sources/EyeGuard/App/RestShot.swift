import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 休息画面的离屏连拍。开发期自查用。
///
/// 用法：`EyeGuard --shot-rest <输出目录>`
///
/// ## 为什么不是「渲染一张图」而是「连拍」
///
/// 设置页是静态的，渲染一次就够。休息画面不是 —— 它最关键的路径是
/// **同一个窗口里换图**（点「换一张」）：视图实例不重建，只有
/// `scheduler.currentAsset` 变了。
///
/// 这条路径的失效方式极其隐蔽：程序化场景走 `Canvas` 绘制，SwiftUI 在
/// 「视图结构相同、只有捕获的闭包内容不同」时不保证重新调用渲染闭包。
/// 表现出来就是「日志显示换成了另一张，画面却一动不动」——
/// 而这正是**读代码看不出来、只有连拍才能发现**的一类缺陷。
///
/// 因此这里刻意保持**同一个 `NSHostingView` 存活**，中途只调
/// `scheduler.nextScene()`，每换一次截一张。若若干张 PNG 完全相同，
/// 就说明换图没有真正重绘。
///
/// 全程在隔离目录（`EYEGUARD_HOME`）里跑，不碰用户真实数据。
///
/// ## 为什么窗口尺寸是可传的
///
/// 这里渲染的尺寸必须能变，否则会漏掉一整类缺陷：**布局对宽高比敏感**。
/// 真实窗口取的是 `NSScreen.frame`，而背景图用 `aspectRatio(.fill)` 铺满，
/// 于是「窗口宽高比」与「图片宽高比」的大小关系会改变容器的最终尺寸。
/// 写死 1440×900（16:10）时这条路径恰好不会出问题，看着一切正常。
enum RestShot {

    /// 默认按主屏的实际点数渲染 —— 也就是生产环境真实的窗口尺寸。
    /// 传 `WxH` 可覆盖（例如 1920x1080 复现 16:9 外接屏）。
    static func defaultSize() -> CGSize {
        if let screen = NSScreen.main {
            return screen.frame.size
        }
        return CGSize(width: 1440, height: 900)
    }

    static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width >= 200, height >= 200 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func run(outputDirectory: String, size requestedSize: CGSize?) -> Int32 {
        let size = requestedSize ?? defaultSize()
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("无法创建输出目录：\(error.localizedDescription)")
            return 1
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempHome = NSTemporaryDirectory() + "eyeguard-restshot-\(UUID().uuidString)"
        setenv("EYEGUARD_HOME", tempHome, 1)
        // 布局探针在这里**强制打开**：这个工具从「看一眼对不对」升级成
        // 「越界就判失败」，否则「控件跑出屏幕」这类缺陷只能靠人眼发现。
        setenv("EYEGUARD_LAYOUT_PROBE", "1", 1)
        defer {
            unsetenv("EYEGUARD_HOME")
            unsetenv("EYEGUARD_LAYOUT_PROBE")
            try? FileManager.default.removeItem(atPath: tempHome)
        }

        let configStore = ConfigStore()
        configStore.persistenceSuspended = true
        let sceneLibrary = SceneLibrary()
        let scheduler = Scheduler(configStore: configStore,
                                  sceneLibrary: sceneLibrary)
        // 同一个宿主视图贯穿全程 —— 这是这个工具的全部意义所在
        let hosting = NSHostingView(rootView: RestView(scheduler: scheduler))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.isOpaque = true
        window.backgroundColor = .black
        window.orderFront(nil)

        settle(0.8)

        let insets = hosting.safeAreaInsets
        print(String(format: "窗口 %.0f x %.0f   宿主视图 bounds %@   安全区 上%.0f 左%.0f 下%.0f 右%.0f",
                     size.width, size.height,
                     NSStringFromRect(hosting.bounds),
                     insets.top, insets.left, insets.bottom, insets.right))

        var written: [String] = []
        var outOfView: [String] = []
        var index = 1

        func shoot(_ label: String) {
            let name = String(format: "%02d-%@.png", index, label)
            index += 1
            let url = directory.appendingPathComponent(name)
            let asset = scheduler.currentAsset
            let id = asset?.id ?? "nil"
            let category = asset?.category.rawValue ?? "—"
            var ratio = "—"
            if let asset, asset.height > 0 {
                ratio = String(format: "%.2f", Double(asset.width) / Double(asset.height))
            }
            print("  \(name)  id=\(id)  category=\(category)  source=\(asset?.source.rawValue ?? "—")  图宽高比=\(ratio)")
            if capture(hosting, to: url) {
                written.append(name)
            } else {
                print("    渲染失败")
            }
            LayoutProbe.report(windowSize: size)
            let bad = LayoutProbe.outOfViewCount(windowSize: size)
            if bad > 0 {
                outOfView.append("\(name)（\(bad) 个控件越界）")
            }
            settle(0.45)
        }

        // A. 内置素材：同一个视图里连换三次
        print("内置素材（启用 \(scheduler.activeAssets.count) 张）")
        scheduler.restNow()
        settle(0.45)
        shoot("内置-1")
        for _ in 0..<3 {
            scheduler.nextScene()
            shoot("内置-换一张")
        }

        // B. 导入图片后再连换两次 —— 确认两路素材在同一个视图里都能换
        scheduler.skip()
        settle(0.3)
        importSamples(into: sceneLibrary)
        print("导入图片后（启用 \(scheduler.activeAssets.count) 张）")
        scheduler.restNow()
        settle(0.45)
        shoot("导入-1")
        for _ in 0..<2 {
            scheduler.nextScene()
            shoot("导入-换一张")
        }

        // B2. 只留竖幅导入图，**强制命中窄图这条路径**。
        //
        // 背景图用 `aspectRatio(.fill)` 铺满，会把根容器撑得比窗口还高；
        // 撑高的幅度只取决于「窗口宽高比 ÷ 图片宽高比」。所以窄图（竖幅、
        // 4:3 这种）是最容易把底部按钮顶出屏幕的一类。靠洗牌碰运气撞不到，
        // 必须定向构造 —— 这一项就是为「控件跑出视野」设的回归检查。
        scheduler.skip()
        settle(0.3)
        configStore.config.useBuiltInScenes = false
        for asset in sceneLibrary.importedAssets {
            configStore.config.setAsset(asset.id, enabled: asset.height > asset.width)
        }
        print("只留竖幅导入图后（启用 \(scheduler.activeAssets.count) 张）")
        scheduler.restNow()
        settle(0.45)
        shoot("竖幅导入图")

        // C. 全部禁用 → 退化层。自检能证明不崩，但「长什么样」只能看
        scheduler.skip()
        settle(0.3)
        for asset in sceneLibrary.importedAssets {
            configStore.config.setAsset(asset.id, enabled: false)
        }
        print("全部禁用后（启用 \(scheduler.activeAssets.count) 张）")
        scheduler.restNow()
        settle(0.45)
        shoot("空素材库")

        window.orderOut(nil)

        print("")
        for name in written {
            print("已写出 \(directory.appendingPathComponent(name).path)")
        }
        print("")
        if outOfView.isEmpty {
            print("控件越界检查：全部通过（\(written.count) 张，没有任何控件跑出窗口）")
        } else {
            print("控件越界检查：未通过 \(outOfView.count) 张")
            for item in outOfView {
                print("  · \(item)")
            }
        }
        return (written.isEmpty || !outOfView.isEmpty) ? 1 : 0
    }

    // MARK: - 工具

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func capture(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// 造几张尺寸、色调各异的图并导入（与设置页截图共用同一套造图逻辑）
    private static func importSamples(into library: SceneLibrary) {
        let tempSources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyeguard-restshot-src-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempSources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSources) }

        // 刻意混进一张**竖幅**：用户导入的是自己的照片，手机竖拍、4:3 都很常见。
        // 原来三张全是 16:9，正好把「窄图把按钮顶出屏幕」这条路径整个绕过去了 ——
        // 这是样例集的漏洞，不是运气问题。
        let specs: [(name: String, width: Int, height: Int, format: UTType, category: SceneCategory)] = [
            ("清晨的山脊.jpg", 2400, 1350, .jpeg, .mountain),
            ("午后海面.png",   1920, 1080, .png,  .ocean),
            ("湖畔黄昏.png",   2560, 1440, .png,  .lake),
            ("竖幅远山.jpg",   1512, 2016, .jpeg, .mountain)
        ]

        var byCategory: [SceneCategory: [URL]] = [:]
        for (index, spec) in specs.enumerated() {
            guard let data = AssetImportSelfTest.makeImageData(width: spec.width,
                                                               height: spec.height,
                                                               format: spec.format,
                                                               seed: UInt64(index + 200)) else { continue }
            let url = tempSources.appendingPathComponent(spec.name)
            guard (try? data.write(to: url)) != nil else { continue }
            byCategory[spec.category, default: []].append(url)
        }

        for (category, urls) in byCategory {
            let outcome = SceneImporter.importItems(urls, category: category, existingIDs: [])
            try? library.addImported(outcome.added)
        }
    }
}
