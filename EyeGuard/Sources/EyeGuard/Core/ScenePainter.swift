import CoreGraphics
import Foundation

/// 程序化风景绘制器。纯 CoreGraphics，不依赖 SwiftUI。
///
/// ## 为什么存在
///
/// 新装、还没导入任何照片时，休息画面不能是一块纯色 —— 这个程序的全部意义
/// 是让人「抬头看远处」，而画面本身是那个动作的引子。因此程序化场景不是
/// 装饰，它是默认状态下的唯一画面来源。
///
/// ## 为什么从 SwiftUI Canvas 搬到 CoreGraphics
///
/// 早期版本用 `Canvas` 直接画，有两个问题：
///
///   1. **每次 tick（0.5 秒）视图重算就重画一遍**，纯属浪费；
///   2. 更要紧的是 —— 「50 张素材看起来是不是 50 张」这件事**没法自动验证**。
///
/// 搬成纯函数之后，自检可以把 50 张全部渲染成像素做两两比对，把
/// 「不雷同」从「id 不同」变成「像素不同」。这是这次改动的真正动机：
/// 之前 50 张里有大量看起来一模一样的，而靠肉眼抽查永远发现不了。
///
/// ## 观感上的硬指标
///
/// 「不雷同」和「有纵深」都要可验证，因此每条都对应一个可检查的构造：
///
/// | 指标 | 构造手段 |
/// |---|---|
/// | 同类别的 6 张彼此可辨 | 每张独立抽「时段」（黎明/上午/正午/黄昏/暮色/夜） |
/// | 同上 | 每张独立抽形态：层数、地平线高度、起伏、频率、主峰位置 |
/// | 有纵深 | 空气透视：越远越向天色混合，层内自上而下渐变 |
/// | 有纵深 | 近层细节多、远层细节少（八度数随距离衰减） |
/// | 有纵深 | 尺度参照：飞鸟、水面倒影、光晕 |
/// | 纵深与元数据一致 | 直接读 `asset.depthScore` 决定层数与雾化强度 |
struct ScenePainter {

    // MARK: - 对外入口

