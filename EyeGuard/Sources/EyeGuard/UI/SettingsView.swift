import SwiftUI
import AppKit

/// 设置面板。规格书 FR-7.3。
///
/// 全部文案取自 `configStore.config.strings` —— 语言在「常规」页第一项切换，
/// 整个窗口即时跟着变（`configStore` 是 `@ObservedObject`，改 `language`
/// 就会重绘）。没有 `.strings` 文件，也没有 `Bundle.module`。
struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var sceneLibrary: SceneLibrary

    /// 初始标签页。
    ///
    /// 只为离屏工装（`--shot-settings`）服务 —— 要逐页截图就得能从外面指定
    /// 打开哪一页，而 `TabView` 的选中项是视图内部状态。默认「常规」，
    /// 与用户实际打开设置时看到的一致。
    var initialTab: Tab = .general

    enum Tab: String, CaseIterable, Hashable {
        case general, suppression, display, assets, about
    }

    @State private var selected: Tab = .general

    /// 当前语言的文案表
    private var s: Strings { configStore.config.strings }

    var body: some View {
        TabView(selection: $selected) {
            generalTab
                .tabItem { Label(s.tabGeneral, systemImage: "gearshape") }
                .tag(Tab.general)
            suppressionTab
                .tabItem { Label(s.tabSuppression, systemImage: "hand.raised") }
                .tag(Tab.suppression)
            displayTab
                .tabItem { Label(s.tabDisplay, systemImage: "display") }
                .tag(Tab.display)
            AssetSettingsView(configStore: configStore,
                              sceneLibrary: sceneLibrary,
                              scheduler: scheduler)
                .tabItem { Label(s.tabAssets, systemImage: "photo.on.rectangle") }
                .tag(Tab.assets)
            aboutTab
                .tabItem { Label(s.tabAbout, systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 580, height: 540)
        .onAppear { selected = initialTab }
    }

    // MARK: - 常规

    private var generalTab: some View {
        Form {
            Section {
                Picker(s.labelLanguage, selection: $configStore.config.language) {
                    ForEach(Language.allCases) { language in
                        // 语言**自称**，不翻译 —— 用户误切到看不懂的语言时，
                        // 列表里必须至少有一项是他能认出来的。
                        Text(language.endonym).tag(language)
                    }
                }
                Text(s.helpLanguage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secLanguage)
            }

            Section {
                Picker(s.labelWorkInterval, selection: $configStore.config.workIntervalMinutes) {
                    ForEach(configStore.config.availableIntervalOptions, id: \.self) { value in
                        Text(s.unitMinutes(value)).tag(value)
                    }
                }
                Picker(s.labelRestDuration, selection: $configStore.config.restDurationSeconds) {
                    ForEach(configStore.config.availableDurationOptions, id: \.self) { value in
                        Text(s.unitSeconds(value)).tag(value)
                    }
                }
                Picker(s.labelPrewarning, selection: $configStore.config.prewarningSeconds) {
                    ForEach(AppConfig.prewarningOptions, id: \.self) { value in
                        Text(s.unitSeconds(value)).tag(value)
                    }
                }
            } header: {
                Text(s.secRhythm)
            }

            Section {
                Picker(s.labelSkipUnlock, selection: $configStore.config.skipUnlockSeconds) {
                    ForEach(AppConfig.skipUnlockOptions, id: \.self) { value in
                        Text(value == 0 ? s.skipUnlockImmediate : s.unitSeconds(value)).tag(value)
                    }
                }
                Picker(s.labelSnoozeLength, selection: $configStore.config.snoozeMinutes) {
                    ForEach(configStore.config.availableSnoozeOptions, id: \.self) { value in
                        Text(s.unitMinutes(value)).tag(value)
                    }
                }
                Text(s.helpSkipUnlock)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secSkipSnooze)
            }

            Section {
                Toggle(s.toggleLaunchAtLogin, isOn: $configStore.config.launchAtLogin)
            } header: {
                Text(s.secLaunch)
            }

            Section {
                Toggle(s.toggleTestMode, isOn: testModeBinding)
                Text(s.helpTestMode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secTesting)
            }
        }
        .formStyle(.grouped)
    }

    /// 关闭测试模式时顺手把落在测试档位的值收敛回常规档位，
    /// 否则 Picker 的 selection 指向一个不存在的选项，界面会显示空白。
    private var testModeBinding: Binding<Bool> {
        Binding(
            get: { configStore.config.testModeEnabled },
            set: { newValue in
                configStore.config.testModeEnabled = newValue
                if !newValue { configStore.config.clampToAvailableOptions() }
            }
        )
    }

    // MARK: - 顺延

    private var suppressionTab: some View {
        Form {
            Section {
                Toggle(s.toggleSuppressIdle, isOn: $configStore.config.suppressOnIdle)
                Picker(s.labelIdleThreshold, selection: $configStore.config.idleThresholdMinutes) {
                    ForEach(configStore.config.availableIdleThresholdOptions, id: \.self) { value in
                        Text(s.unitMinutes(value)).tag(value)
                    }
                }
                .disabled(!configStore.config.suppressOnIdle)
                Text(s.helpIdleThreshold)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secIdle)
            }

            Section {
                Toggle(s.toggleSuppressFullscreen, isOn: $configStore.config.suppressOnFullscreen)
                Toggle(s.toggleSuppressCamera, isOn: $configStore.config.suppressOnCamera)
                Text(s.helpFullscreen)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secForeground)
            }

            Section {
                Text(s.helpWakeCooldown(configStore.config.effectiveWakeCooldownSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.helpDoNotDisturb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secOther)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 显示

    private var displayTab: some View {
        Form {
            Section {
                Picker(s.labelDisplayTarget, selection: $configStore.config.displayTarget) {
                    ForEach(DisplayTarget.allCases) { target in
                        Text(target.displayName(s)).tag(target)
                    }
                }
            } header: {
                Text(s.secMultiDisplay)
            }

            Section {
                Toggle(s.toggleNightDimming, isOn: $configStore.config.nightDimmingEnabled)
                Picker(s.labelNightStart, selection: $configStore.config.nightStartHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                .disabled(!configStore.config.nightDimmingEnabled)
                Picker(s.labelNightEnd, selection: $configStore.config.nightEndHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                .disabled(!configStore.config.nightDimmingEnabled)
                Text(s.helpNightDimming)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(s.secNight)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于 / 许可（FR-12）

    /// 关于页。**这不是装饰，是分发的前提。**
    ///
    /// 内置素材全部来自 Wikimedia Commons，以 CC BY / CC BY-SA / CC0 / 公有领域发布。
    /// CC 的署名要求是**署名 + 许可声明 + 链接**三件套，所以下面那个逐条列表
    /// 不是「锦上添花的版权页」—— 缺了它，带 CC 素材分发就是侵权。
    ///
    /// 2026-10-13 之前素材库里还有 17 张 macOS 随附的 Apple 官方壁纸，
    /// 那些**不允许随 App 分发**，已全部移除（见 `build_captions.py` 末尾的说明）。
    /// 现在 609 张全部是自由授权。
    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(s.appName) \(appVersion)")
                    .font(.system(size: 15, weight: .semibold))
                Text(s.aboutCodeLicense)
                    .font(.caption).foregroundStyle(.secondary)
                Text(s.aboutPhotoNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(s.aboutLicenseSummary).font(.callout)
                Text(licenseGroups.map { "\($0.0) ×\($0.1)" }.joined(separator: "   "))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 10)

            Divider()

            Text(s.aboutCredits(creditRows.count))
                .font(.callout)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(creditRows) { row in
                        Button {
                            if let url = row.url { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.callout).lineLimit(1)
                                    Text(row.subtitle).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 20)
                    }
                }
            }
        }
        // ⚠️ 这个背景**不能省**。另外 4 个标签页用 `Form(.grouped)`，它自带页面底色；
        // 这一页是裸 `VStack`，不显式给底色的话**整页是半透明的**（离屏渲染出来的
        // PNG alpha 最大值只有 223，转成 RGB 就是一片白）。
        // 应用里有窗口垫着看不出问题，但那样 `--shot-settings` 就拍不出这一页 ——
        // 而这一页恰恰是**合规声明**，必须能被拍出来核对。
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private struct CreditRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let url: URL?
    }

    /// 逐条署名。**只收有来源链接的** —— 没有链接就没有可核查的出处，
    /// 满足不了 CC 的「链接」要求（程序化占位素材无需署名，自然被排除）。
    private var creditRows: [CreditRow] {
        SceneLibrary.builtInPool().compactMap { asset in
            guard let url = asset.sourceURL else { return nil }
            return CreditRow(
                id: asset.id,
                title: asset.caption(configStore.config.language) ?? asset.displayName(s),
                subtitle: "\(asset.photographer ?? "—") · \(asset.license)",
                url: url)
        }
    }

    private var licenseGroups: [(String, Int)] {
        var counts: [String: Int] = [:]
        for asset in SceneLibrary.builtInPool() { counts[asset.license, default: 0] += 1 }
        return counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
    }
}
