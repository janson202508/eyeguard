import Foundation
import AppKit

/// 休息展示层的抽象。让 Core 层不依赖 AppKit 的具体实现。
protocol RestPresenting: AnyObject {
    func present(scheduler: Scheduler)
    func dismiss()
}

/// 状态机 + 计时器。规格书 §3 的实现。
///
/// 计时全部基于单调时钟（`Monotonic`），不使用墙上时钟，避免休眠唤醒后
/// 时间跳变导致误触发（规格书 §3.3 不变量 4）。墙上时钟只用于持久化，
/// 因为跨进程重启必须有一个绝对时间参照。
final class Scheduler: ObservableObject {

    // MARK: - 对外可观察状态（驱动 UI）

    @Published private(set) var phase: Phase = .working
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var restRemainingSeconds: Int = 0
    @Published private(set) var restTotalSeconds: Int = 20
    @Published private(set) var skipUnlocked = false
    @Published private(set) var skipLockRemaining = 0
    @Published private(set) var currentAsset: SceneAsset?
    @Published private(set) var suppressionReasons: Set<SuppressionReason> = []
    @Published private(set) var isNight = false
    /// 不设 private(set)：AppEnvironment 需要订阅它的 projected value 来弹提示
    @Published var skipHintVisible = false

    /// 状态迁移回调。控制通道用它把状态主动推给启动器，
    /// 省得启动器只能靠轮询、慢一拍。
    var onPhaseChanged: (() -> Void)?

    /// 休息进度 0…1，用于环形倒计时
    var restProgress: Double {
        guard restTotalSeconds > 0 else { return 0 }
        let elapsed = restTotalSeconds - restRemainingSeconds
        return min(max(Double(elapsed) / Double(restTotalSeconds), 0), 1)
    }

    // MARK: - 依赖

    let configStore: ConfigStore
    let sceneLibrary: SceneLibrary

    weak var presenter: RestPresenting?

    private let stateStore = StateStore()
    private let evaluator: SuppressionEvaluator
    private let sleepLockMonitor = SleepLockMonitor()

    // MARK: - 内部计时状态

    private var bag = ShuffleBagState()
    private var deadlineUptime: UInt64 = 0
    private var restDeadlineUptime: UInt64 = 0
    private var skipUnlockUptime: UInt64 = 0
    private var wakeCooldownUntilUptime: UInt64 = 0
    private var isSleeping = false
    private var manualPauseUntil: Date?
    private var skipStreak = 0
    private var lastRestEndedAt: Date?
    private var currentIntervalMinutes = 0
    private var timer: Timer?
    private var lastPersistedAt = Date.distantPast
    private var lastLoggedPhase: Phase?

    private let tickInterval: TimeInterval = 0.5
    private let persistInterval: TimeInterval = 10

    /// 当前语言的文案表。UI 一律走这里取字符串。
    var strings: Strings { configStore.config.strings }

    /// 当前界面语言。
    ///
    /// 取文案走 `strings` 就够了；只有在**需要按语言分支**时才用这个 ——
    /// 图片介绍就是把两种语言都存下来、按需选一个（`SceneAsset.caption(_:)`）。
    var language: Language { configStore.config.language }

    init(configStore: ConfigStore, sceneLibrary: SceneLibrary) {
        self.configStore = configStore
        self.sceneLibrary = sceneLibrary
        self.evaluator = SuppressionEvaluator(configStore: configStore)
    }

    // MARK: - 生命周期

    func start() {
        sleepLockMonitor.onEvent = { [weak self] event in
            self?.handleSleepLock(event)
        }
        restoreState()

        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        persist()
    }

    // MARK: - 主循环

    private func tick() {
        tickInternal()
        handlePhaseTransition()
    }

