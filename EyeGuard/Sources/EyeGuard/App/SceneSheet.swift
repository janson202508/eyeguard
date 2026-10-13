import AppKit
import CoreGraphics
import Foundation

/// 50 张内置素材的总览图。开发期自查用。
///
/// 用法：`EyeGuard --shot-sheet <输出目录>`
///
/// ## 为什么需要它
///
/// 「50 张素材看起来是不是 50 张」是个**观感**问题，但它可以被量化为
/// 「两两像素差异是否足够大」。自检负责那道数值门槛（见 `SceneSheet`
/// 对应的自检项），而人眼还需要一张图一眼看清有没有「同一张换了个噪声种子」
/// 的情况 —— 数值达标但看着雷同，同样是缺陷。
///
/// 网格顺序与 `SceneLibrary.builtInPool()` 一致，同时把
/// 序号与 id 打到 stdout，便于定位到具体是哪一张。
enum SceneSheet {

    private static let columns = 8
    private static let rows = 7
    private static let cell = CGSize(width: 300, height: 188)

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("无法创建输出目录：\(error.localizedDescription)")
            return 1
        }

        let assets = SceneLibrary.builtInPool()
        guard !assets.isEmpty else {
            print("没有内置素材可渲染")
            return 1
        }

        let width = Int(cell.width) * columns
        let height = Int(cell.height) * rows
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            print("无法创建画布")
            return 1
        }

        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var drawnFromFile = 0
        for (index, asset) in assets.enumerated() {
            let column = index % columns
            let row = index / columns
            guard row < rows else { break }

            let rect = CGRect(x: CGFloat(column) * cell.width,
                              y: CGFloat(rows - row - 1) * cell.height,
                              width: cell.width,
                              height: cell.height)
            // 预置素材现在是真实照片，必须优先画文件；程序化渲染只是
            // bundle 里没有素材时的兜底。总览图要反映 App 实际会显示的东西。
            if let image = fileImage(for: asset, fitting: cell) {
                drawnFromFile += 1
                context.draw(image, in: rect)
            } else {
                guard let image = ScenePainter.makeImage(asset: asset,
                                                         size: cell,
                                                         isNight: false,
                                                         scale: 1) else { continue }
                context.draw(image, in: rect)
            }
            print(String(format: "%2d  列%02d 行%d  %@", index, column, row, asset.id))
        }

        guard let sheet = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])
        else {
            print("无法编码 PNG")
            return 1
        }

        // 文件名里的张数**不能写死**（曾固定叫「-50张」，扩容到 392 张后名不符实）。
        let url = directory.appendingPathComponent("内置素材-\(assets.count)张总览.png")
        do {
            try data.write(to: url)
            print("已写出 \(url.path)")
            print("其中来自真实图片：\(drawnFromFile)/\(assets.count)")
            return 0
        } catch {
            print("写入失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// 按 cell 的宽高比居中裁剪，避免总览图里出现被拉伸变形的图。
    private static func fileImage(for asset: SceneAsset, fitting cell: CGSize) -> CGImage? {
        guard let url = AppPaths.imageURL(for: asset),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let targetAspect = cell.width / cell.height
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var crop = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        if imageAspect > targetAspect {
            crop.size.width = CGFloat(image.height) * targetAspect
            crop.origin.x = (CGFloat(image.width) - crop.size.width) / 2
        } else {
            crop.size.height = CGFloat(image.width) / targetAspect
            crop.origin.y = (CGFloat(image.height) - crop.size.height) / 2
        }
        return image.cropping(to: crop)
    }
}
