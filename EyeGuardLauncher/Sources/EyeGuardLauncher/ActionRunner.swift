import AppKit
import Foundation

/// 命令行动作：不打开界面，直接驱动 `LauncherModel` 的操作。
///
/// 用法：`EyeGuardLauncher --action start|pause|resume|rest|skip|quit|toggle`
///
/// 为什么需要它：验证「控制台 → EyeGuard」这条链路时，用界面点击需要
/// 「辅助功能」授权才能合成鼠标事件，在受控环境里往往给不了。
/// 这条入口走的是**和按钮完全相同的 `LauncherModel` 方法**，
/// 只把「谁来调用」从 SwiftUI 换成了命令行，链路本身照样被覆盖。
enum ActionRunner {

    static func run(_ name: String) -> Int32 {
        let model = LauncherModel()
        model.startPolling()

        // 先等连接建立，最多 6 秒
        wait(until: 6) { model.connection.isRunning }

        let wasRunning = model.connection.isRunning

        switch name {
        case "start":
            if wasRunning {
                print("EyeGuard 已在运行，无需启动")
            } else {
                model.togglePrimary()
                wait(until: 14) { model.connection.isRunning }
            }

        case "toggle", "pause", "resume", "rest", "skip":
            guard wasRunning else {
                print("EyeGuard 未运行，无法执行 \(name)")
                return 1
            }
            switch name {
            case "toggle": model.togglePrimary()
            case "pause":  model.pause()
            case "resume": model.resume()
            default:       model.performSecondary()
            }
            // 给状态机一个 tick 的时间把新状态推回来
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        case "quit":
            guard wasRunning else {
                print("EyeGuard 本来就没在运行")
                return 0
            }
            model.quitEyeGuard()
            wait(until: 10) { !model.connection.isRunning }

        default:
            print("未知动作：\(name)")
            print("可用：start / pause / resume / toggle / rest / skip / quit")
            return 2
        }

        model.stopPolling()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        print(describe(model.connection, action: name))
        return exitCode(for: model.connection, action: name)
    }

    // MARK: - 私有

    /// 转 RunLoop 直到条件成立或超时。返回是否成立。
    @discardableResult
    private static func wait(until seconds: TimeInterval,
                             _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private static func describe(_ connection: LauncherModel.Connection, action: String) -> String {
        switch connection {
        case .connected(let state):
            return "✅ 运行中：phase=\(state.phase.rawValue) "
                 + "显示=\(state.ringText ?? "—") "
                 + "间隔=\(state.intervalMinutes) 分钟"
        case .notRunning:
            return "✅ EyeGuard 未运行"
        case .launching:
            return "⚠️ 仍在启动中（超时）"
        case .unknown:
            return "⚠️ 状态未知（超时）"
        }
    }

    private static func exitCode(for connection: LauncherModel.Connection, action: String) -> Int32 {
        switch action {
        case "quit":
            return connection.isRunning ? 1 : 0
        case "start":
            return connection.isRunning ? 0 : 1
        default:
            return connection.isRunning ? 0 : 1
        }
    }
}
