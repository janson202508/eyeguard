import AppKit
import SwiftUI

/// 在**真实屏幕**上走一遍生产展示路径，并报告各控件的实际坐标。
///
/// 用法：`EyeGuard --probe-overlay`（配合 `EYEGUARD_LAYOUT_PROBE=1`）
///
/// ## 为什么需要它
///
/// `RestShot` 用的是「自己造一个无边框窗、把 frame 设成固定值」的离屏宿主。
/// 那个宿主能证明「画出来是什么样」，但证明不了**生产窗口**的几何：
/// 生产用的是 `RestOverlayWindow`（`.screenSaver` 层级、真屏坐标、会激活应用），
/// 而且窗口尺寸来自 `NSScreen.frame`。窗口一旦不是「整屏」，
/// 或者宿主视图的 frame 与窗口不一致，控件的位置就会和离屏结果不一样。
///
/// 这类差异正是「控件跑到屏幕外」最容易藏身的地方，所以这里刻意
/// **复刻 `RestOverlayController` 的完整展示流程**，只在中间插入测量。
enum OverlayProbe {

    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempHome = NSTemporaryDirectory() + "eyeguard-overlayprobe-\(UUID().uuidString)"
        setenv("EYEGUARD_HOME", tempHome, 1)
        defer {
            unsetenv("EYEGUARD_HOME")
            try? FileManager.default.removeItem(atPath: tempHome)
        }

        let configStore = ConfigStore()
        configStore.persistenceSuspended = true
        let scheduler = Scheduler(configStore: configStore,
                                  sceneLibrary: SceneLibrary())
        let controller = RestOverlayController()
        scheduler.presenter = controller

        if let screen = NSScreen.main {
            print("屏幕 frame       \(NSStringFromRect(screen.frame))")
            print("屏幕 visibleFrame \(NSStringFromRect(screen.visibleFrame))")
        }
        print("屏幕数量 \(NSScreen.screens.count)")

        scheduler.restNow()
        settle(1.2)

        for window in NSApp.windows where window.isVisible {
            let insets = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            print(String(format: "真实窗口 frame %@  contentView.frame %@  安全区 上%.0f 下%.0f",
                         NSStringFromRect(window.frame),
                         NSStringFromRect(window.contentView?.frame ?? .zero),
                         insets.top, insets.bottom))
            print("      level=\(window.level.rawValue)  屏幕 frame 高度=\(NSScreen.main?.frame.height ?? 0)")
        }

        var round = 1
        report(round)
        for _ in 0..<5 {
            scheduler.nextScene()
            settle(0.7)
            round += 1
            report(round)
        }

        // 抓一张真实窗口的内容，作为「屏幕上实际长什么样」的证据
        if let window = NSApp.windows.first(where: { $0.isVisible }),
           let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eyeguard-overlay-probe.png")
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                print("已写出 \(url.path)")
            }
        }

        controller.dismiss()
        settle(0.6)
        return 0
    }

    private static func report(_ round: Int) {
        print("── 第 \(round) 次 ──")
        LayoutProbe.report(windowSize: NSScreen.main?.frame.size ?? .zero)
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
