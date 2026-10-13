import AppKit
import SwiftUI

/// 入口由 main.swift 调用（存在 main.swift 时不能用 @main）。
struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var delegate
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        Window("EyeGuard 控制台", id: "control") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动器是被用户主动打开的工具，窗口应该直接到前台
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉窗口就退出。控制台是个「打开—点一下—关掉」的工具，
    /// 留一个没有窗口的进程在后台只会让人困惑「它是不是还在跑」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
