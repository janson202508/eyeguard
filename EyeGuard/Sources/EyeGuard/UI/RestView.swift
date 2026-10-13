import SwiftUI
import AppKit

/// 休息全屏层。规格书 FR-3。
///
/// 布局自上而下：风景 → 名称 → 小字介绍 → 出处行 → 环形倒计时 → 操作按钮。
///
/// 文字三级的字号与不透明度：名称 24pt/1.0、小字介绍 15pt/0.78、出处行 12pt/0.55。
/// 三级是**刻意**的 —— 小字介绍要看得出来是「补充」而不是第二行标题。
///
/// **关于「图上不再有任何行动指令」这条决定（2026-10-13）。**
/// 用户要求去掉「抬头，看向 6 米外的某个细节」那句引导句。
/// 需要知道代价：**那是 P1（风景是引导式、屏幕上的图只是遮眼物）在版面上唯一的表达**，
/// 去掉之后休息画面就只剩「看一张图 + 倒计时」，屏幕上的风景从「遮眼物」
/// 变成了「被观看的内容本身」—— 而 20-20-20 的作用机制是让睫状肌放松，
/// 盯着一张照片看并不产生这个效果。
/// 决定是用户做的，这里只记录：**若要恢复，把 6 条 `prompt*` 文案加回
/// `Tools/i18n/gen_strings.py`、恢复 `Scheduler.currentPrompt` 与 FR-6 自检即可**
/// （旧文案见 `需求规格书-v1.md` 附录或 git 历史）。
///
/// 保留的取舍：介绍仍占最大的一行（FR-11）。
///
/// 「跳过」按钮在 `skipUnlockSeconds` 秒后才出现（FR-3.4），制造轻微摩擦；
/// 未解锁期间给一行低对比度说明，避免用户以为程序卡住。
struct RestView: View {
    @ObservedObject var scheduler: Scheduler

    /// 当前语言的文案表
    private var s: Strings { scheduler.strings }

    /// 当前素材的图片介绍（主行，地名/场景名）。
    /// 用户导入的图片没有介绍，返回 nil，整行不显示。
    private var caption: String? {
        scheduler.currentAsset?.caption(scheduler.language)
    }

    /// 小字介绍（FR-11.9）：`类别 · 年月`，全部由可核查组件重组。
    /// 同样地，没有就整行不显示。
    private var blurb: String? {
        scheduler.currentAsset?.blurb(scheduler.language)
    }

    var body: some View {
        ZStack {
            sceneLayer
            dimmingLayer
            content
        }
        .ignoresSafeArea()
        .background(LayoutProbeView(label: "根容器 ZStack"))
        .onExitCommand {
            // FR-3.7：Esc 行为等同点击跳过按钮，因此同样受解锁延迟约束
            if scheduler.skipUnlocked { scheduler.skip() }
        }
    }

    // MARK: - 背景

    @ViewBuilder
    private var sceneLayer: some View {
        if let asset = scheduler.currentAsset {
            if let url = AppPaths.imageURL(for: asset),
               let image = NSImage(contentsOf: url) {
                // ⚠️ 必须把图片关进一个**尺寸确定**的框里。
                //
                // `.aspectRatio(contentMode: .fill)` 返回的布局尺寸是「按比例
                // 铺满建议尺寸」的结果：图片比窗口「更方」时，它比窗口**更高**。
                // 而 `.frame(maxWidth: .infinity, maxHeight: .infinity)` 夹不住它
                // （上限是无穷大），于是根容器被撑高，**整个界面的纵向位置都跟着
                // 当前这张图变** —— 容器越高，底部那排按钮越往下。
                //
                // 实测（1440×900 窗口，`--shot-rest` + `EYEGUARD_LAYOUT_PROBE=1`）：
                //   · 图片宽高比 2.48 → 容器 900 高，按钮在 y 770..836   ✓
                //   · 图片宽高比 1.48 → 容器 973 高，按钮在 y 807..873   （余量 27pt）
                //   · 图片宽高比 0.75（竖幅照片）→ 容器 1920 高，
                //     按钮在 y 1280..1346 —— 屏幕只有 900 高，**跑出去 446pt，
                //     看不见也点不到**。16:9 屏配内置素材就能复现（最差超出 36pt）。
                //
                // 修法与 `PlaceholderSceneView` 一致（那条路径本来就是对的）：
                // 用 GeometryReader 取窗口给的实际尺寸，再用确定尺寸的 frame 把图
                // 夹回去，多出来的部分交给 `.clipped()` 裁掉。这样背景图对布局的
                // 贡献恒等于窗口尺寸，控件位置不再取决于正在显示哪张图。
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                PlaceholderSceneView(asset: asset, isNight: scheduler.isNight)
            }
        } else {
            // 素材库为空：用户禁用了全部素材，或删光了导入的图片又关了内置场景。
            //
            // 这里给一层安静的深色渐变而不是纯黑 —— 纯黑看起来像程序崩了。
            // 语义上这次休息仍然是完整的：引导文案和健康提示都在，
            // 图片本来就只是遮挡与心理开关（规格书原则 P1）。
            emptySceneLayer
        }
    }

