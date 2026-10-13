import SwiftUI
import AppKit

/// 入口由 main.swift 调用（存在 main.swift 时不能用 @main）。
struct EyeGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(scheduler: AppEnvironment.shared.scheduler)
        } label: {
            MenuBarLabel(scheduler: AppEnvironment.shared.scheduler)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不占用 Dock 与 Cmd-Tab
        NSApp.setActivationPolicy(.accessory)
        AppEnvironment.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
