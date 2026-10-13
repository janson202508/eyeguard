import Foundation

/// FR-2 顺延条件的聚合判定。
///
/// 把五类条件（空闲 / 全屏 / 摄像头 / 手动暂停 / 休眠）收敛成单一的
/// 「原因集合」。只要集合非空，本轮提醒就不弹出（规格书原则 P2）。
///
/// 注意：规格书 §FR-2 的「勿扰 / 专注模式」在 macOS 上没有公开 API，
/// v1 不作为硬依赖，由「手动暂停」替代。
final class SuppressionEvaluator {
    private let idleMonitor = IdleMonitor()
    private let fullscreenMonitor = FullscreenMonitor()
    private let cameraMonitor = CameraMonitor()
    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// 当前命中的顺延原因集合
    func currentReasons(manualPauseUntil: Date?, isSleeping: Bool, now: Date = Date()) -> Set<SuppressionReason> {
        var reasons: Set<SuppressionReason> = []
        let config = configStore.config

        if isSleeping {
            reasons.insert(.sleeping)
        }

        if let until = manualPauseUntil, until > now {
            reasons.insert(.manual)
        }

        if config.suppressOnIdle && idleMonitor.isIdle(thresholdMinutes: config.idleThresholdMinutes) {
            reasons.insert(.idle)
        }

        if config.suppressOnFullscreen && fullscreenMonitor.hasFullscreenWindow() {
            reasons.insert(.fullscreen)
        }

        if config.suppressOnCamera && cameraMonitor.isCameraInUse() {
            reasons.insert(.camera)
        }

        return reasons
    }

    /// 供设置页展示：当前空闲秒数
    var idleSeconds: TimeInterval { idleMonitor.idleSeconds }
}