    /// 渲染一张。`size` 为逻辑尺寸，`scale` 为像素倍率。
    ///
    /// 同一组 `(asset.id, isNight, size)` 永远得到逐像素一致的结果。
    static func makeImage(asset: SceneAsset,
                          size: CGSize,
                          isNight: Bool,
                          scale: CGFloat = 2) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width >= 16, height >= 16 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let recipe = makeRecipe(asset: asset, isNight: isNight)
        draw(recipe, in: context, size: CGSize(width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    // MARK: - 配方

    /// 天体装饰类型。刻意不叫 `none`，避免与 `Optional.none` 产生歧义。
    /// 用 `fileprivate` 而不是 `private`：`BasePalette` 在同一个文件里但
    /// 不在 `ScenePainter` 内，`private` 会让它看不见这个类型。
    fileprivate enum Celestial { case sun, moon, stars, nothing }

    private struct Recipe {
        var skyTop: RGB
        var skyMid: RGB
        var skyHorizon: RGB
        var horizonY: Double
        var layers: [Layer]
        var celestial: Celestial
        var celestialX: Double
        var celestialY: Double
        var celestialRadius: Double
        var cloudCount: Int
        var starCount: Int
        var milkyWay: Bool
        var hasWater: Bool
        var birdCount: Int
        var seed: UInt64
        /// 时段整体的分通道增益，用来给整幅画统一打光
        var gain: (Double, Double, Double)
    }

    private struct Layer {
        var color: RGB
        /// 0…1，越大越向天色混合（越远）
        var haze: Double
        var baseY: Double
        var amplitude: Double
        var frequency: Double
        var octaves: Int
        var peakiness: Double
        var ridged: Bool
        var seed: UInt64
        var heroX: Double?
        var heroHeight: Double
        var gradientDepth: Double
    }

    private static func makeRecipe(asset: SceneAsset, isNight: Bool) -> Recipe {
        // 形态只由 id 决定，与昼夜无关 —— 同一处风景换个光，而不是换一个地方
        var shape = SplitMix64(seed: stableSeed(asset.id))
        // 配色与时段另起一路随机流，避免加一个参数就把所有形态推倒重来
        var palette = SplitMix64(seed: stableSeed(asset.id) &+ 0x5EED_1A7E)

        let base = BasePalette.of(asset.category)

        // depthScore 是元数据，也是构图参数：分越高越「远」
        let depth = min(max((asset.depthScore - 3.0) / 2.0, 0), 1)

        // 时段：夜间强制冷暗时段，白天按 tone 挑 ——
        // 这条约束是为了让 tone 元数据不撒谎：暖调素材不会在正午被画成冷色，
        // 冷调素材也不会在黄昏被画成暖色。
        let timeOfDay: TimeOfDay
        if isNight {
            timeOfDay = palette.unit() < 0.62 ? .night : .twilight
        } else {
            let options = TimeOfDay.dayOptions(for: asset.tone)
            timeOfDay = options[Int(palette.unit() * Double(options.count)) % options.count]
        }

        // 每张素材自己的色彩抖动：色相微移 + 明度/饱和度缩放
        let hueJitter = palette.range(-0.030, 0.030)
        let satJitter = palette.range(0.88, 1.16)
        let brightJitter = palette.range(0.90, 1.10)

        func shade(_ color: RGB) -> RGB {
            color.adjusted(hueShift: hueJitter,
                           saturationScale: satJitter * timeOfDay.saturation,
                           brightnessScale: brightJitter * timeOfDay.brightness)
                .gain(timeOfDay.gain)
        }

        let skyTop = shade(base.skyTop)
        let skyMid = shade(base.skyHorizon)
        let skyHorizon = skyMid.blended(with: timeOfDay.horizonTint,
                                       amount: timeOfDay.horizonTintAmount)

        let horizonY = base.hasWater
            ? shape.range(0.42, 0.58)
            : shape.range(0.30, 0.48)

        let layerCount = 3 + Int((depth * 3).rounded())          // 3…6 层
        let perspective = shape.range(0.85, 1.75)
        let freqScale = shape.range(0.75, 1.35)
        let ampScale = shape.range(0.80, 1.28)
        let hazeTop = shape.range(0.52, 0.82) * (0.72 + 0.28 * depth)

        var layers: [Layer] = []
        for index in 0..<layerCount {
            let d = Double(index) / Double(max(layerCount - 1, 1))   // 0 = 最远

            let baseY: Double
            let amplitude: Double
            if base.hasWater {
                // 水面场景：所有山脊都压在水线上方，倒影另画
                baseY = horizonY - 0.012 * (1 - d) * perspective
                amplitude = base.amplitude * ampScale * (0.30 + 0.70 * (1 - d))
            } else {
                baseY = horizonY + (1 - horizonY) * pow(d, perspective)
                amplitude = base.amplitude * ampScale * (0.32 + 0.95 * pow(d, 1.25))
            }

            let heroRoll = shape.unit()
            let isNear = d > 0.55

            layers.append(Layer(
                color: shade(base.ridges[index % base.ridges.count]),
                haze: hazeTop * pow(1 - d, 1.15),
                baseY: baseY,
                amplitude: amplitude,
                // 近层细节多、远层细节少 —— 这是空气透视的一半
                frequency: base.frequency * freqScale * (1 + 0.75 * d),
                octaves: 2 + Int((d * 3).rounded()),
                peakiness: base.peakiness * shape.range(0.85, 1.20),
                ridged: base.ridged,
                seed: shape.next(),
                // 主峰只给近层，且不是每张都有 —— 有无主峰本身就是很强的形态差异
                heroX: (isNear && heroRoll < 0.5) ? shape.range(0.18, 0.82) : nil,
                heroHeight: shape.range(0.45, 1.15),
                gradientDepth: 0.10 + 0.10 * d
            ))
        }

        let celestialKind: Celestial = {
            if isNight { return base.celestial == .sun ? .moon : base.celestial }
            return base.celestial
        }()

        let celestialX = shape.range(0.16, 0.84)
        // 有水面时把天体压到地平线附近，倒影里才有一条光路
        let celestialY = base.hasWater
            ? horizonY * shape.range(0.42, 0.72)
            : horizonY * shape.range(0.14, 0.40)

        let starCount: Int = {
            if celestialKind == .stars { return isNight || timeOfDay.isDark ? 240 : 190 }
            return timeOfDay.isDark ? 150 : 0
        }()

        return Recipe(
            skyTop: skyTop,
            skyMid: skyMid,
            skyHorizon: skyHorizon,
            horizonY: horizonY,
            layers: layers,
            celestial: celestialKind,
            celestialX: celestialX,
            celestialY: celestialY,
            celestialRadius: shape.range(0.026, 0.042),
            cloudCount: timeOfDay.cloudRange.lowerBound
                + Int(shape.unit() * Double(timeOfDay.cloudRange.count)),
            starCount: starCount,
            milkyWay: celestialKind == .stars && shape.unit() < 0.55,
            hasWater: base.hasWater,
            birdCount: timeOfDay.isDark ? 0
                : (base.allowBirds && shape.unit() < 0.45
                   ? 3 + Int(shape.unit() * 5)
                   : 0),
            seed: shape.next(),
            gain: timeOfDay.gain
        )
    }

    // MARK: - 绘制

    private static func draw(_ recipe: Recipe, in context: CGContext, size: CGSize) {
        // 翻成 y 向下增长，和「地平线在上、近景在下」的心智模型一致
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let horizonY = size.height * recipe.horizonY

        drawSky(recipe, in: context, size: size, horizonY: horizonY)
        if recipe.milkyWay { drawMilkyWay(recipe, in: context, size: size, horizonY: horizonY) }
        if recipe.starCount > 0 {
            drawStars(recipe, in: context, size: size, horizonY: horizonY)
        }
        drawCelestial(recipe, in: context, size: size, horizonY: horizonY)
        if recipe.cloudCount > 0 {
            drawClouds(recipe, in: context, size: size, horizonY: horizonY)
        }
        drawLayers(recipe, in: context, size: size, horizonY: horizonY)
        if recipe.hasWater {
            drawWater(recipe, in: context, size: size, horizonY: horizonY)
        }
        if recipe.birdCount > 0 {
            drawBirds(recipe, in: context, size: size, horizonY: horizonY)
        }
    }

    /// 天空。三档渐变：天顶 → 中层 → 地平线，最下一档再向「时段色调」偏，
    /// 这是日出/日落那种贴地平线的暖带。
    private static func drawSky(_ recipe: Recipe,
                               in context: CGContext,
                               size: CGSize,
                               horizonY: CGFloat) {
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [recipe.skyTop.cg, recipe.skyMid.cg, recipe.skyHorizon.cg] as CFArray,
            locations: [0, 0.62, 1]
        )
        guard let gradient else { return }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: horizonY + 1))
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: horizonY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func drawCelestial(_ recipe: Recipe,
                                     in context: CGContext,
                                     size: CGSize,
                                     horizonY: CGFloat) {
        let center = CGPoint(x: size.width * recipe.celestialX,
                             y: size.height * recipe.celestialY)
        let radius = size.height * recipe.celestialRadius

        switch recipe.celestial {
        case .sun, .moon:
            // 光晕：没有它画面就是一排纯色块，有了它才有「光从哪来」
            let glowRadius = radius * (recipe.celestial == .sun ? 7.5 : 5.0)
            let glowColor = recipe.celestial == .sun
                ? recipe.skyMid.blended(with: RGB(r: 1, g: 0.95, b: 0.82), amount: 0.55)
                : recipe.skyMid.blended(with: RGB(r: 0.85, g: 0.90, b: 1.0), amount: 0.45)
            if let glow = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [glowColor.alpha(recipe.celestial == .sun ? 0.55 : 0.34),
                         glowColor.alpha(0)] as CFArray,
                locations: [0, 1]
            ) {
                context.drawRadialGradient(glow,
                                           startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: glowRadius,
                                           options: [])
            }

            let discColor = recipe.celestial == .sun
                ? RGB(r: 1.0, g: 0.97, b: 0.90)
                : RGB(r: 0.97, g: 0.97, b: 0.93)
            context.setFillColor(discColor.alpha(recipe.celestial == .sun ? 0.95 : 0.92))
            context.fillEllipse(in: CGRect(x: center.x - radius,
                                           y: center.y - radius,
                                           width: radius * 2,
                                           height: radius * 2))

        case .stars, .nothing:
            break
        }
    }

    private static func drawStars(_ recipe: Recipe,
                                 in context: CGContext,
                                 size: CGSize,
                                 horizonY: CGFloat) {
        var rng = SplitMix64(seed: recipe.seed &+ 0x51A2)
        let band = horizonY * 0.98
        for _ in 0..<recipe.starCount {
            let x = size.width * rng.unit()
            let y = band * rng.unit()
            let brightness = rng.range(0.25, 1.0)
            // 少数亮星稍大，制造星等差异 —— 均匀的点阵看起来像噪点
            let radius = size.height * (brightness > 0.93 ? rng.range(0.0022, 0.0034)
                                                         : rng.range(0.0006, 0.0016))
            context.setFillColor(RGB(r: 1, g: 1, b: 1).alpha(brightness))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
        }
    }

    /// 银河带。一条斜向的密集星带，是「星空」与「夜空」最省事的区分手段。
    private static func drawMilkyWay(_ recipe: Recipe,
                                    in context: CGContext,
                                    size: CGSize,
                                    horizonY: CGFloat) {
        var rng = SplitMix64(seed: recipe.seed &+ 0x3A17)
        let startX = size.width * rng.range(-0.1, 0.35)
        let endX = size.width * rng.range(0.65, 1.1)
        let startY = horizonY * rng.range(0.05, 0.35)
        let endY = horizonY * rng.range(0.55, 0.95)
        let bandWidth = size.height * rng.range(0.05, 0.10)

        for _ in 0..<420 {
            let t = rng.unit()
            let centerX = startX + (endX - startX) * t
            let centerY = startY + (endY - startY) * t
            let spread = bandWidth * rng.range(-0.5, 0.5)
            let x = centerX + spread
            let y = centerY + spread * rng.range(-0.35, 0.35)
            guard y > 0, y < horizonY else { continue }
            let radius = size.height * rng.range(0.0004, 0.0011)
            let alpha = rng.range(0.06, 0.30) * (1 - abs(spread) / (bandWidth * 0.5))
            context.setFillColor(RGB(r: 0.92, g: 0.93, b: 1.0).alpha(max(alpha, 0)))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
        }
    }

    private static func drawClouds(_ recipe: Recipe,
                                  in context: CGContext,
                                  size: CGSize,
                                  horizonY: CGFloat) {
        var rng = SplitMix64(seed: recipe.seed &+ 0xC10D)
        let cloudColor = recipe.skyMid.blended(with: RGB(r: 1, g: 1, b: 1), amount: 0.45)

        for _ in 0..<recipe.cloudCount {
            let centerX = size.width * rng.range(0.05, 0.95)
            let centerY = horizonY * rng.range(0.12, 0.78)
            let width = size.width * rng.range(0.10, 0.30)
            let height = size.height * rng.range(0.012, 0.030)
            let alpha = rng.range(0.10, 0.26)
            let puffs = 3 + Int(rng.unit() * 4)

            for _ in 0..<puffs {
                let offsetX = width * rng.range(-0.45, 0.45)
                let offsetY = height * rng.range(-0.6, 0.6)
                let scale = rng.range(0.55, 1.0)
                context.setFillColor(cloudColor.alpha(alpha * scale))
                context.fillEllipse(in: CGRect(
                    x: centerX + offsetX - width * 0.5 * scale,
                    y: centerY + offsetY - height * scale,
                    width: width * scale,
                    height: height * 2 * scale
                ))
            }
        }
    }

    private static func drawLayers(_ recipe: Recipe,
                                  in context: CGContext,
                                  size: CGSize,
                                  horizonY: CGFloat) {
        // 由远到近：后面的层盖住前面的层，天然形成遮挡关系
        for layer in recipe.layers {
            let path = ridgePath(layer, size: size,
                                 bottomY: recipe.hasWater ? horizonY : size.height)
            let topY = size.height * layer.baseY - size.height * layer.amplitude
            let bottomY = recipe.hasWater ? horizonY : size.height

            // 层内渐变：上缘偏亮（受大气散射影响最强），下缘偏暗。
            // 早期版本每层是纯色填充，这正是「扁平」的主要来源。
            let top = layer.color.blended(with: recipe.skyHorizon,
                                          amount: layer.haze + layer.gradientDepth * 0.55)
            let bottom = layer.color.blended(with: recipe.skyHorizon,
                                             amount: layer.haze * 0.78)
                .brightened(1 - layer.gradientDepth * 0.55)

            context.saveGState()
            context.addPath(path)
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top.cg, bottom.cg] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(gradient,
                                           start: CGPoint(x: 0, y: topY),
                                           end: CGPoint(x: 0, y: bottomY),
                                           options: [.drawsBeforeStartLocation,
                                                     .drawsAfterEndLocation])
            } else {
                context.setFillColor(bottom.cg)
                context.fill(CGRect(x: 0, y: topY, width: size.width, height: bottomY - topY))
            }
            context.restoreGState()
        }
    }

    /// 水面。倒影 + 光路 + 横向波纹，三者都在强化「往远处延伸」。
    private static func drawWater(_ recipe: Recipe,
                                 in context: CGContext,
                                 size: CGSize,
                                 horizonY: CGFloat) {
        var rng = SplitMix64(seed: recipe.seed &+ 0x7A7E)

        let near = recipe.skyHorizon.blended(with: RGB(r: 0.05, g: 0.08, b: 0.12),
                                             amount: 0.35)
            .gain(recipe.gain)
        let far = recipe.skyHorizon.brightened(0.98).blended(with: recipe.skyHorizon, amount: 0.5)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: horizonY, width: size.width, height: size.height - horizonY))

        // 水面：靠近水线处反射天空（亮），越近越暗
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [far.cg, near.cg] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: horizonY),
                                       end: CGPoint(x: 0, y: size.height),
                                       options: [.drawsBeforeStartLocation,
                                                 .drawsAfterEndLocation])
        }

        // 倒影：把最近的两层山脊沿水线镜像、纵向压扁
        let reflections = recipe.layers.suffix(2)
        for layer in reflections {
            let squash = 0.34
            let mirrored = ridgePath(layer, size: size, bottomY: horizonY, mirror: true,
                                     squash: squash)
            context.setFillColor(layer.color
                .blended(with: recipe.skyHorizon, amount: 0.45)
                .alpha(0.40))
            context.addPath(mirrored)
            context.fillPath()
        }

        // 天体在水面上的光路：一串横向短亮条，间距随距离拉大 —— 透视线索
        if recipe.celestial == .sun || recipe.celestial == .moon {
            let columnX = size.width * recipe.celestialX
            let waterDepth = size.height - horizonY
            for _ in 0..<46 {
                let t = pow(rng.unit(), 1.7)
                let y = horizonY + waterDepth * t
                let halfWidth = size.width * (0.012 + 0.16 * t) * rng.range(0.35, 1.0)
                let height = size.height * (0.0018 + 0.004 * t)
                let alpha = (0.28 - 0.20 * t) * rng.range(0.4, 1.0)
                context.setFillColor(RGB(r: 1, g: 0.97, b: 0.90).alpha(max(alpha, 0)))
                context.fill(CGRect(x: columnX - halfWidth, y: y,
                                    width: halfWidth * 2, height: height))
            }
        }

        // 普通波纹
        for _ in 0..<40 {
            let t = pow(rng.unit(), 1.5)
            let y = horizonY + (size.height - horizonY) * t
            let x = size.width * rng.unit()
            let halfWidth = size.width * (0.008 + 0.05 * t) * rng.range(0.3, 1.0)
            let height = size.height * (0.0012 + 0.0022 * t)
            context.setFillColor(RGB(r: 1, g: 1, b: 1).alpha(rng.range(0.03, 0.12)))
            context.fill(CGRect(x: x - halfWidth, y: y, width: halfWidth * 2, height: height))
        }

        context.restoreGState()
    }

    /// 飞鸟。作用不是装饰，是**尺度参照** —— 有已知大小的东西在天上飞，
    /// 远处那个地平线才显得「远」。
    private static func drawBirds(_ recipe: Recipe,
                                 in context: CGContext,
                                 size: CGSize,
                                 horizonY: CGFloat) {
        var rng = SplitMix64(seed: recipe.seed &+ 0xB1D5)
        context.setStrokeColor(recipe.skyHorizon.blended(with: RGB(r: 0.1, g: 0.1, b: 0.12),
                                                         amount: 0.55).alpha(0.65))
        context.setLineWidth(max(size.height * 0.0016, 1))

        for _ in 0..<recipe.birdCount {
            let x = size.width * rng.range(0.08, 0.92)
            let y = horizonY * rng.range(0.10, 0.62)
            let span = size.height * rng.range(0.006, 0.014)
            context.move(to: CGPoint(x: x - span, y: y))
            context.addQuadCurve(to: CGPoint(x: x, y: y),
                                 control: CGPoint(x: x - span * 0.5, y: y - span * 0.55))
            context.addQuadCurve(to: CGPoint(x: x + span, y: y),
                                 control: CGPoint(x: x + span * 0.5, y: y - span * 0.55))
            context.strokePath()
        }
    }

    // MARK: - 山脊线

    private static func ridgePath(_ layer: Layer,
                                  size: CGSize,
                                  bottomY: CGFloat,
                                  mirror: Bool = false,
                                  squash: Double = 1) -> CGPath {
        let samples = 128
        let path = CGMutablePath()
        let baseY = size.height * layer.baseY
        let amplitude = size.height * layer.amplitude

        func point(_ index: Int) -> CGPoint {
            let x = size.width * Double(index) / Double(samples)
            let offset = ridgeOffset(layer, x: Double(index) / Double(samples)) * amplitude
            let y = baseY - offset
            if mirror {
                return CGPoint(x: x, y: baseY + (baseY - y) * squash)
            }
            return CGPoint(x: x, y: y)
        }

        path.move(to: point(0))
        for index in 1...samples {
            path.addLine(to: point(index))
        }
        path.addLine(to: CGPoint(x: size.width, y: bottomY))
        path.addLine(to: CGPoint(x: 0, y: bottomY))
        path.closeSubpath()
        return path
    }

    /// 返回 -1…1 的起伏量（1 表示高出基准线一个 amplitude）
    private static func ridgeOffset(_ layer: Layer, x: Double) -> Double {
        var n = fbm(x * layer.frequency, octaves: layer.octaves, seed: layer.seed)
        if layer.ridged {
            // 1-|2n-1|：把平滑噪声折成尖峰，这是山脉与沙丘的分界
            n = 1 - abs(2 * n - 1)
        }
        n = pow(max(n, 0), layer.peakiness)

        var value = (n - 0.5) * 2
        if let heroX = layer.heroX {
            // 高斯主峰：单峰构图与「一排小山包」的差别一眼可辨
            let distance = (x - heroX) / 0.16
            value += layer.heroHeight * exp(-distance * distance)
        }
        return value
    }

    // MARK: - 噪声

    private static func hash01(_ index: Int, seed: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15 &+ seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    private static func valueNoise(_ x: Double, seed: UInt64) -> Double {
        let base = Int(floor(x))
        let fraction = x - Double(base)
        let smooth = fraction * fraction * (3 - 2 * fraction)
        return hash01(base, seed: seed) * (1 - smooth) + hash01(base + 1, seed: seed) * smooth
    }

    private static func fbm(_ x: Double,
                            octaves: Int,
                            seed: UInt64) -> Double {
        var sum = 0.0
        var amplitude = 1.0
        var frequency = 1.0
        var normal = 0.0
        for octave in 0..<max(octaves, 1) {
            sum += amplitude * valueNoise(x * frequency,
                                          seed: seed &+ UInt64(octave) &* 0x9E37_79B9)
            normal += amplitude
            amplitude *= 0.5
            frequency *= 2.07
        }
        return normal > 0 ? sum / normal : 0
    }
}

