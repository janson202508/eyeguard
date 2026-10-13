import AppKit
import SwiftUI

/// 程序化风景。规格书附录 A 的 50 张内置素材。
///
/// 这一层只做两件事：**缓存**与**贴图**。绘制全部在 `ScenePainter` 里
/// （纯 CoreGraphics），这样自检可以把 50 张渲染成像素做两两比对 ——
/// 而「50 张看起来是不是 50 张」恰恰是早期版本真正的缺陷：
/// 同一类别共用一套配色与形态参数，观感上退化成十来张扁平的图。
struct PlaceholderSceneView: View {
    let asset: SceneAsset
    let isNight: Bool

    var body: some View {
        GeometryReader { proxy in
            if let image = SceneImageCache.image(for: asset,
                                                 size: proxy.size,
                                                 isNight: isNight) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                Color.black
            }
        }
        .background(Color.black)
    }
}

/// 渲染结果缓存。
///
/// 两个理由：
///
///   1. 休息页每 0.5 秒重算一次视图（倒计时在走），没有缓存就会每半秒
///      重画一遍满分辨率画面；
///   2. 换图时 `Image(decorative:)` 拿到的是另一张 `CGImage`，视图身份
///      随之改变，**必然重绘** —— 不再依赖 SwiftUI 对「只换了闭包捕获」
///      这类变化的比较策略。
///
/// 容量刻意很小（4 张）：一张满分辨率 CGImage 约 10–20MB，
/// 而任何时刻真正在显示的只有一张。缓存是给「同一张反复贴图」用的，
/// 不是给整个素材库用的。
@MainActor
enum SceneImageCache {
    private static var cache: [String: CGImage] = [:]
    private static var order: [String] = []
    private static let capacity = 4

    static func image(for asset: SceneAsset, size: CGSize, isNight: Bool) -> CGImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // 尺寸向上取整到 64 的倍数：多屏切换时避免因为几像素差异重画
        let width = max(Int(size.width / 64 + 1) * 64, 320)
        let height = max(Int(size.height / 64 + 1) * 64, 200)
        let key = "\(asset.id)|\(width)x\(height)|\(isNight ? "n" : "d")"

        if let hit = cache[key] { return hit }

        guard let image = ScenePainter.makeImage(asset: asset,
                                                 size: CGSize(width: width, height: height),
                                                 isNight: isNight,
                                                 scale: scale) else {
            return nil
        }

        cache[key] = image
        order.append(key)
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return image
    }

    static func invalidate() {
        cache.removeAll()
        order.removeAll()
    }
}