    /// 状态发生迁移时：打一行日志 + 通知控制通道。
    ///
    /// 日志让测试时能直接 `2>&1 | tee` 看到完整时间线，不必盯着 UI 猜当前处在
    /// 哪个阶段（`log show` 在沙箱里读不到统一日志，只有 stderr 可靠）。
    private func handlePhaseTransition() {
        guard phase != lastLoggedPhase else { return }
        lastLoggedPhase = phase
        onPhaseChanged?()

        let detail: String
        switch phase {
        case .working, .snoozed, .prewarning:
            detail = "剩余 \(Self.mmss(remainingSeconds))"
        case .resting:
            detail = "时长 \(restTotalSeconds) 秒 · 跳过\(skipUnlocked ? "已解锁" : "锁定中")"
        case .suppressed:
            // 日志用 rawValue 而不是 displayName：这些行只有开发者在场才看，
            // 跟着界面语言变只会让「同一段日志两种语言」变得难搜。
            detail = suppressionReasons.map(\.rawValue).sorted().joined(separator: ",")
        case .paused:
            detail = "手动暂停"
        case .sleeping:
            detail = "休眠/锁屏"
        }
        NSLog("[EyeGuard] phase -> \(phase.rawValue)（\(detail)）")
    }

    private func tickInternal() {
        let now = Date()

        if now.timeIntervalSince(lastPersistedAt) >= persistInterval {
            persist()
        }

        isNight = configStore.config.isNight(at: now)
        suppressionReasons = evaluator.currentReasons(manualPauseUntil: manualPauseUntil,
                                                      isSleeping: isSleeping,
                                                      now: now)

        // 1. 休眠优先于一切
        if isSleeping {
            if phase != .sleeping { enterSleeping() }
            return
        }

        // 2. 休息中不受顺延影响
        if phase == .resting {
            tickResting()
            return
        }

        // 3. 手动暂停
        if phase == .paused { return }

        // 4. 顺延判定
        if !suppressionReasons.isEmpty {
            if phase != .suppressed { enterSuppressed() }
            return
        }

        // 5. 条件解除 → 重新开始完整计时（FR-2.7）
        if phase == .suppressed {
            startWorkInterval(phase: .working)
            return
        }

        // 6. 倒计时
        tickCountdown()
    }

    private func tickCountdown() {
        // 用户改了间隔 → 立刻按新间隔重新计时
        if phase == .working, configStore.config.workIntervalMinutes != currentIntervalMinutes {
            startWorkInterval(phase: .working)
            return
        }

        let remaining = Monotonic.secondsRemaining(until: deadlineUptime)
        let prewarning = Double(configStore.config.prewarningSeconds)

        if remaining <= 0 {
            remainingSeconds = 0
            if canTriggerRest {
                enterResting()
            } else {
                enterSuppressed()
            }
            return
        }

        remainingSeconds = Int(ceil(remaining))

        // FR-1.3：进入预告窗口
        if (phase == .working || phase == .snoozed), remaining <= prewarning {
            phase = .prewarning
        }
    }

    private func tickResting() {
        let remaining = Monotonic.secondsRemaining(until: restDeadlineUptime)
        if remaining <= 0 {
            restRemainingSeconds = 0
            finishRest(skipped: false)
            return
        }
        restRemainingSeconds = Int(ceil(remaining))

        if !skipUnlocked {
            let untilUnlock = Monotonic.secondsRemaining(until: skipUnlockUptime)
            if untilUnlock <= 0 {
                skipUnlocked = true
                skipLockRemaining = 0
            } else {
                skipLockRemaining = Int(ceil(untilUnlock))
            }
        }
    }

    /// FR-2.6：休眠唤醒或解锁后，至少等待冷却时间才允许触发提醒
    private var canTriggerRest: Bool {
        Monotonic.now >= wakeCooldownUntilUptime
            && !isSleeping
            && suppressionReasons.isEmpty
    }

    // MARK: - 状态转移

    private func startWorkInterval(phase newPhase: Phase) {
        let minutes = configStore.config.workIntervalMinutes
        let seconds = Double(minutes * 60)
        deadlineUptime = Monotonic.deadline(afterSeconds: seconds)
        remainingSeconds = Int(seconds)
        currentIntervalMinutes = minutes
        phase = newPhase
    }

