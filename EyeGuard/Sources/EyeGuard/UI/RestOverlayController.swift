import AppKit
import SwiftUI

/// 无边框全屏覆盖窗。
///
/// 层级 `.screenSaver`，可跨 Space 显示。规格书 FR-3.9 的关键结论：
/// 因为全屏应用场景已被顺延规则覆盖，这个窗口**不需要**具备盖住原生全屏
/// 应用的能力，从而绕开了 macOS 上最难实现的部分（原生全屏应用独占 Space）。
///
/// 需要 `canBecomeKey == true`，否则无边框窗口无法接收 Esc 键。
///
/// ## 键盘
///
/// `Esc` 走 SwiftUI 的 `onExitCommand`（见 `RestView.body`），这里只管
/// **左右方向键换图**（FR-3.12）。
///
/// 为什么不在 SwiftUI 里给按钮挂 `.keyboardShortcut(.leftArrow, modifiers: [])`：
/// 那要求按钮处在焦点体系里，而这个无边框窗口既没有菜单栏、也没有初始焦点，
/// 快捷键最终注册到哪条响应链上是不确定的。方向键在这里是一等公民
/// （休息时用户唯一会反复按的键），放在窗口层显式处理，行为可预期、也好测
/// （见 `--probe-keys`）。
final class RestOverlayWindow: NSWindow {

    /// 按下 ← 或 → 时调用。
    ///
    /// 两个方向都做「换一张」，不区分上下张 —— 选片器是**只进不退**的洗牌袋
    /// （`AssetPicker.pick` 消费 `bag`），本来就没有「上一张」这个概念。
    /// 硬造一个需要额外的历史栈，还会和「袋耗尽前不重复」的约束打架。
    var onNextScene: (() -> Void)?

