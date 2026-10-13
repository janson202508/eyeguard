import AppKit
import Combine
import ServiceManagement

/// 依赖装配与生命周期。所有单例都从这里取，避免散落的 `shared`。
final class AppEnvironment {
    static let shared = AppEnvironment()

    let configStore: ConfigStore
    let sceneLibrary: SceneLibrary
    let scheduler: Scheduler

    private let overlayController = RestOverlayController()
    private var cancellables: Set<AnyCancellable> = []
    private var controlChannel: ControlChannel?

    private init() {
        AppPaths.ensureDirectories()
        configStore = ConfigStore()
        sceneLibrary = SceneLibrary()
        scheduler = Scheduler(configStore: configStore,
                              sceneLibrary: sceneLibrary)
    }

    func start() {
        scheduler.presenter = overlayController
        SettingsWindowController.shared.attach(scheduler: scheduler)

        // FR-3.6：连续跳过达到阈值后弹一次间隔调整建议
        scheduler.$skipHintVisible
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.presentSkipHint() }
            .store(in: &cancellables)

        // FR-7.4：登录项跟随配置变化
        configStore.$config
            .map(\.launchAtLogin)
            .removeDuplicates()
            .dropFirst()
            .sink { enabled in Self.applyLaunchAtLogin(enabled) }
            .store(in: &cancellables)

        Self.applyLaunchAtLogin(configStore.config.launchAtLogin)

        // --test-mode：开发者测试模式。常规最小间隔是 15 分钟，验证「自动触发」
        // 这条核心路径每轮都要等 15 分钟，迭代成本高到没人愿意测。打开后间隔
        // 解锁到 1 分钟、休息 5 秒，完整循环约 65 秒。设置面板里可随时关掉。
        //
        // 必须在 scheduler.start() 之前设置：start() 内部会 restoreState()，
        // 而它按 config.workIntervalMinutes 还原剩余计时。放在之后会让首轮
        // 仍按旧间隔起算，日志里会看到「剩余 20:00」这种误导性的首行。
        //
        // 同时挂起配置落盘：测试档位只活在本次进程内存里。否则 1 分钟间隔
        // 会被写进 config.json，用户下次正常启动就被 1 分钟提醒一次。
        if CommandLine.arguments.contains("--test-mode") {
            configStore.persistenceSuspended = true
            configStore.config.testModeEnabled = true
            configStore.config.workIntervalMinutes = 1
            configStore.config.restDurationSeconds = 5
            NSLog("[EyeGuard] 测试模式已开启：间隔 1 分钟 / 休息 5 秒 / 唤醒冷却 5 秒（仅本次运行，不写入配置）")
        }

        scheduler.start()

        // 控制通道：让「EyeGuard 控制台」（启动器 App）能启停与控制本程序。
        // 放在 scheduler.start() 之后，保证被控制时状态机已经在跑。
        let channel = ControlChannel(
            handle: { [weak self] action in self?.handleControl(action) },
            snapshot: { [weak self] in self?.scheduler.statusSnapshot ?? [:] }
        )
        controlChannel = channel
        channel.start()
        scheduler.onPhaseChanged = { [weak self] in self?.controlChannel?.broadcastStatus() }

        // --preview：启动后立即展示一次休息画面，用于预览与验收，
        // 省去等满一个提醒间隔。
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.scheduler.restNow()
            }
        }
    }

    func stop() {
        controlChannel?.announceTermination()
        scheduler.stop()
    }

    // MARK: - 控制通道

    /// 处理来自启动器的指令。
    ///
    /// 每条会改变状态的指令都紧跟一次 `broadcastStatus()`：状态机的
    /// `onPhaseChanged` 要等到下一次 tick（最多 0.5 秒）才推状态，
    /// 而按钮按下去到界面更新之间不该有可见延迟。
    private func handleControl(_ action: ControlProtocol.Action) {
        switch action {
        case .status:
            controlChannel?.broadcastStatus()

        case .pause:
            scheduler.pauseIndefinitely()
            controlChannel?.broadcastStatus()

        case .resume:
            scheduler.resume()
            controlChannel?.broadcastStatus()

        case .restNow:
            scheduler.restNow()
            controlChannel?.broadcastStatus()

        case .skipRest:
            scheduler.skip()
            controlChannel?.broadcastStatus()

        case .openSettings:
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.shared.show()

        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: - 间隔调整建议

    private func presentSkipHint() {
        NSApp.activate(ignoringOtherApps: true)

        let s = configStore.config.strings
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = s.noticeSkipTitle
        alert.informativeText = s.noticeSkipBody(configStore.config.workIntervalMinutes)
        alert.addButton(withTitle: s.noticeSkipAction30)
        alert.addButton(withTitle: s.noticeSkipActionKeep)
        alert.addButton(withTitle: s.noticeSkipActionMute)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            scheduler.acceptSkipHint()
        case .alertThirdButtonReturn:
            scheduler.dismissSkipHint()
        default:
            scheduler.clearSkipHint()
        }
    }

    // MARK: - 登录项

    private static func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
            }
        } catch {
            NSLog("[EyeGuard] 登录项设置失败：\(error.localizedDescription)")
        }
    }
}
