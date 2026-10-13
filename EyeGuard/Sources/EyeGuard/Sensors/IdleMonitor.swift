import Foundation
import CoreGraphics

/// FR-2.1 用户空闲检测。
///
/// 使用 `CGEventSource.secondsSinceLastEventType` 读取「自最后一次任意输入事件
/// 以来的秒数」。这是公开 API，不需要辅助功能或输入监控权限。
final class IdleMonitor {
    /// 自最后一次任意输入事件以来的秒数
    var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        )
    }

    /// 空闲是否已达到阈值。规格书 FR-2.1 默认 5 分钟。
    func isIdle(thresholdMinutes: Int) -> Bool {
        idleSeconds >= Double(thresholdMinutes) * 60
    }
}
