import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置界面的离屏渲染。开发期自查用。
///
/// 用法：`EyeGuard --shot-settings <输出目录>`
///
/// ## 为什么需要它
///
/// 「素材」页里的东西（卡片里的无边框下拉菜单、自适应列宽的网格、
/// 两段式开关列表）全都是**编译期完全看不出来、只有渲染出来才知道对不对**
/// 的构造。它们不会让构建失败，只会让界面难看或者不可用。
///
/// 截图本来可以用 `screencapture`，但那需要「屏幕录制」授权，在受控环境里
/// 往往给不了；而且截的是「当前屏幕」，窗口被挡住就白截。这里改走
/// `NSHostingView` + `cacheDisplay` —— 让程序自己把自己的视图渲染成 PNG，
/// 不依赖任何授权，也不受窗口遮挡影响。
///
/// 渲染会在隔离目录（`EYEGUARD_HOME`）里造几张图并真的导入一遍，
/// 这样截出来的是「已经导入过图片」的真实样子，而不是空库的退化状态。
/// 全程不碰用户真实数据。
enum SettingsShot {

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("无法创建输出目录：\(error.localizedDescription)")
            return 1
        }

        // 离屏渲染仍需要一个 NSApplication 实例，否则窗口与视图的布局不走。
        // 用 .accessory 策略：不出现在 Dock，也不抢焦点。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempHome = NSTemporaryDirectory() + "eyeguard-shot-\(UUID().uuidString)"
        setenv("EYEGUARD_HOME", tempHome, 1)
        defer {
            unsetenv("EYEGUARD_HOME")
            try? FileManager.default.removeItem(atPath: tempHome)
        }

        let configStore = ConfigStore()
        configStore.persistenceSuspended = true          // 截图不写配置
        let sceneLibrary = SceneLibrary()
        let scheduler = Scheduler(configStore: configStore,
                                  sceneLibrary: sceneLibrary)
        var written: [String] = []

        // 语言：英文是**默认语言**，但整套界面当初是按中文排的 ——
        // 英文标签普遍更长（"Suppress while the camera is in use (in a meeting)"
        // 对「摄像头被占用（会议中）」）。「排得下、不截断」这件事必须两种语言
        // 各看一遍；只截中文的话，英文界面的截断永远没人发现。
        let languages = Language.allCases

        // 1. 空库状态 —— 用户刚装好、还没导入任何图片时看到的样子
        //
        // 高度用 492 而不是窗口的 540：`TabView` 在 macOS 上是原生 NSTabView，
        // 顶部标签栏要占掉约 48pt，标签页内容真正拿到的可视高度就是 540-48。
        // 用 540 渲染会**高估**可视区，把「内容被挡在下面」这类问题截没了。
        for language in languages {
            configStore.config.language = language
            let name = "01-素材-空库-\(language.rawValue).png"
            if render(AssetSettingsView(configStore: configStore,
                                        sceneLibrary: sceneLibrary,
                                        scheduler: scheduler),
                      size: CGSize(width: 580, height: 492),
                      to: directory.appendingPathComponent(name)) {
                written.append(name)
            }
        }

        // 2. 导入几张图 —— 卡片网格的真实样子
        importSamples(into: sceneLibrary)
        // 关掉其中一张，让「禁用态」也能在截图里看到
        if let first = sceneLibrary.importedAssets.first {
            configStore.config.setAsset(first.id, enabled: false)
        }

        for language in languages {
            configStore.config.language = language
            let tag = language.rawValue

            let assetShot = "02-素材-已导入-\(tag).png"
            if render(AssetSettingsView(configStore: configStore,
                                        sceneLibrary: sceneLibrary,
                                        scheduler: scheduler),
                      size: CGSize(width: 580, height: 540),
                      to: directory.appendingPathComponent(assetShot)) {
                written.append(assetShot)
            }

            // 4. 素材页长图。
            //
            // 540pt 的高度会把「内置场景」的类别列表整个截在视野外，而类别名
            // 恰恰是英文比中文长最多的地方（"Grassland" 对「草原」，
            // "Starfield" 对「星空」）。列宽是按英文改的，就得按英文量一次 ——
            // **按中文宽度写死，英文会被截断，而截断只有渲染出来才看得见。**
            let tallName = "04-素材-长图-\(tag).png"
            if render(AssetSettingsView(configStore: configStore,
                                        sceneLibrary: sceneLibrary,
                                        scheduler: scheduler),
                      size: CGSize(width: 580, height: 1120),
                      to: directory.appendingPathComponent(tallName)) {
                written.append(tallName)
            }

            // 3. 设置窗口逐标签页。素材页上面已经单独截过，这里跳过。
            for tab in SettingsView.Tab.allCases where tab != .assets {
                let name = "03-设置-\(tab.rawValue)-\(tag).png"
                if render(SettingsView(configStore: configStore,
                                       scheduler: scheduler,
                                       sceneLibrary: sceneLibrary,
                                       initialTab: tab),
                          size: CGSize(width: 580, height: 540),
                          to: directory.appendingPathComponent(name)) {
                    written.append(name)
                }
            }
        }

        configStore.config.language = Language.fallback

        for name in written {
            print("已写出 \(directory.appendingPathComponent(name).path)")
        }
        if written.isEmpty {
            print("渲染失败：没有产出任何图片")
            return 1
        }
        return 0
    }

    // MARK: - 渲染

    /// 把 SwiftUI 视图渲染成 PNG。
    ///
    /// 窗口放在屏幕外并 `orderFront` —— SwiftUI 只有在视图挂进窗口层级后才会
    /// 真正布局与绘制，光有 `NSHostingView` 是不够的。放屏幕外是为了避免
    /// 截图过程在用户眼前闪一下。
    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) -> Bool {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)

        // 让 SwiftUI 把布局和首帧绘制跑完
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let ok: Bool
        if let data = rep.representation(using: .png, properties: [:]) {
            ok = (try? data.write(to: url)) != nil
        } else {
            ok = false
        }

        window.orderOut(nil)
        return ok
    }

    // MARK: - 造素材

    /// 造一批尺寸、色调各异的图并导入，让网格里既有横图也有竖图。
    private static func importSamples(into library: SceneLibrary) {
        let tempSources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyeguard-shot-src-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempSources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSources) }

        let specs: [(name: String, width: Int, height: Int, format: UTType, category: SceneCategory)] = [
            ("清晨的山脊.jpg",   2400, 1350, .jpeg, .mountain),
            ("午后海面.png",     1920, 1080, .png,  .ocean),
            ("林间小路.jpg",     1350, 2000, .jpeg, .forest),
            ("湖畔黄昏.png",     2560, 1440, .png,  .lake),
            ("星空.jpg",         1800, 1200, .jpeg, .starfield),
            ("我拍的窗景.png",   1600, 1000, .png,  .custom),
        ]

        var byCategory: [SceneCategory: [URL]] = [:]
        for (index, spec) in specs.enumerated() {
            guard let data = AssetImportSelfTest.makeImageData(width: spec.width,
                                                               height: spec.height,
                                                               format: spec.format,
                                                               seed: UInt64(index + 100)) else { continue }
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
