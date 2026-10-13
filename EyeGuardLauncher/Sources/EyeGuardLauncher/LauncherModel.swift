import AppKit
import Combine

/// 启动器的状态与操作。
///
/// 线程约定：所有入口都在主线程 —— `Timer` 挂在主 RunLoop，
/// `ControlClient` 的回调队列是 `.main`。因此这里刻意**不加 `@MainActor`**：
/// 加了之后 `DistributedNotificationCenter` 的回调（非隔离闭包）里调本类方法
/// 会编译不过，还得套 `assumeIsolated`，反而绕。
final class LauncherModel: ObservableObject {

    /// 与 EyeGuard 的连接状态
    enum Connection: Equatable {
        case unknown        // 刚开始检测，还不知道
        case launching      // 用户点了启动，或正在等首次回复
        case notRunning
        case connected(RemoteState)

        var state: RemoteState? {
            if case .connected(let state) = self { return state }
            return nil
        }

        var isRunning: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var appURL: URL?
    /// 一次性提示（错误或确认），界面用一行小字展示
    @Published var notice: String?

    private let client = ControlClient()
    private var timer: Timer?

    /// 最近一次收到回复的时刻
    private var lastReplyAt: Date?
    /// 本轮「等不到回复」是从什么时候开始的
    private var probeStartedAt: Date?
    /// 用户点「启动」的时刻
    private var launchedAt: Date?

    /// 超过这么久没有回复就算掉线
    private let staleAfter: TimeInterval = 2.5
    /// 冷启动时给首次探测的窗口
    private let firstProbeTimeout: TimeInterval = 1.2
    /// 点过启动之后，等应用起来并注册好观察者的宽限期
    private let launchGracePeriod: TimeInterval = 10

    init() {
        appURL = EyeGuardLocator.find()
        client.start(
            onState: { [weak self] state in self?.receive(state) },
            onEvent: { [weak self] event in self?.receive(event: event) }
        )
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 轮询

    func startPolling() {
        guard timer == nil else { return }
        let created = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
        tick()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        client.send(.status)

        let now = Date()

        // ① 最近有回复 → 连接正常，状态由回调更新
        if let last = lastReplyAt {
            if now.timeIntervalSince(last) < staleAfter { return }
            lastReplyAt = nil
        }

        // ② 刚点过启动 → 给更长的宽限期，别急着报「未运行」
        if let launchedAt, now.timeIntervalSince(launchedAt) < launchGracePeriod {
            connection = .launching
            return
        }

        // ③ 冷启动的首次探测窗口
        if probeStartedAt == nil { probeStartedAt = now }
        if now.timeIntervalSince(probeStartedAt!) < firstProbeTimeout { return }

        if case .notRunning = connection { return }
        connection = .notRunning
    }

    private func receive(_ state: RemoteState) {
        lastReplyAt = Date()
        probeStartedAt = nil
        launchedAt = nil
        connection = .connected(state)
        if notice != nil { notice = nil }
    }

    private func receive(event: String) {
        switch event {
        case "launched":
            // 不用等到下一秒，立刻要一份状态
            probeStartedAt = nil
            client.send(.status)

        case "terminated":
            lastReplyAt = nil
            probeStartedAt = nil
            launchedAt = nil
            connection = .notRunning

        default:
            break
        }
    }

    // MARK: - 操作

    /// 主开关：未运行 → 启动；已暂停 → 恢复；其余 → 暂停
    func togglePrimary() {
        switch connection {
        case .connected(let state):
            client.send(state.phase == .paused ? .resume : .pause)

        case .notRunning:
            launch()

        case .unknown, .launching:
            break
        }
    }

    /// 副操作：休息中 → 跳过这次；其余 → 立即休息
    func performSecondary() {
        guard let state = connection.state else { return }
        client.send(state.phase == .resting ? .skipRest : .restNow)
    }

    /// 显式暂停 / 恢复。已经在目标状态就不重复发指令 ——
    /// 重复发会让 EyeGuard 多做一次状态迁移与广播，界面会闪。
    func pause() {
        if case .connected(let state) = connection, state.phase == .paused { return }
        client.send(.pause)
    }

    func resume() {
        if case .connected(let state) = connection, state.phase != .paused { return }
        client.send(.resume)
    }

    func openSettings() {
        client.send(.openSettings)
    }

    func quitEyeGuard() {
        client.send(.quit)

        // 兜底：控制通道万一没送达，3 秒后用 LaunchServices 再请它退出一次。
        // 用户点了「退出」却退不掉，比多点一次危险得多。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.connection.isRunning else { return }
            NSRunningApplication
                .runningApplications(withBundleIdentifier: EyeGuardLocator.bundleID)
                .first?
                .terminate()
        }
    }

    func chooseApp() {
        guard let url = EyeGuardLocator.chooseManually() else { return }
        appURL = url
        notice = "已记住 EyeGuard 的位置"
    }

    // MARK: - 私有

    private func launch() {
        guard let url = appURL ?? EyeGuardLocator.find() else {
            notice = "找不到 EyeGuard.app，请点「定位…」手动指定。"
            return
        }
        appURL = url
        launchedAt = Date()
        probeStartedAt = nil
        connection = .launching

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false   // 菜单栏应用，不要抢走当前窗口的焦点

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.notice = "启动失败：\(error.localizedDescription)"
                self?.launchedAt = nil
                self?.connection = .notRunning
            }
        }
    }
}
