import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置面板的「素材」标签页。
///
/// 两段式：上面是「我的图片」（逐张管理），下面是「内置场景」（按类别管理）。
/// 两套粒度的理由见 `AppConfig` 里那段注释 —— 简单说就是 50 张占位素材逐张勾选
/// 是折磨，而用户自己导入的几十张里「这张我不喜欢」必须能精确到单张。
struct AssetSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var sceneLibrary: SceneLibrary
    @ObservedObject var scheduler: Scheduler

    @State private var message: String?
    @State private var messageIsError = false

    private var enabledCount: Int { scheduler.activeAssets.count }
    private var config: AppConfig { configStore.config }

    /// 界面文案一律从这里取。
    ///
    /// 不在视图里写 `Strings.english.xxx` 这类字面量 —— 那样语言设置就成了摆设，
    /// 而且**这种漏改没有编译错误**，只有肉眼能发现。视图里只应出现 `s.xxx`。
    private var s: Strings { config.strings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusBar
                importedSection
                builtInSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 顶部状态

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(s.assetsInRotationLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(s.countScenes(enabledCount))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabledCount == 0 ? .orange : .primary)
                Spacer()
                Text(s.countScenesTotal(sceneLibrary.assets.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if enabledCount == 0 {
                warningRow(s.assetsNoneWarning)
            } else if sceneLibrary.hasNoImportedImages {
                infoRow(builtInIsRealPhotos ? s.assetsAllBundledInfo : s.assetsAllPlaceholderInfo)
            } else if config.useBuiltInScenes {
                HStack(spacing: 8) {
                    Text(builtInIsRealPhotos
                         ? s.assetsMixedSummaryBundled(sceneLibrary.importedAssets.count,
                                                       sceneLibrary.builtInSceneAssets.count)
                         : s.assetsMixedSummaryPlaceholder(sceneLibrary.importedAssets.count,
                                                           sceneLibrary.builtInSceneAssets.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(s.assetsDisableBuiltIn) {
                        configStore.config.useBuiltInScenes = false
                        flash(s.assetsDisabledBuiltInFlash)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(messageIsError ? .red : Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 我的图片

    private var importedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.assetsMyImages)
                    .font(.system(size: 13, weight: .semibold))
                Text(s.countScenes(sceneLibrary.importedAssets.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if sceneLibrary.importedTotalBytes > 0 {
                    Text("· \(Self.byteText(sceneLibrary.importedTotalBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(s.assetsAddImages) { pickImages() }
                Button(s.assetsAddFolder) { pickFolder() }
                Spacer()
                if !sceneLibrary.importedAssets.isEmpty {
                    Button(s.assetsRemoveAll) { removeAll() }
                        .foregroundStyle(.red)
                }
            }
            .controlSize(.small)

            if sceneLibrary.importedAssets.isEmpty {
                Text(s.assetsImportFormatsHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 10)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(sceneLibrary.importedAssets) { asset in
                        ImportedAssetCard(
                            asset: asset,
                            strings: s,
                            enabled: config.isAssetEnabled(asset),
                            onToggle: { toggle(asset) },
                            onCategory: { setCategory($0, for: asset) },
                            onDelete: { remove(asset) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 内置场景

    /// 内置场景现在默认是**随 App 分发的真实风景照**（`source == .bundled`），
    /// 只有预置素材缺失时才会退回程序化占位场景（`source == .placeholder`）。
    ///
    /// ⚠️ 文案必须跟着**实际来源**走。这里原来写死了「程序化生成的占位场景
    /// （抽象色块）」，换成 50 张真照片之后就成了自相矛盾 —— 用户左边看到
    /// 满屏真风景，右边读到自己用的是抽象色块。别把「曾经是什么」写进文案。
    private var builtInIsRealPhotos: Bool {
        sceneLibrary.builtInSceneAssets.first?.source == .bundled
    }

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.assetsBuiltInTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(s.countScenes(sceneLibrary.builtInSceneAssets.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(s.assetsInRotationToggle, isOn: $configStore.config.useBuiltInScenes)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text(builtInIsRealPhotos
                 ? s.assetsBuiltInRealPhotosHelp(sceneLibrary.builtInSceneAssets.count)
                 : s.assetsBuiltInPlaceholdersHelp)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(sceneLibrary.builtInByCategory.enumerated()), id: \.element.category) { index, group in
                    if index > 0 { Divider().opacity(0.4) }
                    HStack(spacing: 10) {
                        Text(group.category.displayName(s))
                            // 100pt 是按**英文**留的（"Grassland" 比「草原」宽得多）。
                            // 英文现在是默认语言，按中文宽度写 78pt 会把英文截断。
                            .frame(width: 100, alignment: .leading)
                            .lineLimit(1)
                        Text(s.countScenes(group.assets.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(s.countScenesEnabled(group.assets.filter { config.isAssetEnabled($0) }.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: categoryBinding(group.category))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .opacity(config.useBuiltInScenes ? 1 : 0.42)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .disabled(!config.useBuiltInScenes)
        }
    }

    // MARK: - 绑定

    private func categoryBinding(_ category: SceneCategory) -> Binding<Bool> {
        Binding(
            get: { !config.disabledSceneCategories.contains(category.rawValue) },
            set: { configStore.config.setCategory(category, enabled: $0) }
        )
    }

    // MARK: - 操作

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.title = s.assetsPickPanelTitle
        panel.prompt = s.assetsImportButton
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        performImport(panel.urls)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = s.assetsPickFolderPanel
        panel.message = s.assetsPickFolderNote
        panel.prompt = s.assetsImportButton
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        performImport([folder])
    }

    private func performImport(_ urls: [URL]) {
        guard let category = askCategory() else { return }

        let outcome = SceneImporter.importItems(
            urls,
            category: category,
            existingIDs: Set(sceneLibrary.importedAssets.map(\.id))
        )

        guard !outcome.added.isEmpty else {
            var text = outcome.summary(s)
            if let detail = outcome.failureDetail(s) { text += s.parenthesized(detail) }
            flash(text, isError: true)
            return
        }

        do {
            try sceneLibrary.addImported(outcome.added)
            flash(outcome.message(s))
        } catch {
            flash(s.assetsWriteFailed(error.localizedDescription), isError: true)
        }
    }

    /// 导入前问一次这批图归哪个类别。
    ///
    /// 类别不是装饰：它决定这张图参与哪个轮次，以及会不会在夜间被排除。
    /// 用一次性询问而不是导入后逐张设置 —— 批量导入几十张时逐张点太折磨。
    /// 之后想改，卡片上有下拉可以逐张调整。
    private func askCategory() -> SceneCategory? {
        let alert = NSAlert()
        alert.messageText = s.assetsCategoryPromptTitle
        alert.informativeText = s.assetsCategoryPromptHelp
        alert.addButton(withTitle: s.assetsImportButton)
        alert.addButton(withTitle: s.commonCancel)

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 25))
        for category in SceneCategory.allCases {
            popup.addItem(withTitle: category.displayName(s))
        }
        popup.selectItem(at: SceneCategory.allCases.firstIndex(of: .custom) ?? 0)
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard SceneCategory.allCases.indices.contains(index) else { return .custom }
        return SceneCategory.allCases[index]
    }

    private func toggle(_ asset: SceneAsset) {
        let nowEnabled = config.isAssetEnabled(asset)
        configStore.config.setAsset(asset.id, enabled: !nowEnabled)
    }

    private func setCategory(_ category: SceneCategory, for asset: SceneAsset) {
        do {
            try sceneLibrary.reassign(id: asset.id, to: category)
        } catch {
            flash(s.assetsReassignFailed(error.localizedDescription), isError: true)
        }
    }

    private func remove(_ asset: SceneAsset) {
        let alert = NSAlert()
        alert.messageText = s.assetsDeleteConfirmTitle(asset.displayName(s))
        alert.informativeText = s.assetsDeleteConfirmHelp
        alert.alertStyle = .warning
        alert.addButton(withTitle: s.commonDelete)
        alert.addButton(withTitle: s.commonCancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try sceneLibrary.removeImported(id: asset.id)
            ThumbnailCache.invalidate()
            configStore.config.setAsset(asset.id, enabled: true)   // 清掉可能残留的禁用记录
            flash(s.assetsDeletedFlash)
        } catch {
            flash(s.assetsDeleteFailed(error.localizedDescription), isError: true)
        }
    }

    private func removeAll() {
        let alert = NSAlert()
        alert.messageText = s.assetsRemoveAllConfirm(sceneLibrary.importedAssets.count)
        alert.informativeText = s.assetsRemoveAllHelp
        alert.alertStyle = .warning
        alert.addButton(withTitle: s.assetsRemoveAll)
        alert.addButton(withTitle: s.commonCancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try sceneLibrary.removeAllImported()
            ThumbnailCache.invalidate()
            configStore.config.disabledAssetIDs = []
            flash(s.assetsRemovedAllFlash)
        } catch {
            flash(s.assetsRemoveFailed(error.localizedDescription), isError: true)
        }
    }

    private func flash(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }

    private static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - 图片卡片

private struct ImportedAssetCard: View {
    let asset: SceneAsset
    /// 卡片是独立视图，拿不到 `configStore`，所以文案表要显式传进来。
    /// 从环境里取「当前语言」是个陷阱：那样这个视图在离屏工装里就没法指定语言了。
    let strings: Strings
    let enabled: Bool
    let onToggle: () -> Void
    let onCategory: (SceneCategory) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                Button(action: onToggle) {
                    Image(systemName: enabled ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(
                            Circle().fill(enabled ? Color.accentColor.opacity(0.92)
                                                  : Color.black.opacity(0.72))
                        )
                        // 照片什么底色都有，纯色圆点在浅色照片上会糊掉 ——
                        // 加一圈描边保证任何背景上都能看清。
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(enabled ? strings.assetsTipDisable : strings.assetsTipEnable)
            }

            Text(asset.displayName(strings))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(asset.displayName(strings))

            HStack(spacing: 6) {
                Menu {
                    ForEach(SceneCategory.allCases) { category in
                        Button(category.displayName(strings)) { onCategory(category) }
                    }
                } label: {
                    Text(asset.category.displayName(strings))
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(strings.assetsTipDelete)
            }
        }
        // 禁用态**只压暗缩略图**，不压暗整张卡片。
        // 早期版本给整张卡片加 opacity，结果「重新启用」那个按钮也跟着变淡 ——
        // 恰恰是最需要看清的控件最难看清。文字改用次级色来表达禁用，
        // 控件本身始终保持可辨认。
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(enabled ? 0.05 : 0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(enabled ? 0.08 : 0.05), lineWidth: 1)
        )
    }

    private var thumbnail: some View {
        Group {
            if let image = ThumbnailCache.thumbnail(for: asset) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // 去饱和 + 压暗 = 「这张不参与轮播」一眼可辨
        .saturation(enabled ? 1 : 0)
        .opacity(enabled ? 1 : 0.40)
    }
}
