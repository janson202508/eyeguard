import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 生成应用图标（`.iconset`，再由 `iconutil` 打成 `.icns`）。
///
/// 用代码画而不是往仓库里放一个 `.icns` 二进制：图标只有「渐变底 + 一只眼睛」，
/// 代码生成让它能随品牌色调整，也免去在版本控制里塞二进制文件。
///
/// 全程走 CoreGraphics（不用 AppKit 的 `NSImage.lockFocus`），因为这段代码是
/// 在构建脚本里以命令行方式跑的，不应该依赖窗口服务器。
enum AppIconMaker {

    /// `iconutil` 要求的文件名与像素尺寸对照表。
    /// 注意 16/32/128/256/512 各出现两次（1x 与 2x 共用同一像素尺寸）。
    static let entries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var cache: [Int: CGImage] = [:]
        for entry in entries {
            let image: CGImage
            if let cached = cache[entry.pixels] {
                image = cached
            } else {
                image = try render(pixels: entry.pixels)
                cache[entry.pixels] = image
            }
            try write(image, to: directory.appendingPathComponent(entry.name))
        }
    }

    static func render(pixels: Int) throws -> CGImage {
        let size = CGFloat(pixels)
        let space = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(data: nil,
                                      width: pixels,
                                      height: pixels,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IconError.contextCreationFailed
        }

        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)

        // ── 圆角底。macOS 图标的惯例：四周留约 5.5% 边距，圆角半径约 22.37% 边长
        let inset = size * 0.055
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = rect.width * 0.2237

        context.saveGState()
        context.addPath(CGPath(roundedRect: rect,
                               cornerWidth: radius,
                               cornerHeight: radius,
                               transform: nil))
        context.clip()

        let colors = [
            CGColor(srgbRed: 0.11, green: 0.33, blue: 0.50, alpha: 1),
            CGColor(srgbRed: 0.24, green: 0.66, blue: 0.70, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.maxY),
                                       end: CGPoint(x: rect.maxX, y: rect.minY),
                                       options: [])
        }
        context.restoreGState()

        // ── 眼睛：上下两条二次贝塞尔围成杏仁形。
        // 控制点偏移取 lid*2，二次曲线的实际峰值在控制点的一半处，
        // 于是眼高 = 2 * lid，眼宽 = 2 * halfWidth。
        let cx = size / 2
        let cy = size / 2
        let halfWidth = size * 0.315
        let lid = size * 0.175

        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: cx - halfWidth, y: cy))
        eye.addQuadCurve(to: CGPoint(x: cx + halfWidth, y: cy),
                         control: CGPoint(x: cx, y: cy + lid * 2))
        eye.addQuadCurve(to: CGPoint(x: cx - halfWidth, y: cy),
                         control: CGPoint(x: cx, y: cy - lid * 2))
        eye.closeSubpath()

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(eye)
        context.fillPath()

        // ── 瞳孔：用深底色画一个圆落在白色眼球上
        let irisRadius = size * 0.105
        context.setFillColor(CGColor(srgbRed: 0.09, green: 0.29, blue: 0.44, alpha: 1))
        context.fillEllipse(in: CGRect(x: cx - irisRadius,
                                       y: cy - irisRadius,
                                       width: irisRadius * 2,
                                       height: irisRadius * 2))

        guard let image = context.makeImage() else { throw IconError.renderFailed }
        return image
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw IconError.writeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IconError.writeFailed(url.lastPathComponent)
        }
    }

    enum IconError: LocalizedError {
        case contextCreationFailed
        case renderFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed: return "无法创建绘图上下文"
            case .renderFailed:          return "无法生成位图"
            case .writeFailed(let name): return "无法写入 \(name)"
            }
        }
    }
}
