import SwiftUI

/// 控制台主界面。
///
/// 布局自上而下：标题 → 环形状态 → 主开关 → 次要操作 → 底部（定位 / 退出）。
/// 一屏之内只放一个「大动作」，其余都降级为次要按钮 —— 这个程序的使用场景是
/// 「瞟一眼、点一下」，层级多了反而慢。
struct ContentView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusArea
            actionArea
            Divider()
            footer
        }
        .frame(width: 380, height: 528)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 11) {
            appIcon
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("EyeGuard 控制台")
                    .font(.system(size: 14, weight: .semibold))
                Text("20-20-20 护眼提醒")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 直接用真实的应用图标，而不是再画一遍。
    /// 之前这里用 `eye.fill` 符号自绘，结果是 Dock 图标（实心瞳孔）
    /// 和窗口头部（空心环瞳孔）风格对不上 —— 同一个程序出现两个「标志」
    /// 是那种说不清哪里别扭、但一眼能看出来的问题。
    @ViewBuilder
    private var appIcon: some View {
        if let icon = Self.bundleIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            // 兜底：直接跑二进制（没有 bundle 图标）时退回符号
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.brandTop, Palette.brandBottom],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: "eye.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    /// 优先直接读 bundle 里的 `AppIcon.icns`。
    /// `NSApp.applicationIconImage` 在图标缓存尚未刷新时会返回 nil，
    /// 那时会退回符号自绘，头部和 Dock 就又不一样了。
    private static let bundleIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }()

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text(badgeText)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(badgeColor.opacity(0.14)))
        .foregroundStyle(badgeColor)
    }

    // MARK: - 环形状态

    private var statusArea: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 18)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 9)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: ringProgress)

                VStack(spacing: 3) {
                    if let text = ringText {
                        Text(text)
                            .font(.system(size: 33, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    } else {
                        Image(systemName: ringIcon)
                            .font(.system(size: 27, weight: .light))
                            .foregroundStyle(ringColor)
                    }
                    Text(headline)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 154, height: 154)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 32)
                .padding(.horizontal, 30)

            Spacer(minLength: 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作

    private var actionArea: some View {
        VStack(spacing: 9) {
            FilledButton(title: primaryTitle,
                         systemImage: primaryIcon,
                         tint: primaryTint,
                         enabled: primaryEnabled,
                         action: model.togglePrimary)

            HStack(spacing: 9) {
                OutlineButton(title: secondaryTitle,
                              systemImage: secondaryIcon,
                              enabled: model.connection.isRunning,
                              action: model.performSecondary)

                OutlineButton(title: "设置…",
                              systemImage: "gearshape",
                              enabled: model.connection.isRunning,
                              action: model.openSettings)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button(action: model.chooseApp) {
                    Text("定位 EyeGuard…")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)

                Spacer()

                Button(action: model.quitEyeGuard) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("退出护眼")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.connection.isRunning ? Color.red : Color.secondary)
                .disabled(!model.connection.isRunning)
            }

            if let url = model.appURL {
                Text(url.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 展示值

    private var ringText: String? {
        switch model.connection {
        case .connected(let state): return state.ringText
        case .unknown, .launching, .notRunning: return nil
        }
    }

    private var ringProgress: Double {
        if case .connected(let state) = model.connection { return state.ringProgress }
        return 0
    }

    private var ringIcon: String {
        switch model.connection {
        case .connected(let state):
            switch state.phase {
            case .paused:     return "pause.fill"
            case .suppressed: return "hand.raised.fill"
            case .sleeping:   return "moon.zzz.fill"
            default:          return "hourglass"
            }
        case .launching:  return "arrow.triangle.2.circlepath"
        case .unknown:    return "magnifyingglass"
        case .notRunning: return "power"
        }
    }

    private var headline: String {
        switch model.connection {
        case .connected(let state): return state.headline
        case .launching:            return "正在连接"
        case .unknown:              return "检测中"
        case .notRunning:           return "未运行"
        }
    }

    private var detail: String {
        switch model.connection {
        case .connected(let state):
            return state.detail
        case .launching:
            return "正在启动 EyeGuard…"
        case .unknown:
            return "正在检查 EyeGuard 是否在运行…"
        case .notRunning:
            return "点下面的按钮启动，之后它会常驻菜单栏"
        }
    }

    private var ringColor: Color {
        switch model.connection {
        case .connected(let state):
            switch state.phase {
            case .working, .prewarning, .snoozed: return Palette.active
            case .resting:                        return Palette.resting
            case .paused, .suppressed, .sleeping: return Palette.paused
            }
        case .launching, .unknown: return Color.secondary
        case .notRunning:          return Color.secondary
        }
    }

    private var badgeColor: Color { ringColor }

    private var badgeText: String {
        switch model.connection {
        case .connected(let state): return state.phase.displayName
        case .launching:            return "启动中"
        case .unknown:              return "检测中"
        case .notRunning:           return "未运行"
        }
    }

    private var primaryTitle: String {
        switch model.connection {
        case .connected(let state): return state.phase == .paused ? "恢复提醒" : "暂停提醒"
        case .notRunning:           return "启动护眼"
        case .launching:            return "正在启动…"
        case .unknown:              return "检测中…"
        }
    }

    private var primaryIcon: String {
        switch model.connection {
        case .connected(let state): return state.phase == .paused ? "play.fill" : "pause.fill"
        case .notRunning:           return "play.fill"
        case .launching, .unknown:  return "ellipsis"
        }
    }

    private var primaryTint: Color {
        switch model.connection {
        case .connected(let state):
            return state.phase == .paused ? Palette.active : Palette.neutral
        case .notRunning:  return Palette.active
        case .launching, .unknown: return Palette.neutral
        }
    }

    private var primaryEnabled: Bool {
        switch model.connection {
        case .unknown, .launching: return false
        default: return true
        }
    }

    private var secondaryTitle: String {
        if case .connected(let state) = model.connection, state.phase == .resting {
            return "跳过这次休息"
        }
        return "立即休息"
    }

    private var secondaryIcon: String {
        if case .connected(let state) = model.connection, state.phase == .resting {
            return "forward.end.fill"
        }
        return "sun.max.fill"
    }
}

// MARK: - 配色

private enum Palette {
    static let brandTop    = Color(red: 0.11, green: 0.33, blue: 0.50)
    static let brandBottom = Color(red: 0.24, green: 0.66, blue: 0.70)
    /// 正常运行
    static let active  = Color(red: 0.16, green: 0.60, blue: 0.42)
    /// 休息中
    static let resting = Color(red: 0.20, green: 0.50, blue: 0.82)
    /// 暂停 / 顺延 / 休眠
    static let paused  = Color(red: 0.86, green: 0.56, blue: 0.16)
    /// 中性动作（暂停）
    static let neutral = Color(red: 0.36, green: 0.42, blue: 0.50)
}

// MARK: - 按钮

private struct FilledButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(enabled ? (hovering ? 0.86 : 1) : 0.32))
            )
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

private struct OutlineButton: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(enabled ? (hovering ? 0.11 : 0.06) : 0.03))
            )
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