// MARK: - 颜色

/// 线性 sRGB 分量。自己实现 HSB 换算而不是走 `NSColor`，
/// 是为了让这个绘制器能在纯 CoreGraphics 环境（自检）里跑。
struct RGB {
    var r: Double
    var g: Double
    var b: Double

    var cg: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

    func alpha(_ value: Double) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: min(max(value, 0), 1))
    }

    func blended(with other: RGB, amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        return RGB(r: r + (other.r - r) * t,
                   g: g + (other.g - g) * t,
                   b: b + (other.b - b) * t)
    }

    func brightened(_ factor: Double) -> RGB {
        RGB(r: min(r * factor, 1), g: min(g * factor, 1), b: min(b * factor, 1))
    }

    /// 分通道增益。用来给整幅画统一打光（黄昏偏暖、暮色偏紫），
    /// 比单纯调明度更能表达「什么时候的光」。
    func gain(_ values: (Double, Double, Double)) -> RGB {
        RGB(r: min(max(r * values.0, 0), 1),
            g: min(max(g * values.1, 0), 1),
            b: min(max(b * values.2, 0), 1))
    }

    func adjusted(hueShift: Double,
                  saturationScale: Double,
                  brightnessScale: Double) -> RGB {
        let maxValue = max(r, max(g, b))
        let minValue = min(r, min(g, b))
        let delta = maxValue - minValue

        var hue = 0.0
        if delta > 1e-9 {
            if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue <= 1e-9 ? 0 : delta / maxValue

        var newHue = (hue + hueShift).truncatingRemainder(dividingBy: 1)
        if newHue < 0 { newHue += 1 }
        let newSaturation = min(max(saturation * saturationScale, 0), 1)
        let newValue = min(max(maxValue * brightnessScale, 0), 1)

        let sector = Int(newHue * 6) % 6
        let fraction = newHue * 6 - Double(Int(newHue * 6))
        let p = newValue * (1 - newSaturation)
        let q = newValue * (1 - fraction * newSaturation)
        let t = newValue * (1 - (1 - fraction) * newSaturation)

        switch sector {
        case 0: return RGB(r: newValue, g: t, b: p)
        case 1: return RGB(r: q, g: newValue, b: p)
        case 2: return RGB(r: p, g: newValue, b: t)
        case 3: return RGB(r: p, g: q, b: newValue)
        case 4: return RGB(r: t, g: p, b: newValue)
        default: return RGB(r: newValue, g: p, b: q)
        }
    }
}

