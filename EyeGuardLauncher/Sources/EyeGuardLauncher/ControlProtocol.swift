import Foundation

/// 控制通道协议 —— **必须与 EyeGuard 侧保持一致**。
///
/// 原始定义在 `EyeGuard/Sources/EyeGuard/Core/ControlChannel.swift`。
/// 两个工程是独立的 SPM package，共用一个 target 需要把 EyeGuard 拆成
/// library + executable 两个 target，代价大于收益，所以这里是刻意的副本。
/// **改一边务必改另一边**，否则表现是「按钮点了没反应」这种最难查的静默失败。
enum ControlProtocol {
    static let control = Notification.Name("info.xiaolu.eyeguard.control")
    static let status  = Notification.Name("info.xiaolu.eyeguard.status")
    static let event   = Notification.Name("info.xiaolu.eyeguard.event")

    enum Action: String {
        case status
        case pause
        case resume
        case restNow
        case skipRest
        case openSettings
        case quit
    }
}
