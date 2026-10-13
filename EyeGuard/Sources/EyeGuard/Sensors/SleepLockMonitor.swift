import Foundation
import AppKit

/// FR-2.5 锁屏与系统休眠检测。
///
/// - 休眠 / 唤醒：`NSWorkspace.notificationCenter`
/// - 锁屏 / 解锁：`DistributedNotificationCenter` 的
///   `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
///
/// 全部为公开通知，不需要额外权限。
final class SleepLockMonitor {
    enum Event {
        case sleep
        case wake
        case lock
        case unlock
    }

    var onEvent: ((Event) -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(center: workspaceCenter, name: NSWorkspace.willSleepNotification) { [weak self] in
            self?.onEvent?(.sleep)
        }
        observe(center: workspaceCenter, name: NSWorkspace.didWakeNotification) { [weak self] in
            self?.onEvent?(.wake)
        }

        let distributed = DistributedNotificationCenter.default()
        observe(center: distributed, name: Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.onEvent?(.lock)
        }
        observe(center: distributed, name: Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.onEvent?(.unlock)
        }
    }

    deinit {
        for entry in observers {
            entry.center.removeObserver(entry.token)
        }
    }

    private func observe(center: NotificationCenter,
                         name: Notification.Name,
                         handler: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            handler()
        }
        observers.append((center, token))
    }
}