// MARK: - 时段

/// 时段。它是「同类别的 6 张彼此可辨」最主要的手段 ——
/// 同一座山在黎明、正午、黄昏、夜里，比同一座山换六个噪声种子差异大得多。
private enum TimeOfDay: CaseIterable {
    case dawn, morning, noon, dusk, twilight, night

    /// 白天可用的时段。按 `Tone` 过滤，保证元数据不撒谎：
    /// 暖调素材不会被画成冷色，冷调素材也不会被画成暖色。
    static func dayOptions(for tone: Tone) -> [TimeOfDay] {
        switch tone {
        case .warm:    return [.dawn, .dusk, .noon]
        case .cool:    return [.morning, .noon, .twilight]
        case .neutral: return [.morning, .noon, .dawn, .dusk]
        }
    }

    var isDark: Bool { self == .night || self == .twilight }

    /// 整幅画的分通道增益
    var gain: (Double, Double, Double) {
        switch self {
        case .dawn:     return (1.10, 0.99, 0.93)
        case .morning:  return (1.04, 1.02, 0.99)
        case .noon:     return (1.00, 1.00, 1.01)
        case .dusk:     return (1.18, 0.89, 0.73)
        case .twilight: return (0.92, 0.90, 1.07)
        case .night:    return (0.74, 0.84, 1.06)
        }
    }

