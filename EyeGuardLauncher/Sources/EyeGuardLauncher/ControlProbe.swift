import Foundation

/// 命令行探测：不打开界面，直接问一次 EyeGuard 的状态。
///
/// 用法：`EyeGuardLauncher --probe`
/// 退出码 0 = 收到回复（EyeGuard 在运行），1 = 没收到。
///
/// 存在的理由：排查「控制台显示未运行」时，需要把「通道不通」和「界面逻辑错」
/// 分开。这条命令只依赖控制通道，与 SwiftUI 无关。
enum ControlProbe {

    static func run() -> Int32 {
        let center = DistributedNotificationCenter.default()
        var received: RemoteState?

        center.addObserver(forName: ControlProtocol.status,
                           object: nil,
                           queue: .main) { note in
            guard let info = note.userInfo, let state = RemoteState(userInfo: info) else { return }
            received = state
        }

        center.postNotificationName(ControlProtocol.control,
                                    object: nil,
                                    userInfo: ["action": ControlProtocol.Action.status.rawValue],
                                    deliverImmediately: true)

        RunLoop.main.run(until: Date().addingTimeInterval(2))

        guard let state = received else {
            print("未运行：2 秒内没有收到 EyeGuard 的回复")
            return 1
        }

        print("运行中：phase=\(state.phase.rawValue) "
              + "显示=\(state.ringText ?? "—") "
              + "间隔=\(state.intervalMinutes) 分钟 "
              + "休息时长=\(state.restDurationSeconds) 秒")
        print("说明：\(state.detail)")
        return 0
    }
}