    private var emptySceneLayer: some View {
        ZStack {
            LinearGradient(
                colors: scheduler.isNight
                    ? [Color(red: 0.05, green: 0.06, blue: 0.10),
                       Color(red: 0.10, green: 0.11, blue: 0.16)]
                    : [Color(red: 0.13, green: 0.16, blue: 0.22),
                       Color(red: 0.22, green: 0.27, blue: 0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.22))
                Text(s.restEmptyLibrary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.30))
            }
            .offset(y: -120)
        }
    }

    /// 压暗层。FR-8.1：夜间额外压暗，避免突然的全屏白亮刺激。
    ///
    /// 分两层，因为两层的职责不同：
    ///
    ///   1. **全局一层很轻的压暗** —— 只是让照片不至于刺眼，观感上几乎不变。
    ///      原来这里是从上到下 0.06 → 0.80 的横向渐变，底边被压到八成黑。
    ///      那是「看不清风景」的大头：信息区只占右下角一小块，
    ///      却把整条底边都压黑了。现在把这一层的强度交还给照片。
    ///   2. **右下角局部压暗** —— 唯一目的是让信息区在任何照片上都读得清
    ///      （雪原、亮天空这种高亮背景上，白字没有底衬是读不了的）。
    ///      用径向渐变贴着角，左上大半张画面完全不受影响。
    ///
    /// 半径为什么要设上限：信息区**贴着右下角**，边距和宽度都是固定的 pt，
    /// 所以它的远角到屏幕右下角恒为约 550pt —— 与屏幕尺寸无关。半径只要
    /// 到 1000pt 左右就足够覆盖它，再大就纯粹是在无谓地压暗画面。
    /// 实测教训：不设上限时半径是 `max(宽,高) × 0.68`，3440 宽的带鱼屏会
    /// 算出 2339pt，蔓延到把**右上角**（属于画面上半部分）也压暗 26%，
    /// 正好违反 FR-3.11。加上限后上半部分只剩全局那 0.10。
    private var dimmingLayer: some View {
        ZStack {
            Color.black.opacity(scheduler.isNight ? 0.34 : 0.10)

            GeometryReader { geo in
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0.78), location: 0.00),
                        .init(color: .black.opacity(0.58), location: 0.35),
                        .init(color: .black.opacity(0.22), location: 0.65),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: min(max(geo.size.width, geo.size.height) * 0.68, 980)
                )
            }
        }
    }

    // MARK: - 前景

    /// 信息区：贴在**右下角**，尽量少挡风景。
    ///
    /// 原来是一整条纵向居中的栈：文案横向铺满整屏、正落在视线高度上，
    /// 再叠加一条把底边压到八成黑的渐变 —— 两者合起来才是「看不清风景」。
    /// 现在信息压进右下角一小块，左上大半张画面完整空出来给风景本身。
    ///
    /// 结构上分两层，职责不同：
    ///   · 外层只用 `Spacer()` 做定位（先到底、再到右），不带任何尺寸语义；
    ///   · 内层才是真正的内容栈，用 `.trailing` 对齐，并把宽度**封顶**在
    ///     `clusterMaxWidth`。封顶是必须的 —— 否则长地名会把簇拉成横贯整屏
    ///     的一条，右下角就白贴了。封顶之后容器边界即文本边界。
    ///     内层自上而下：图片介绍 → 出处行 → 倒计时环 → 按钮。
    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 0) {
                    // 主行：图片介绍（FR-11）。拍的是哪儿、或者是什么场景。
                    // 依据字段记在 `SceneAsset.captionSource` 里 —— 介绍必须是
                    // 可核查的（图源元数据 / GPS 反查 / 人工标注的类别），不编造。
                    if let caption {
                        Text(caption)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .shadow(color: .black.opacity(0.55), radius: 16, y: 2)

                        // 小字介绍（FR-11.9）：类别 · 年月。介于名称与出处行之间，
                        // 字号与不透明度都比名称弱、比出处行强，形成 24 / 15 / 12 三级。
                        if let blurb {
                            Spacer().frame(height: 7)
                            Text(blurb)
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.78))
                                .multilineTextAlignment(.trailing)
                                .shadow(color: .black.opacity(0.45), radius: 10)
                        }

                        // 出处行：作者 · 年份。两者都取自图源元数据。
                        if let credit = scheduler.currentAsset?.credit(s) {
                            Spacer().frame(height: 6)
                            Text(credit)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.trailing)
                                .shadow(color: .black.opacity(0.45), radius: 10)
                        }

                    }

                    Spacer().frame(height: 24)

                    ring

                    Spacer().frame(height: 20)

                    buttons
                }
                .frame(maxWidth: clusterMaxWidth, alignment: .trailing)
                .background(LayoutProbeView(label: "信息区"))
            }
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 40)
    }

    /// 信息区宽度上限。取 430 的依据：这是「贴右下角、尽量不挡风景」与
    /// 「地名读得下」之间的折中。24pt 的图片介绍在这一宽度下折成两行，
    /// 再宽就开始横向侵占画面中部 —— 而画面中部正是这次休息要人看出去的地方。
    private let clusterMaxWidth: CGFloat = 430

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 4)
            Circle()
                .trim(from: 0, to: scheduler.restProgress)
                .stroke(Color.white.opacity(0.92),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: scheduler.restProgress)
            Text("\(scheduler.restRemainingSeconds)")
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
    }

    private var buttons: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // 「换一张」不设解锁延迟：它是跳过之外的温和出口，
                // 加摩擦只会把用户推回「跳过」。
                // `hint` 把 FR-3.12 的快捷键写在按钮上 —— 不写就没人知道。
                PillButton(title: s.restNextScene,
                           icon: "arrow.triangle.2.circlepath",
                           hint: "← →") {
                    scheduler.nextScene()
                }

                PillButton(title: s.menuSnooze(scheduler.configStore.config.snoozeMinutes)) {
                    scheduler.snooze()
                }

                if scheduler.skipUnlocked {
                    PillButton(title: s.restSkip) {
                        scheduler.skip()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }

            if !scheduler.skipUnlocked {
                Text(s.restSkipUnlockIn(scheduler.skipLockRemaining))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .background(LayoutProbeView(label: "操作按钮区"))
    }
}

/// 记录自己被布局到窗口坐标系的哪个位置（`LayoutProbe` 的视图侧）。
///
/// 用 `let _ =` 在 `GeometryReader` 的 body 里直接记录，而不是 `onAppear`：
/// `onAppear` 只在视图首次出现时触发一次，而这里要看的是**换图之后**
/// 的布局，视图身份并没有变。`GeometryReader` 的 body 每次布局都会重跑，
/// 才能拿到「当前这一张图」的真实位置。
private struct LayoutProbeView: View {
    let label: String

    var body: some View {
        // 关闭时连视图都不建 —— 正式构建里不该为调试设施付布局开销。
        // `enabled` 只读环境变量，进程内不会变，所以视图身份是稳定的。
        if LayoutProbe.enabled {
            GeometryReader { geo in
                let _ = LayoutProbe.record(label, geo.frame(in: .global))
                Color.clear
            }
            .allowsHitTesting(false)
        }
    }
}

private struct PillButton: View {
    let title: String
    var icon: String?
    /// 右侧的快捷键提示（例如「← →」）。用比标题更小、更暗的样式，
    /// 只是「告诉你还有这条路」，不参与视觉竞争。
    var hint: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.leading, 2)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.24 : 0.14)))
            .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