    var brightness: Double {
        switch self {
        case .dawn:     return 0.94
        case .morning:  return 1.03
        case .noon:     return 1.06
        case .dusk:     return 0.90
        case .twilight: return 0.70
        case .night:    return 0.46
        }
    }

    var saturation: Double {
        switch self {
        case .dawn:     return 1.06
        case .morning:  return 1.02
        case .noon:     return 0.92
        case .dusk:     return 1.16
        case .twilight: return 0.96
        case .night:    return 0.74
        }
    }

    /// 贴地平线的暖带/冷带颜色
    var horizonTint: RGB {
        switch self {
        case .dawn:     return RGB(r: 1.00, g: 0.80, b: 0.62)
        case .morning:  return RGB(r: 1.00, g: 0.96, b: 0.88)
        case .noon:     return RGB(r: 0.94, g: 0.97, b: 1.00)
        case .dusk:     return RGB(r: 1.00, g: 0.63, b: 0.39)
        case .twilight: return RGB(r: 0.64, g: 0.57, b: 0.88)
        case .night:    return RGB(r: 0.17, g: 0.23, b: 0.46)
        }
    }

    var horizonTintAmount: Double {
        switch self {
        case .dawn:     return 0.34
        case .morning:  return 0.16
        case .noon:     return 0.10
        case .dusk:     return 0.44
        case .twilight: return 0.40
        case .night:    return 0.50
        }
    }