    /// FR-2.7：抑制态不消耗工作时长，条件解除后重新开始完整计时
    private func enterSuppressed() {
        startWorkInterval(phase: .suppressed)
        persist()
    }

    private func enterSleeping() {
        phase = .sleeping
        persist()
    }

    private func enterResting() {
        let config = configStore.config

        currentAsset = AssetPicker.pick(pool: activeAssets, bag: &bag, isNight: isNight)

        restTotalSeconds = max(config.restDurationSeconds, 1)
        restRemainingSeconds = restTotalSeconds
        restDeadlineUptime = Monotonic.deadline(afterSeconds: Double(restTotalSeconds))

        skipUnlockUptime = Monotonic.deadline(afterSeconds: Double(config.skipUnlockSeconds))
        skipUnlocked = config.skipUnlockSeconds <= 0
        skipLockRemaining = config.skipUnlockSeconds

        phase = .resting
        presenter?.present(scheduler: self)
        persist()
    }

    private func finishRest(skipped: Bool) {
        presenter?.dismiss()
        currentAsset = nil
        lastRestEndedAt = Date()

        if skipped {
            skipStreak += 1
        } else {
            skipStreak = 0
        }

        // FR-3.6：连续跳过或延后达阈值，弹一次间隔调整建议
        let config = configStore.config
        if skipStreak >= config.skipStreakThreshold, !config.skipStreakHintDisabled {
            skipHintVisible = true
            skipStreak = 0
        }

        startWorkInterval(phase: .working)
        persist()
    }

    private func handleSleepLock(_ event: SleepLockMonitor.Event) {
        switch event {
        case .sleep, .lock:
            isSleeping = true
            phase = .sleeping
            persist()

        case .wake, .unlock:
            isSleeping = false
            wakeCooldownUntilUptime = Monotonic.deadline(
                afterSeconds: Double(configStore.config.effectiveWakeCooldownSeconds)
            )
            startWorkInterval(phase: .working)
        }
    }

    // MARK: - 用户操作

    /// FR-3.7 跳过当前休息
    func skip() {
        guard phase == .resting else { return }
        finishRest(skipped: true)
    }

    /// FR-3.5 休息中延后
    func snooze() {
        guard phase == .resting else { return }
        presenter?.dismiss()
        currentAsset = nil
        skipStreak += 1

        let minutes = configStore.config.snoozeMinutes
        deadlineUptime = Monotonic.deadline(afterSeconds: Double(minutes * 60))
        remainingSeconds = minutes * 60
        currentIntervalMinutes = minutes
        phase = .snoozed
        persist()
    }

    /// 菜单栏的「延后」，非休息态也可用
    func snoozeFromMenu() {
        if phase == .resting {
            snooze()
            return
        }
        let minutes = configStore.config.snoozeMinutes
        deadlineUptime = Monotonic.deadline(afterSeconds: Double(minutes * 60))
        remainingSeconds = minutes * 60
        currentIntervalMinutes = minutes
        phase = .snoozed
        persist()
    }

    /// 菜单栏的「立即休息」。用户主动要求，因此忽略顺延条件。
    func restNow() {
        guard phase != .resting, !isSleeping else { return }
        enterResting()
    }

    /// 当前参与轮播的素材。过滤实现见 `SceneLibrary.enabledAssets(using:)`。
    var activeAssets: [SceneAsset] {
        sceneLibrary.enabledAssets(using: configStore.config)
    }

