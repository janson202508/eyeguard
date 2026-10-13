import Foundation
import AppKit
import CoreGraphics

/// FR-2.2 前台全屏窗口检测。
///
/// 判定一个窗口「全屏」需要同时满足三条：
///   1. 位于普通窗口层（layer == 0）
///   2. 属于其他进程 —— 排除本程序自己的休息覆盖窗
///   3. 尺寸与某块屏幕一致，**且顶边贴住屏幕顶部**（覆盖菜单栏区域）
///
/// 第 3 条是关键。macOS 上「最大化」（zoom）的窗口顶边停在菜单栏之下，
/// 而原生全屏窗口会盖住菜单栏。用这一点把两者区分开，避免用户只要
/// 把窗口最大化就被判定为「全屏」。
///
/// 坐标系：`CGWindowListCopyWindowInfo` 返回的是屏幕坐标（原点在主屏左上），
/// 而 `NSScreen.frame` 是 Cocoa 坐标（原点在主屏左下），y 轴方向相反，需要换算。
///
/// 按规格书原则 P2「宁可顺延，不可骚扰」，误判为全屏只会多顺延一次，
/// 属于安全方向，因此允许一定程度的过度检测。
final class FullscreenMonitor {
    private let ownPID = getpid()

    // 窗口枚举在 2 Hz 的 tick 下会产生不必要的开销，做 1 秒缓存。
    // 1 秒的判定延迟对「是否弹窗」这个决策没有任何实际影响。
    private var cachedValue = false
    private var lastCheckAt = Date.distantPast
    private let cacheInterval: TimeInterval = 1

    func hasFullscreenWindow() -> Bool {
        if Date().timeIntervalSince(lastCheckAt) < cacheInterval {
            return cachedValue
        }
        lastCheckAt = Date()
        cachedValue = Self.queryFullscreenWindow(ownPID: ownPID)
        return cachedValue
    }

    private static func queryFullscreenWindow(ownPID: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let screens = screenFramesInCGSpace()
        guard !screens.isEmpty else { return false }

        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let pid = window[kCGWindowOwnerPID as String] as? Int, pid_t(pid) == ownPID { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { continue }

            for screen in screens where coversScreen(rect, screen) {
                return true
            }
        }
        return false
    }

    /// 把 NSScreen.frame（Cocoa 坐标）换算为 CGWindowList 使用的屏幕坐标。
    private static func screenFramesInCGSpace() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            return CGRect(x: frame.minX,
                          y: primaryHeight - frame.maxY,
                          width: frame.width,
                          height: frame.height)
        }
    }

    private static func coversScreen(_ rect: CGRect, _ screen: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(rect.minX - screen.minX) < tolerance
            && abs(rect.minY - screen.minY) < tolerance
            && abs(rect.width - screen.width) < tolerance
            && abs(rect.height - screen.height) < tolerance
    }
}