    init(overlayFrame: NSRect) {
        super.init(contentRect: overlayFrame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = false
    }

    required init?(coder: NSCoder) {
        fatalError("RestOverlayWindow 不支持从归档加载")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124:                       // ← 或 →
            // 按住不放会连续触发。这里**刻意忽略重复事件**，一次按键只换一张。
            // 原因不是手感，是磁盘：`nextScene()` 末尾会 `persist()` 写一次
            // state.json，而系统按键重复率最高约每秒 30 次 —— 按住不放会把
            // 状态文件打成每秒几十次写入，同时每次换图还要重新解码一张 1920px
            // 的图。一次一按既没有这个问题，也符合「浏览」而不是「快进」的语义。
            guard !event.isARepeat else { return }
            onNextScene?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// 休息层的展示控制器。
///
/// 负责：多屏策略、渐入渐出、以及**焦点还原** —— 展示前记录当前前台应用，
/// 关闭后把焦点还回去，避免用户回到工作时发现自己「被切走了」。
final class RestOverlayController: RestPresenting {
    private var windows: [RestOverlayWindow] = []
    private var previousApp: NSRunningApplication?

    /// FR-3.12 的键盘监听句柄。展示时装上，收起时摘掉。
    private var keyMonitor: Any?

    /// 休息期间 ← / → 的动作。
    private var onNextScene: (() -> Void)?

    /// 键盘**走两条路**，这不是冗余，是因为两条路的前置条件不同：
    ///
    ///   1. **本地事件监听器**（`NSEvent.addLocalMonitorForEvents`）——
    ///      只要**应用活跃**就能收到，不要求窗口是 key window。
    ///   2. **`RestOverlayWindow.keyDown`** —— 要求窗口是 key window。
    ///
    /// 为什么以监听器为主：实测发现「窗口有没有成为 key window」从进程外
    /// **观测不到**，只能靠推理。而「应用活跃」是可以直接观测的 ——
    /// 用 `lsappinfo front` 一看就知道。既然一个前提可验证、另一个不可验证，
    /// 就应该把正确性建立在可验证的那个上面。
    /// （已实测：展示期间 `lsappinfo front` 返回 `EyeGuard`，应用确实在前台。）
    ///
    /// 两条路不会重复触发：监听器处理完会 `return nil` 把事件吃掉，
    /// 后面那条路根本看不到它。窗口那条留着是为了「监听器万一没装上」时兜底。
    ///
    /// 用法见 `--probe-keys` —— 探针里两种投递方式各测一遍，
    /// `NSApp.sendEvent` 走的是窗口那条路，`postEvent → nextEvent` 走的是监听器那条。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.windows.isEmpty else { return event }
            guard event.keyCode == 123 || event.keyCode == 124 else { return event }
            // 按住不放会连续触发；`nextScene()` 末尾会写 state.json，
            // 系统按键重复率最高约每秒 30 次，不挡会把状态文件打爆。
            // 一次按键换一张，既没有这个问题，也符合「浏览」而不是「快进」。
            guard !event.isARepeat else { return nil }
            self.onNextScene?()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    func present(scheduler: Scheduler) {
        previousApp = NSWorkspace.shared.frontmostApplication
        teardownWindows()

        onNextScene = { [weak scheduler] in scheduler?.nextScene() }
        installKeyMonitor()

        let screens = targetScreens(for: scheduler.configStore.config.displayTarget)
        NSLog("[EyeGuard] present: 系统屏幕 \(NSScreen.screens.count) 块，选中 \(screens.count) 块，displayTarget=\(scheduler.configStore.config.displayTarget.rawValue)")
        guard !screens.isEmpty else {
            NSLog("[EyeGuard] present: 未选中任何屏幕，放弃展示")
            return
        }

        for screen in screens {
            let window = RestOverlayWindow(overlayFrame: screen.frame)
            window.contentView = NSHostingView(rootView: RestView(scheduler: scheduler))
            window.setFrame(screen.frame, display: true)
            window.alphaValue = 0
            // FR-3.12 ← / → 换图。多屏时每个窗口都挂同一个动作，
            // 实际只有 key window 会收到按键，不会重复触发。
            window.onNextScene = { [weak scheduler] in scheduler?.nextScene() }
            // orderFrontRegardless 不受「应用必须是活跃应用」的限制 ——
            // 对一个要接管全屏的提醒程序来说这是必须的
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        NSLog("[EyeGuard] present: 已创建 \(windows.count) 个窗口，frame=\(windows.first?.frame.debugDescription ?? "nil")")

        // FR-1.4 渐入。完成回调里做兜底：动画若被系统跳过（应用未激活、
        // 或开启了「减弱动态效果」），alpha 会永远停在 0，画面将完全不可见。
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            self.windows.forEach { $0.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            let stillInvisible = self.windows.filter { $0.alphaValue < 1 }
            if !stillInvisible.isEmpty {
                NSLog("[EyeGuard] present: 渐入未生效，兜底置为不透明（\(stillInvisible.count) 个窗口）")
                stillInvisible.forEach { $0.alphaValue = 1 }
            }
            self.windows.forEach { $0.orderFrontRegardless() }
        })
    }

    func dismiss() {
        removeKeyMonitor()
        onNextScene = nil
        guard !windows.isEmpty else { return }
        let closing = windows
        windows = []

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            closing.forEach { $0.orderOut(nil) }
            guard let self, self.windows.isEmpty else { return }
            self.previousApp?.activate()
            self.previousApp = nil
        })
    }

    private func teardownWindows() {
        removeKeyMonitor()
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func targetScreens(for target: DisplayTarget) -> [NSScreen] {
        switch target {
        case .allScreens:
            return NSScreen.screens

        case .mainScreen:
            return NSScreen.main.map { [$0] } ?? Array(NSScreen.screens.prefix(1))

        case .mouseScreen:
            let mouseLocation = NSEvent.mouseLocation
            if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
                return [hit]
            }
            return NSScreen.main.map { [$0] } ?? Array(NSScreen.screens.prefix(1))
        }
    }
}