    var cloudRange: ClosedRange<Int> {
        switch self {
        case .dawn:     return 2...5
        case .morning:  return 2...6
        case .noon:     return 2...6
        case .dusk:     return 3...6
        case .twilight: return 1...3
        case .night:    return 0...2
        }
    }
}

// MARK: - 类别底稿

/// 每个类别的「底稿」：一组基础色 + 形态倾向。时段与素材抖动都叠在它上面。
private struct BasePalette {
    var skyTop: RGB
    var skyHorizon: RGB
    var ridges: [RGB]
    var celestial: ScenePainter.Celestial
    var ridged: Bool
    var frequency: Double
    var amplitude: Double
    var peakiness: Double
    var hasWater: Bool
    var allowBirds: Bool

    static func of(_ category: SceneCategory) -> BasePalette {
        switch category {
        case .custom:
            // 用户导入的图片走真实照片渲染，正常不会落到这里。
            // 只有导入的文件后来丢失时才会兜底 —— 刻意用低饱和中性色，
            // 让「这张图不见了」看起来就是「没图」，而不是伪装成一幅风景。
            return BasePalette(
                skyTop: RGB(r: 0.20, g: 0.21, b: 0.24),
                skyHorizon: RGB(r: 0.34, g: 0.35, b: 0.39),
                ridges: [RGB(r: 0.27, g: 0.28, b: 0.31),
                         RGB(r: 0.21, g: 0.22, b: 0.25),
                         RGB(r: 0.15, g: 0.16, b: 0.18)],
                celestial: .nothing, ridged: true, frequency: 1.2,
                amplitude: 0.05, peakiness: 1.0, hasWater: false, allowBirds: false)

        case .mountain:
            return BasePalette(
                skyTop: RGB(r: 0.09, g: 0.20, b: 0.31),
                skyHorizon: RGB(r: 0.43, g: 0.61, b: 0.77),
                ridges: [RGB(r: 0.24, g: 0.37, b: 0.51),
                         RGB(r: 0.17, g: 0.29, b: 0.41),
                         RGB(r: 0.11, g: 0.20, b: 0.28),
                         RGB(r: 0.06, g: 0.12, b: 0.17)],
                celestial: .sun, ridged: true, frequency: 1.5,
                amplitude: 0.105, peakiness: 1.35, hasWater: false, allowBirds: true)

        case .ocean:
            return BasePalette(
                skyTop: RGB(r: 0.17, g: 0.37, b: 0.53),
                skyHorizon: RGB(r: 0.66, g: 0.80, b: 0.88),
                ridges: [RGB(r: 0.18, g: 0.42, b: 0.57),
                         RGB(r: 0.12, g: 0.31, b: 0.43),
                         RGB(r: 0.07, g: 0.20, b: 0.29)],
                celestial: .sun, ridged: false, frequency: 1.1,
                amplitude: 0.022, peakiness: 1.0, hasWater: true, allowBirds: true)

        case .forest:
            return BasePalette(
                skyTop: RGB(r: 0.50, g: 0.66, b: 0.55),
                skyHorizon: RGB(r: 0.79, g: 0.86, b: 0.77),
                ridges: [RGB(r: 0.24, g: 0.42, b: 0.31),
                         RGB(r: 0.17, g: 0.32, b: 0.24),
                         RGB(r: 0.11, g: 0.23, b: 0.16),
                         RGB(r: 0.07, g: 0.14, b: 0.10)],
                celestial: .nothing, ridged: true, frequency: 3.4,
                amplitude: 0.048, peakiness: 1.6, hasWater: false, allowBirds: false)

        case .lake:
            return BasePalette(
                skyTop: RGB(r: 0.29, g: 0.43, b: 0.59),
                skyHorizon: RGB(r: 0.72, g: 0.81, b: 0.89),
                ridges: [RGB(r: 0.31, g: 0.43, b: 0.57),
                         RGB(r: 0.20, g: 0.31, b: 0.43),
                         RGB(r: 0.13, g: 0.20, b: 0.29),
                         RGB(r: 0.08, g: 0.14, b: 0.20)],
                celestial: .moon, ridged: true, frequency: 1.4,
                amplitude: 0.055, peakiness: 1.25, hasWater: true, allowBirds: true)

        case .desert:
            return BasePalette(
                skyTop: RGB(r: 0.79, g: 0.55, b: 0.29),
                skyHorizon: RGB(r: 0.94, g: 0.82, b: 0.63),
                ridges: [RGB(r: 0.72, g: 0.48, b: 0.27),
                         RGB(r: 0.59, g: 0.38, b: 0.23),
                         RGB(r: 0.43, g: 0.27, b: 0.17)],
                celestial: .sun, ridged: false, frequency: 1.3,
                amplitude: 0.058, peakiness: 1.0, hasWater: false, allowBirds: false)

        case .snow:
            return BasePalette(
                skyTop: RGB(r: 0.62, g: 0.75, b: 0.86),
                skyHorizon: RGB(r: 0.89, g: 0.93, b: 0.96),
                ridges: [RGB(r: 0.78, g: 0.85, b: 0.90),
                         RGB(r: 0.66, g: 0.75, b: 0.83),
                         RGB(r: 0.53, g: 0.64, b: 0.74),
                         RGB(r: 0.39, g: 0.51, b: 0.61)],
                celestial: .nothing, ridged: true, frequency: 1.6,
                amplitude: 0.090, peakiness: 1.3, hasWater: false, allowBirds: false)

        case .starfield:
            return BasePalette(
                skyTop: RGB(r: 0.02, g: 0.03, b: 0.06),
                skyHorizon: RGB(r: 0.06, g: 0.10, b: 0.18),
                ridges: [RGB(r: 0.04, g: 0.06, b: 0.13),
                         RGB(r: 0.02, g: 0.04, b: 0.08)],
                celestial: .stars, ridged: true, frequency: 1.7,
                amplitude: 0.070, peakiness: 1.4, hasWater: false, allowBirds: false)

        case .grassland:
            return BasePalette(
                skyTop: RGB(r: 0.44, g: 0.63, b: 0.77),
                skyHorizon: RGB(r: 0.81, g: 0.88, b: 0.91),
                ridges: [RGB(r: 0.48, g: 0.63, b: 0.35),
                         RGB(r: 0.36, g: 0.50, b: 0.27),
                         RGB(r: 0.25, g: 0.36, b: 0.19)],
                celestial: .sun, ridged: false, frequency: 1.0,
                amplitude: 0.036, peakiness: 1.0, hasWater: false, allowBirds: true)

        case .canyon:
            return BasePalette(
                skyTop: RGB(r: 0.72, g: 0.48, b: 0.31),
                skyHorizon: RGB(r: 0.91, g: 0.79, b: 0.63),
                ridges: [RGB(r: 0.66, g: 0.39, b: 0.24),
                         RGB(r: 0.53, g: 0.29, b: 0.17),
                         RGB(r: 0.37, g: 0.20, b: 0.13)],
                celestial: .sun, ridged: true, frequency: 1.8,
                amplitude: 0.125, peakiness: 1.5, hasWater: false, allowBirds: true)

        case .aerial:
            return BasePalette(
                skyTop: RGB(r: 0.36, g: 0.53, b: 0.68),
                skyHorizon: RGB(r: 0.77, g: 0.85, b: 0.90),
                ridges: [RGB(r: 0.50, g: 0.63, b: 0.74),
                         RGB(r: 0.37, g: 0.51, b: 0.63),
                         RGB(r: 0.25, g: 0.39, b: 0.51),
                         RGB(r: 0.14, g: 0.26, b: 0.36)],
                celestial: .nothing, ridged: true, frequency: 1.3,
                amplitude: 0.100, peakiness: 1.2, hasWater: false, allowBirds: true)
        }
    }
}
