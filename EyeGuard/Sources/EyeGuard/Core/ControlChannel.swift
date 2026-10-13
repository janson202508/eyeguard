import Foundation

/// EyeGuard 与「EyeGuard 控制台」（启动器 App）之间的控制通道协议。
///
/// 为什么用 `DistributedNotificationCenter` 而不是 XPC 或 Unix socket：
/// 两个程序都是本机非沙箱应用、运行在同一用户下，这是成本最低、且**不需要
/// 任何权限、不需要 launchd 配置、不需要 socket 文件**的方案。
/// 已实测跨进程可用（含 ad-hoc 签名的两个独立二进制）。
///
/// 协议：
///   启动器 → EyeGuard   `control`   userInfo["action"]
///   EyeGuard → 启动器   `status`    完整状态快照（值必须是 property-list 类型）
///   EyeGuard → 启动器   `event`     userInfo["event"] = "launched" | "terminated"
///
/// ⚠️ 这份定义在启动器工程里有一份**必须保持一致的副本**
/// （`EyeGuardLauncher/Sources/EyeGuardLauncher/ControlProtocol.swift`）。
/// 两个工程是独立的 SPM package，共用一个 target 需要把 EyeGuard 拆成
/// library + executable 两个 target，代价大于收益。改动这里时务必同步改那边。
enum ControlProtocol {
    static let control = Notification.Name("info.xiaolu.eyeguard.control")
    static let status  = Notification.Name("info.xiaolu.eyeguard.status")
    static let event   = Notification.Name("info.xiaolu.eyeguard.event")

    enum Action: String {
        /// 请求一次状态快照。启动器每秒发一次，用来做心跳 + 刷新倒计时。
        case status
        /// 无限期暂停，直到用户手动恢复。启动器的主开关用它。
        case pause
        case resume
        case restNow
        case skipRest
        case openSettings
        case quit
    }
}

/// 控制通道的服务端（跑在 EyeGuard 里）。
final class ControlChannel {
    private let center = DistributedNotificationCenter.default()
    private let handle: (ControlProtocol.Action) -> Void
    private let snapshot: () -> [String: Any]
    private var observer: NSObjectProtocol?

    init(handle: @escaping (ControlProtocol.Action) -> Void,
         snapshot: @escaping () -> [String: Any]) {
        self.handle = handle
        self.snapshot = snapshot
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func start() {
        observer = center.addObserver(forName: ControlProtocol.control,
                                      object: nil,
                                      queue: .main) { [weak self] note in
            guard let raw = note.userInfo?["action"] as? String,
                  let action = ControlProtocol.Action(rawValue: raw) else {
                NSLog("[EyeGuard] 控制通道收到无法识别的指令：\(String(describing: note.userInfo))")
                return
            }
            self?.handle(action)
        }

        // 宣告启动：已经开着的控制台可以立刻刷新，不必等下一次轮询。
        post(ControlProtocol.event, ["event": "launched"])
    }

    /// 状态变化时主动推一次，让控制台不必等到下一次轮询才更新。
    func broadcastStatus() {
        post(ControlProtocol.status, snapshot())
    }

    func announceTermination() {
        post(ControlProtocol.event, ["event": "terminated"])
    }

    private func post(_ name: Notification.Name, _ info: [String: Any]) {
        center.postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }
}