    /// 休息中换一张背景，并把**这次休息重新计时**。
    ///
    /// ## 为什么要重新计时（2026-10-12 变更）
    ///
    /// 原实现刻意不重置，理由是「用户是来换图的，不是来重新计时的」。
    /// 但实测下来这条理由站不住：倒计时快结束时换图，新图只会闪现一两秒，
    /// 于是「换一张」在体感上等于「把这次休息作废」—— 用户会觉得自己白按了。
    /// 重新计时让每一张新图都拿到完整的休息时长，换图才真正等价于
    /// 「换一张再看一会儿」。
    ///
    /// ## 这个出口值得留
    ///
    /// 「换一张」是「跳过这次休息」的温和替代品：不想看当前这张图时，
    /// 如果没有换图这个选项，用户的下一个动作往往就是直接跳过 ——
    /// 那样连这次休息都没了。
    ///
    /// ## 刻意**不**重置 `skipUnlockUptime`
    ///
    /// 解锁延迟（FR-3.4）的作用是防止休息一开始就被反射性地跳过。
    /// 用户已经在休息里、并且正在主动操作时，重新上锁只会把人推回「跳过」，
    /// 还会造出一种新的卡顿（按了 → 之后三秒内出不去）。
    /// 一旦解锁就保持解锁 —— 这也保证「反复换图」永远不会把用户困住。
    ///
    /// ## 用 `restTotalSeconds` 而不是重读配置
    ///
    /// 它是**这次休息**的时长，也是环形倒计时 `restProgress` 的分母。
    /// 中途重读配置会让分母跳变，环会画错。
    func nextScene() {
        guard phase == .resting else { return }
        currentAsset = AssetPicker.pick(pool: activeAssets, bag: &bag, isNight: isNight)
        restRemainingSeconds = restTotalSeconds
        restDeadlineUptime = Monotonic.deadline(afterSeconds: Double(restTotalSeconds))
        persist()
    }

    func pause(minutes: Int) {
        manualPauseUntil = Date().addingTimeInterval(Double(minutes) * 60)
        phase = .paused
        suppressionReasons.insert(.manual)
        persist()
    }

    func pauseUntilTomorrow() {
        let startOfTomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        manualPauseUntil = startOfTomorrow
        phase = .paused
        suppressionReasons.insert(.manual)
        persist()
    }

    /// 无限期暂停，直到用户手动恢复。启动器的主开关走这条。
    ///
    /// 与 `pause(minutes:)` 的区别只在于 `manualPauseUntil` 为 nil：
    /// `tick()` 里 `phase == .paused` 直接 return，所以没有截止时间也不会自己醒。
    /// `statusText` 已经处理了 nil 的分支（返回「已暂停」）。
    ///
    /// 刻意**不持久化**：与「暂停 1 小时」保持一致 —— 退出程序即视为重新开始。
    /// 理由是不持久化的失效方向更安全：忘了暂停只是多被提醒一次，
    /// 忘了恢复则是护眼程序彻底静默。
    func pauseIndefinitely() {
        manualPauseUntil = nil
        phase = .paused
        persist()
    }

    func resume() {
        manualPauseUntil = nil
        suppressionReasons.remove(.manual)
        startWorkInterval(phase: .working)
        persist()
    }

    // MARK: - 间隔调整建议

    func acceptSkipHint() {
        skipHintVisible = false
        configStore.config.workIntervalMinutes = 30
        startWorkInterval(phase: .working)
    }

    /// 用户选择「保持当前间隔」：只关闭提示，下次达到阈值仍会再问
    func clearSkipHint() {
        skipHintVisible = false
    }

    func dismissSkipHint() {
        skipHintVisible = false
        configStore.config.skipStreakHintDisabled = true
    }

    // MARK: - 持久化

    private func persist() {
        var state = RuntimeState()
        state.phase = phase
        state.intervalMinutes = configStore.config.workIntervalMinutes
        state.skipStreak = skipStreak
        state.lastRestEndedAt = lastRestEndedAt
        state.bag = bag
        state.savedAt = Date()

        switch phase {
        case .working, .snoozed, .prewarning:
            state.remainingSeconds = max(Int(Monotonic.secondsRemaining(until: deadlineUptime)), 0)
        case .suppressed, .paused, .sleeping:
            state.remainingSeconds = configStore.config.workIntervalMinutes * 60
        case .resting:
            state.remainingSeconds = 0
        }

        stateStore.save(state)
        lastPersistedAt = Date()
    }

