import Foundation
import CoreGraphics

/// 布局探针。开发期自查用，**默认完全不工作**。
///
/// ## 它解决什么问题
///
/// 「控件跑到窗口外面去了」这类缺陷，靠读代码是看不出来的：
/// `ZStack` 的最终尺寸由子视图撑开，而子视图又能拿到比窗口更大的尺寸。
/// 结果是**画面看上去正常，控件却在窗口边界之外**——即点不到、也看不见。
///
/// 离屏渲染（`RestShot`）能抓到「画出来是什么样」，但抓不到
/// 「控件落在窗口的哪个坐标」：一旦控件跑出 `view.bounds`，
/// 位图里根本没有它的像素，你只知道「少了点什么」，不知道少了多少、为什么少。
///
/// 所以这里记录**每个关键视图在窗口坐标系里的 frame**，
/// 再和窗口自身尺寸一比，就能直接判定「在不在视野内、超出多少」。
///
/// ## 用法
///
/// 设 `EYEGUARD_LAYOUT_PROBE=1` 后，`RestView` 里的探针会把自己和子视图的
/// frame 写进这里；`--shot-rest` 每拍一张就 `report()` 一次。
/// 不设这个环境变量时，探针不产生任何视图、也不记录任何东西。
enum LayoutProbe {

    /// 每次读环境变量，不用 `static let` 缓存：
    /// 缓存会在首次访问时定死，而 `--shot-rest` 需要在自己的进程里打开它。
    /// 同理不用 `ProcessInfo.environment`（Foundation 会缓存它，见 AppPaths 的注释）。
    static var enabled: Bool {
        guard let raw = getenv("EYEGUARD_LAYOUT_PROBE") else { return false }
        return String(cString: raw) == "1"
    }

    private static let lock = NSLock()
    private static var frames: [String: CGRect] = [:]

    /// 视图每次布局都会调用它 —— 这里必须允许重复写入（后写的覆盖先写的）。
    static func record(_ label: String, _ rect: CGRect) {
        guard enabled else { return }
        lock.lock()
        frames[label] = rect
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    private static func snapshot() -> [(String, CGRect)] {
        lock.lock()
        defer { lock.unlock() }
        return frames.sorted { $0.key < $1.key }
    }

    /// 判定一个 frame 有没有跑出窗口，以及超出的量。
    private static func verdict(for rect: CGRect, windowSize: CGSize) -> (text: String, overflow: Bool) {
        let bottom = max(0, rect.maxY - windowSize.height)
        let right = max(0, rect.maxX - windowSize.width)
        let top = max(0, -rect.minY)
        let left = max(0, -rect.minX)
        if bottom > 0.5 || right > 0.5 || top > 0.5 || left > 0.5 {
            return (String(format: "!! 超出 下%.1f 右%.1f 上%.1f 左%.1f", bottom, right, top, left), true)
        }
        return ("在视野内", false)
    }

    /// 超出窗口范围的控件个数。0 表示「所有控件都点得到」。
    static func outOfViewCount(windowSize: CGSize) -> Int {
        guard enabled else { return 0 }
        return snapshot().filter { verdict(for: $0.1, windowSize: windowSize).overflow }.count
    }

    /// 把当前记录到的 frame 和窗口尺寸对照着打出来。
    ///
    /// - Parameter windowSize: 窗口的点尺寸。任何 `maxY > windowSize.height`
    ///   或 `maxX > windowSize.width` 的视图都在视野之外。
    static func report(windowSize: CGSize) {
        guard enabled else { return }
        let entries = snapshot()
        guard !entries.isEmpty else {
            print("     [探针] 没有记录到任何 frame")
            return
        }
        print(String(format: "     [探针] 窗口 %.0f x %.0f", windowSize.width, windowSize.height))
        for (label, rect) in entries {
            let (text, _) = verdict(for: rect, windowSize: windowSize)
            print(String(format: "       %-18@ x %6.1f..%6.1f  y %6.1f..%6.1f   %@",
                         label as NSString, rect.minX, rect.maxX, rect.minY, rect.maxY,
                         text as NSString))
        }
    }
}
