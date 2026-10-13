import AppKit
import SwiftUI

/// 设置窗口控制器。
///
/// 没有用 SwiftUI 的 `Settings` scene，原因是它的打开方式在不同 macOS 版本上
/// 差异较大（macOS 13 用 `showSettingsWindow:`，14+ 用 `SettingsLink`）。
/// 自己持有一个 NSWindow 更可控，也避免为兼容做版本分支。
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private weak var scheduler: Scheduler?

    private init() {}

    func attach(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    func show() {
        guard let scheduler else { return }

        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(
                configStore: scheduler.configStore,
                scheduler: scheduler,
                sceneLibrary: scheduler.sceneLibrary
            ))

            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = scheduler.strings.settingsWindowTitle
            created.contentView = hosting
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        // 标题**每次打开都重设**。窗口是缓存的（`window == nil` 只成立一次），
        // 只在创建时设一次的话，用户改完界面语言再打开设置，标题会一直停在旧语言上。
        window?.title = scheduler.strings.settingsWindowTitle

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