    /// FR-1.7：恢复剩余计时，避免「退出程序」成为规避提醒的捷径。
    ///
    /// 还原规则抽在 `restoredRemaining` 里，是因为这段逻辑有多个互相叠加的
    /// 兜底分支，出错时又只表现为「偶尔早提醒一次」，很难在手工测试中稳定
    /// 复现 —— 抽成纯函数后自检可以直接覆盖。
    static func restoredRemaining(saved: RuntimeState,
                                  currentIntervalMinutes: Int,
                                  idleThresholdMinutes: Int,
                                  now: Date = Date()) -> Double {
        let fullInterval = Double(currentIntervalMinutes * 60)
        let elapsedSinceSave = max(now.timeIntervalSince(saved.savedAt), 0)
        var remaining = Double(saved.remainingSeconds) - elapsedSinceSave

        // 程序未运行期间视为休息：保存时正在休息，或关闭时长已超过空闲阈值 → 重置
        if saved.phase == .resting || elapsedSinceSave >= Double(idleThresholdMinutes * 60) {
            remaining = fullInterval
        }
        // 间隔变过 → 旧的剩余秒数失去意义，重新完整计时。
        // 典型场景：用测试模式（1 分钟）跑完一轮后正常启动（20 分钟），
        // 不重置就会在启动 30 多秒后莫名其妙被提醒一次。
        if saved.intervalMinutes != currentIntervalMinutes {
            remaining = fullInterval
        }
        if remaining <= 0 || remaining > fullInterval {
            remaining = fullInterval
        }
        return remaining
    }

    private func restoreState() {
        let config = configStore.config

        guard let saved = stateStore.load() else {
            startWorkInterval(phase: .working)
            return
        }

        bag = saved.bag
        skipStreak = saved.skipStreak
        lastRestEndedAt = saved.lastRestEndedAt

        let remaining = Self.restoredRemaining(
            saved: saved,
            currentIntervalMinutes: config.workIntervalMinutes,
            idleThresholdMinutes: config.idleThresholdMinutes
        )

        deadlineUptime = Monotonic.deadline(afterSeconds: remaining)
        remainingSeconds = Int(ceil(remaining))
        currentIntervalMinutes = config.workIntervalMinutes
        phase = .working
    }

    // MARK: - 展示辅助

    /// 状态快照，供控制通道回传给启动器。
    ///
    /// ⚠️ 所有值必须是 property-list 类型 —— `DistributedNotificationCenter`
    /// 的 userInfo 会被序列化，塞入自定义类型会在运行时静默失败。
    var statusSnapshot: [String: Any] {
        var info: [String: Any] = [
            "phase": phase.rawValue,
            "remainingSeconds": remainingSeconds,
            "restRemainingSeconds": restRemainingSeconds,
            "restTotalSeconds": restTotalSeconds,
            "skipUnlocked": skipUnlocked,
            "isNight": isNight,
            "intervalMinutes": configStore.config.workIntervalMinutes,
            "restDurationSeconds": configStore.config.restDurationSeconds,
            "suppressionReasons": suppressionReasons.map(\.rawValue).sorted().joined(separator: ",")
        ]
        if let until = manualPauseUntil {
            info["pausedUntil"] = until.timeIntervalSince1970
        }
        return info
    }

    var menuBarIconName: String {
        switch phase {
        case .resting:              return "eye.circle.fill"
        case .prewarning:           return "eye.circle"
        case .suppressed:           return "eye.slash"
        case .paused, .sleeping:    return "pause.circle"
        case .working, .snoozed:    return "eye"
        }
    }

    var statusText: String {
        let s = strings
        switch phase {
        case .working, .snoozed, .prewarning:
            return s.statusNextBreak(Self.mmss(remainingSeconds))
        case .resting:
            return s.statusResting(restRemainingSeconds)
        case .suppressed:
            let reasons = suppressionReasons.map { $0.displayName(s) }
                .sorted().joined(separator: s.listSeparator)
            return reasons.isEmpty ? s.statusSuppressed : s.statusSuppressedWith(reasons)
        case .paused:
            if let until = manualPauseUntil {
                return s.statusPausedUntil(Self.clockFormatter.string(from: until))
            }
            return s.statusPaused
        case .sleeping:
            return s.statusSleeping
        }
    }

    static func mmss(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
