// ⚠️ 本文件由 `Tools/i18n/gen_strings.py` 从 `Tools/i18n/strings.json` 生成。
// **不要手改** —— 改 `strings.json`（或生成器里的 TABLE）后重新生成：
//
//     python3 Tools/i18n/gen_strings.py
//
// 校验两语言键集是否齐备：
//
//     python3 Tools/i18n/gen_strings.py --check

import Foundation

// MARK: - 界面语言（FR-10）

/// 界面语言。默认**英文**，可在设置里修改；图片介绍跟随同一设置（FR-10.3）。
enum Language: String, Codable, CaseIterable, Identifiable, Hashable {
    case en
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    /// 缺省语言。刻意**不跟随 macOS 系统语言** —— FR-10.1 明确要求默认英文。
    static let fallback: Language = .en

    /// 语言自称。
    ///
    /// 这一项**刻意不翻译**：用户误切到看不懂的语言时，选择列表里
    /// 必须至少有一项是他能认出来的。这也是 macOS 自己的做法。
    var endonym: String {
        switch self {
        case .en:     return "English"
        case .zhHans: return "简体中文"
        }
    }

    var strings: Strings {
        switch self {
        case .en:     return .english
        case .zhHans: return .simplifiedChinese
        }
    }
}

// MARK: - 文案表

/// 全部界面文案。
///
/// 每种语言一个实例，字段**全部是 `let`**，两处都写全才编译得过。
/// 这是刻意的：把「漏翻译一条」从「上线后才发现」变成「构建时就知道」。
/// 项目里没有 `.strings` 文件，也没有 `Bundle.module` —— 手工组装 .app 的
/// 构建方式下，SPM 资源包的查找路径很容易出错，代码表没有这个失败模式。
///
/// 类型为闭包的字段是**带参数**的文案，由 printf 格式串生成。
/// 不要在调用点自己拼字符串 —— 中英文的语序不同，拼接必然有一边是错的。
struct Strings {
    let appName: String
    let settingsWindowTitle: String
    let commonCancel: String
    let commonDelete: String
    let countScenes: (Int) -> String
    let countScenesTotal: (Int) -> String
    let countScenesEnabled: (Int) -> String
    let catCustom: String
    let catMountain: String
    let catOcean: String
    let catForest: String
    let catLake: String
    let catDesert: String
    let catSnow: String
    let catStarfield: String
    let catGrassland: String
    let catCanyon: String
    let catAerial: String
    let toneCool: String
    let toneWarm: String
    let toneNeutral: String
    let sourceImported: String
    let sourceBundled: String
    let sourceDownloaded: String
    let sourcePlaceholder: String
    let phaseWorking: String
    let phasePrewarning: String
    let phaseResting: String
    let phaseSnoozed: String
    let phaseSuppressed: String
    let phasePaused: String
    let phaseSleeping: String
    let targetMouseScreen: String
    let targetMainScreen: String
    let targetAllScreens: String
    let reasonIdle: String
    let reasonFullscreen: String
    let reasonCamera: String
    let reasonManual: String
    let reasonSleeping: String
    let statusNextBreak: (String) -> String
    let statusResting: (Int) -> String
    let statusSuppressed: String
    let statusSuppressedWith: (String) -> String
    let statusPausedUntil: (String) -> String
    let statusPaused: String
    let statusSleeping: String
    let listSeparator: String
    let menuShowingCategory: (String) -> String
    let menuRestNow: String
    let menuSnooze: (Int) -> String
    let menuResume: String
    let menuPause: String
    let menuPauseIndefinitely: String
    let menuPause30: String
    let menuPause60: String
    let menuPauseToday: String
    let menuSettings: String
    let menuQuit: String
    let restEmptyLibrary: String
    let restNextScene: String
    let restSkip: String
    let restSkipUnlockIn: (Int) -> String
    let tabGeneral: String
    let tabSuppression: String
    let tabDisplay: String
    let tabAssets: String
    let tabAbout: String
    let aboutCodeLicense: String
    let aboutPhotoNote: String
    let aboutLicenseSummary: String
    let aboutCredits: (Int) -> String
    let secLanguage: String
    let labelLanguage: String
    let helpLanguage: String
    let secRhythm: String
    let labelWorkInterval: String
    let unitMinutes: (Int) -> String
    let labelRestDuration: String
    let unitSeconds: (Int) -> String
    let labelPrewarning: String
    let secSkipSnooze: String
    let labelSkipUnlock: String
    let skipUnlockImmediate: String
    let labelSnoozeLength: String
    let helpSkipUnlock: String
    let secLaunch: String
    let toggleLaunchAtLogin: String
    let secTesting: String
    let toggleTestMode: String
    let helpTestMode: String
    let secIdle: String
    let toggleSuppressIdle: String
    let labelIdleThreshold: String
    let helpIdleThreshold: String
    let secForeground: String
    let toggleSuppressFullscreen: String
    let toggleSuppressCamera: String
    let helpFullscreen: String
    let secOther: String
    let helpWakeCooldown: (Int) -> String
    let helpDoNotDisturb: String
    let secMultiDisplay: String
    let labelDisplayTarget: String
    let secNight: String
    let toggleNightDimming: String
    let labelNightStart: String
    let labelNightEnd: String
    let helpNightDimming: String
    let assetsInRotationLabel: String
    let assetsNoneWarning: String
    let assetsAllBundledInfo: String
    let assetsAllPlaceholderInfo: String
    let assetsMixedSummaryBundled: (Int, Int) -> String
    let assetsMixedSummaryPlaceholder: (Int, Int) -> String
    let assetsDisableBuiltIn: String
    let assetsDisabledBuiltInFlash: String
    let assetsMyImages: String
    let assetsAddImages: String
    let assetsAddFolder: String
    let assetsRemoveAll: String
    let assetsImportFormatsHelp: String
    let assetsBuiltInTitle: String
    let assetsInRotationToggle: String
    let assetsBuiltInRealPhotosHelp: (Int) -> String
    let assetsBuiltInPlaceholdersHelp: String
    let assetsPickPanelTitle: String
    let assetsImportButton: String
    let assetsPickFolderPanel: String
    let assetsPickFolderNote: String
    let assetsWriteFailed: (String) -> String
    let assetsCategoryPromptTitle: String
    let assetsCategoryPromptHelp: String
    let assetsReassignFailed: (String) -> String
    let assetsDeleteConfirmTitle: (String) -> String
    let assetsDeleteConfirmHelp: String
    let assetsDeletedFlash: String
    let assetsDeleteFailed: (String) -> String
    let assetsRemoveAllConfirm: (Int) -> String
    let assetsRemoveAllHelp: String
    let assetsRemovedAllFlash: String
    let assetsRemoveFailed: (String) -> String
    let assetsTipDisable: String
    let assetsTipEnable: String
    let assetsTipDelete: String
    let importAdded: (Int) -> String
    let importSkippedDuplicates: (Int) -> String
    let importUnsupported: (Int) -> String
    let importFailed: (Int) -> String
    let importNothing: String
    let importAndMore: (String, Int) -> String
    let importDuplicatesList: (String) -> String
    let importUnsupportedList: (String) -> String
    let importFailedList: (String) -> String
    let importFailureLine: (String, String) -> String
    let importSummaryWithDetail: (String, String) -> String
    let parenthesized: (String) -> String
    let detailSeparator: String
    let importReasonUnreadable: String
    let importReasonNotImage: String
    let importReasonUndecodable: String
    let importReasonWriteFailed: String
    let noticeSkipTitle: String
    let noticeSkipBody: (Int) -> String
    let noticeSkipAction30: String
    let noticeSkipActionKeep: String
    let noticeSkipActionMute: String
    let captionCredit: (String, Int) -> String
}

extension Strings {
    static let english = Strings(
        appName: "EyeGuard",
        settingsWindowTitle: "EyeGuard Settings",
        commonCancel: "Cancel",
        commonDelete: "Delete",
        countScenes: { String(format: "%d scenes", $0) },
        countScenesTotal: { String(format: "%d total", $0) },
        countScenesEnabled: { String(format: "%d enabled", $0) },
        catCustom: "My Images",
        catMountain: "Mountains",
        catOcean: "Ocean",
        catForest: "Forest",
        catLake: "Lakes",
        catDesert: "Desert",
        catSnow: "Snow",
        catStarfield: "Starfield",
        catGrassland: "Grassland",
        catCanyon: "Canyon",
        catAerial: "Aerial",
        toneCool: "Cool",
        toneWarm: "Warm",
        toneNeutral: "Neutral",
        sourceImported: "My Images",
        sourceBundled: "Bundled",
        sourceDownloaded: "Downloaded",
        sourcePlaceholder: "Placeholder",
        phaseWorking: "Counting down",
        phasePrewarning: "Break soon",
        phaseResting: "Resting",
        phaseSnoozed: "Snoozed",
        phaseSuppressed: "Suppressed",
        phasePaused: "Paused",
        phaseSleeping: "Sleeping",
        targetMouseScreen: "Screen with pointer",
        targetMainScreen: "Main screen",
        targetAllScreens: "All screens",
        reasonIdle: "User away",
        reasonFullscreen: "Fullscreen / presenting",
        reasonCamera: "Camera in use (in a meeting)",
        reasonManual: "Paused manually",
        reasonSleeping: "Screen locked or asleep",
        statusNextBreak: { String(format: "Next break in %@", $0) },
        statusResting: { String(format: "Resting · %d s left", $0) },
        statusSuppressed: "Suppressed",
        statusSuppressedWith: { String(format: "Suppressed: %@", $0) },
        statusPausedUntil: { String(format: "Paused until %@", $0) },
        statusPaused: "Paused",
        statusSleeping: "Sleeping",
        listSeparator: ", ",
        menuShowingCategory: { String(format: "Showing: %@", $0) },
        menuRestNow: "Take a Break Now",
        menuSnooze: { String(format: "Snooze %d min", $0) },
        menuResume: "Resume Reminders",
        menuPause: "Pause",
        menuPauseIndefinitely: "Until I Resume",
        menuPause30: "30 minutes",
        menuPause60: "1 hour",
        menuPauseToday: "No More Today",
        menuSettings: "Settings…",
        menuQuit: "Quit EyeGuard",
        restEmptyLibrary: "No scenes available — add background images in Settings",
        restNextScene: "Next scene",
        restSkip: "Skip",
        restSkipUnlockIn: { String(format: "Skip available in %d s", $0) },
        tabGeneral: "General",
        tabSuppression: "Suppression",
        tabDisplay: "Display",
        tabAssets: "Scenes",
        tabAbout: "About",
        aboutCodeLicense: "Code released under the MIT license.",
        aboutPhotoNote: "The built-in photos come from Wikimedia Commons. Each keeps its own license — the code license above does not cover them.",
        aboutLicenseSummary: "License summary",
        aboutCredits: { String(format: "Photo credits (%d)", $0) },
        secLanguage: "Language",
        labelLanguage: "Interface language",
        helpLanguage: "The interface and the photo descriptions follow the same setting.",
        secRhythm: "Rhythm",
        labelWorkInterval: "Reminder interval",
        unitMinutes: { String(format: "%d min", $0) },
        labelRestDuration: "Break length",
        unitSeconds: { String(format: "%d s", $0) },
        labelPrewarning: "Heads-up before",
        secSkipSnooze: "Skip & snooze",
        labelSkipUnlock: "\"Skip\" unlock delay",
        skipUnlockImmediate: "Immediately",
        labelSnoozeLength: "Snooze length",
        helpSkipUnlock: "The delay before Skip appears is deliberate: skipping should cost a little resolve. A frictionless skip is no reminder at all.",
        secLaunch: "Startup",
        toggleLaunchAtLogin: "Launch at login",
        secTesting: "Testing",
        toggleTestMode: "Developer test mode",
        helpTestMode: "Unlocks 1/2/5-minute intervals and 5/10-second breaks, and shortens the wake cooldown to 5 seconds, so the whole \"auto-trigger\" path can run a full cycle in about a minute. Leave it off for normal use — a reminder every minute is harassment, not eye care.",
        secIdle: "Idle",
        toggleSuppressIdle: "Suppress while you're away",
        labelIdleThreshold: "Idle threshold",
        helpIdleThreshold: "Once you've been idle for this long it counts as \"already rested\", and the timer resets.",
        secForeground: "Foreground",
        toggleSuppressFullscreen: "Suppress in fullscreen apps / presentations",
        toggleSuppressCamera: "Suppress while the camera is in use (in a meeting)",
        helpFullscreen: "Detected as \"the window's top edge covers the menu bar and it matches the screen size\". A maximised window is not mistaken for fullscreen.",
        secOther: "Other",
        helpWakeCooldown: { String(format: "After waking from sleep or unlocking, reminders wait at least %d seconds before they can fire.", $0) },
        helpDoNotDisturb: "macOS has no public API for Do Not Disturb / Focus, so this version doesn't use it as an automatic signal. Use \"Pause\" in the menu bar instead.",
        secMultiDisplay: "Multiple displays",
        labelDisplayTarget: "Show on",
        secNight: "Night",
        toggleNightDimming: "Dim automatically at night",
        labelNightStart: "Night starts",
        labelNightEnd: "Night ends",
        helpNightDimming: "At night the scene is dimmed and bright scenes are avoided, so a sudden full-screen white flash doesn't hit your eyes.",
        assetsInRotationLabel: "In rotation",
        assetsNoneWarning: "No scenes are enabled. The break screen will fall back to a plain colour — the reminder still works, there's just no picture.",
        assetsAllBundledInfo: "You're using only the landscape photos shipped with the app. Use the buttons below to import your own images.",
        assetsAllPlaceholderInfo: "You're using only the procedurally generated placeholder scenes (abstract colour blocks). Use the buttons below to import your own images.",
        assetsMixedSummaryBundled: { String(format: "Imported %d images; %d bundled landscape photos are also in rotation.", $0, $1) },
        assetsMixedSummaryPlaceholder: { String(format: "Imported %d images; %d placeholder scenes are also in rotation.", $0, $1) },
        assetsDisableBuiltIn: "Turn off built-in scenes",
        assetsDisabledBuiltInFlash: "Built-in scenes are off — only your own images will rotate",
        assetsMyImages: "My Images",
        assetsAddImages: "Add Images…",
        assetsAddFolder: "Add Folder…",
        assetsRemoveAll: "Remove All",
        assetsImportFormatsHelp: "Supports JPG / PNG / HEIC / WebP / TIFF / BMP / GIF. Images wider than 2560 pixels are downsampled automatically, so the library doesn't grow for no reason.",
        assetsBuiltInTitle: "Built-in scenes",
        assetsInRotationToggle: "In rotation",
        assetsBuiltInRealPhotosHelp: { String(format: "%d real landscape photos shipped with the app (from Wikimedia Commons; see each image's original page for its licence). Enable or disable by category — the category is the unit the picker uses to avoid showing two similar scenes in a row.", $0) },
        assetsBuiltInPlaceholdersHelp: "Procedurally generated placeholder scenes, used to exercise the whole flow before any real scenes are available. Enable or disable by category — the category is the unit the picker uses to avoid showing two similar scenes in a row.",
        assetsPickPanelTitle: "Choose background images",
        assetsImportButton: "Import",
        assetsPickFolderPanel: "Choose a folder containing background images",
        assetsPickFolderNote: "Only images directly inside this folder are taken; subfolders are not scanned.",
        assetsWriteFailed: { String(format: "Could not write to the scene library: %@", $0) },
        assetsCategoryPromptTitle: "Which category should these images belong to?",
        assetsCategoryPromptHelp: "The category keeps two consecutive scenes from looking alike. If you're not sure, pick \"My Images\" — you can change each one later.",
        assetsReassignFailed: { String(format: "Could not change the category: %@", $0) },
        assetsDeleteConfirmTitle: { String(format: "Delete \"%@\"?", $0) },
        assetsDeleteConfirmHelp: "This also deletes the copy in the scene library. Your original file is untouched.",
        assetsDeletedFlash: "Deleted",
        assetsDeleteFailed: { String(format: "Delete failed: %@", $0) },
        assetsRemoveAllConfirm: { String(format: "Remove all %d imported images?", $0) },
        assetsRemoveAllHelp: "Only the copies in the scene library are deleted; your original files are untouched.",
        assetsRemovedAllFlash: "All removed",
        assetsRemoveFailed: { String(format: "Remove failed: %@", $0) },
        assetsTipDisable: "Click to disable",
        assetsTipEnable: "Click to enable",
        assetsTipDelete: "Remove from library",
        importAdded: { String(format: "%d imported", $0) },
        importSkippedDuplicates: { String(format: "%d duplicates skipped", $0) },
        importUnsupported: { String(format: "%d non-image files", $0) },
        importFailed: { String(format: "%d failed", $0) },
        importNothing: "Nothing to import",
        importAndMore: { String(format: "%@ and %d more", $0, $1) },
        importDuplicatesList: { String(format: "Duplicates: %@", $0) },
        importUnsupportedList: { String(format: "Not images: %@", $0) },
        importFailedList: { String(format: "Failed: %@", $0) },
        importFailureLine: { String(format: "%@: %@", $0, $1) },
        importSummaryWithDetail: { String(format: "%@ — %@", $0, $1) },
        parenthesized: { String(format: "(%@)", $0) },
        detailSeparator: "; ",
        importReasonUnreadable: "Could not read file",
        importReasonNotImage: "Not a recognizable image",
        importReasonUndecodable: "Could not decode",
        importReasonWriteFailed: "Write failed",
        noticeSkipTitle: "You've skipped several breaks in a row",
        noticeSkipBody: { String(format: "If a %d-minute interval feels too frequent, a longer interval is usually easier to stick with.", $0) },
        noticeSkipAction30: "Use 30 minutes",
        noticeSkipActionKeep: "Keep current interval",
        noticeSkipActionMute: "Don't ask again",
        captionCredit: { String(format: "%@ · %d", $0, $1) },
    )

    static let simplifiedChinese = Strings(
        appName: "EyeGuard",
        settingsWindowTitle: "EyeGuard 设置",
        commonCancel: "取消",
        commonDelete: "删除",
        countScenes: { String(format: "%d 张", $0) },
        countScenesTotal: { String(format: "共 %d 张", $0) },
        countScenesEnabled: { String(format: "%d 张启用", $0) },
        catCustom: "我的图片",
        catMountain: "山峦",
        catOcean: "海洋",
        catForest: "森林",
        catLake: "湖泊",
        catDesert: "沙漠",
        catSnow: "雪原",
        catStarfield: "星空",
        catGrassland: "草原",
        catCanyon: "峡谷",
        catAerial: "高空俯瞰",
        toneCool: "冷调",
        toneWarm: "暖调",
        toneNeutral: "中性",
        sourceImported: "我的图片",
        sourceBundled: "预置",
        sourceDownloaded: "已下载",
        sourcePlaceholder: "占位素材",
        phaseWorking: "计时中",
        phasePrewarning: "即将休息",
        phaseResting: "休息中",
        phaseSnoozed: "已延后",
        phaseSuppressed: "顺延中",
        phasePaused: "已暂停",
        phaseSleeping: "休眠中",
        targetMouseScreen: "鼠标所在屏幕",
        targetMainScreen: "主屏幕",
        targetAllScreens: "全部屏幕",
        reasonIdle: "用户离开",
        reasonFullscreen: "前台全屏 / 演示中",
        reasonCamera: "摄像头被占用（会议中）",
        reasonManual: "手动暂停",
        reasonSleeping: "锁屏或系统休眠",
        statusNextBreak: { String(format: "距离下次休息 %@", $0) },
        statusResting: { String(format: "休息中 · 还剩 %d 秒", $0) },
        statusSuppressed: "顺延中",
        statusSuppressedWith: { String(format: "顺延中：%@", $0) },
        statusPausedUntil: { String(format: "已暂停至 %@", $0) },
        statusPaused: "已暂停",
        statusSleeping: "休眠中",
        listSeparator: "、",
        menuShowingCategory: { String(format: "正在展示：%@", $0) },
        menuRestNow: "立即休息",
        menuSnooze: { String(format: "延后 %d 分钟", $0) },
        menuResume: "恢复提醒",
        menuPause: "暂停",
        menuPauseIndefinitely: "直到手动恢复",
        menuPause30: "30 分钟",
        menuPause60: "1 小时",
        menuPauseToday: "今天不再提醒",
        menuSettings: "设置…",
        menuQuit: "退出 EyeGuard",
        restEmptyLibrary: "素材库为空，可在设置里添加背景图片",
        restNextScene: "换一张",
        restSkip: "跳过",
        restSkipUnlockIn: { String(format: "跳过将在 %d 秒后可用", $0) },
        tabGeneral: "常规",
        tabSuppression: "顺延",
        tabDisplay: "显示",
        tabAssets: "素材",
        tabAbout: "关于",
        aboutCodeLicense: "代码以 MIT 许可发布。",
        aboutPhotoNote: "内置风景照来自 Wikimedia Commons，各自适用其原始许可 —— 上面的代码许可不覆盖它们。",
        aboutLicenseSummary: "授权分布",
        aboutCredits: { String(format: "素材来源（共 %d 条）", $0) },
        secLanguage: "语言",
        labelLanguage: "界面语言",
        helpLanguage: "界面与图片介绍都跟随这一项。",
        secRhythm: "节奏",
        labelWorkInterval: "提醒间隔",
        unitMinutes: { String(format: "%d 分钟", $0) },
        labelRestDuration: "单次休息时长",
        unitSeconds: { String(format: "%d 秒", $0) },
        labelPrewarning: "提前预告",
        secSkipSnooze: "跳过与延后",
        labelSkipUnlock: "「跳过」解锁延迟",
        skipUnlockImmediate: "立即可跳过",
        labelSnoozeLength: "延后时长",
        helpSkipUnlock: "跳过按钮延迟出现，是为了让「跳过」需要一点决心 —— 完全无摩擦的跳过等于没有提醒。",
        secLaunch: "启动",
        toggleLaunchAtLogin: "开机自动启动",
        secTesting: "测试",
        toggleTestMode: "开发者测试模式",
        helpTestMode: "解锁 1/2/5 分钟的间隔与 5/10 秒的休息时长，唤醒冷却缩短到 5 秒，让「自动触发」这条核心路径能在一分多钟内跑完一轮。正常使用时请关闭 —— 1 分钟提醒一次是骚扰，不是护眼。",
        secIdle: "空闲",
        toggleSuppressIdle: "用户离开时顺延",
        labelIdleThreshold: "空闲判定阈值",
        helpIdleThreshold: "空闲达到阈值会被视为「已经休息过」，计时器重置。",
        secForeground: "前台场景",
        toggleSuppressFullscreen: "全屏应用 / 演示中顺延",
        toggleSuppressCamera: "摄像头被占用（会议中）顺延",
        helpFullscreen: "判定为「窗口顶边覆盖菜单栏且尺寸与屏幕一致」。最大化窗口不会被误判为全屏。",
        secOther: "其他",
        helpWakeCooldown: { String(format: "从休眠唤醒或解锁后，至少等待 %d 秒才允许触发提醒。", $0) },
        helpDoNotDisturb: "「勿扰 / 专注模式」在 macOS 上没有公开 API，本版本不作为自动判断依据，请使用菜单栏的「暂停」。",
        secMultiDisplay: "多屏",
        labelDisplayTarget: "展示屏幕",
        secNight: "夜间",
        toggleNightDimming: "夜间自动压暗",
        labelNightStart: "夜间开始",
        labelNightEnd: "夜间结束",
        helpNightDimming: "夜间会压暗画面并避开高亮度素材，避免突然的全屏白亮刺激。",
        assetsInRotationLabel: "当前参与轮播",
        assetsNoneWarning: "没有任何可用素材。休息画面会退化成纯色背景 —— 提醒照常，只是没有配图。",
        assetsAllBundledInfo: "当前全部使用随 App 分发的预置风景照。点下面的按钮可以导入你自己的图片。",
        assetsAllPlaceholderInfo: "当前全部使用程序化生成的占位场景（抽象色块）。点下面的按钮导入你自己的图片。",
        assetsMixedSummaryBundled: { String(format: "已导入 %d 张图片，另有 %d 张预置风景照在轮播中。", $0, $1) },
        assetsMixedSummaryPlaceholder: { String(format: "已导入 %d 张图片，另有 %d 张占位场景在轮播中。", $0, $1) },
        assetsDisableBuiltIn: "关闭内置场景",
        assetsDisabledBuiltInFlash: "已关闭内置场景，现在只轮播你的图片",
        assetsMyImages: "我的图片",
        assetsAddImages: "添加图片…",
        assetsAddFolder: "添加文件夹…",
        assetsRemoveAll: "全部移除",
        assetsImportFormatsHelp: "支持 JPG / PNG / HEIC / WebP / TIFF / BMP / GIF。超过 2560 像素的图会自动降采样，避免素材库无谓地变大。",
        assetsBuiltInTitle: "内置场景",
        assetsInRotationToggle: "参与轮播",
        assetsBuiltInRealPhotosHelp: { String(format: "随 App 分发的 %d 张真实风景照（来源 Wikimedia Commons，许可见各图原始页面）。按类别启用/禁用 —— 类别是选片算法保证「相邻两次画面不雷同」的单位。", $0) },
        assetsBuiltInPlaceholdersHelp: "程序化生成的占位场景，用来在还没有真实素材时跑通流程。按类别启用/禁用 —— 类别是选片算法保证「相邻两次画面不雷同」的单位。",
        assetsPickPanelTitle: "选择背景图片",
        assetsImportButton: "导入",
        assetsPickFolderPanel: "选择包含背景图片的文件夹",
        assetsPickFolderNote: "只取这个文件夹里直接包含的图片，不会递归子文件夹",
        assetsWriteFailed: { String(format: "写入素材库失败：%@", $0) },
        assetsCategoryPromptTitle: "这批图片算作哪一类？",
        assetsCategoryPromptHelp: "类别用于保证相邻两次展示的画面不雷同。不确定就选「我的图片」，之后可以逐张修改。",
        assetsReassignFailed: { String(format: "改类别失败：%@", $0) },
        assetsDeleteConfirmTitle: { String(format: "删除「%@」？", $0) },
        assetsDeleteConfirmHelp: "会同时删掉素材库里这份拷贝。你原来的文件不受影响。",
        assetsDeletedFlash: "已删除",
        assetsDeleteFailed: { String(format: "删除失败：%@", $0) },
        assetsRemoveAllConfirm: { String(format: "移除全部 %d 张导入的图片？", $0) },
        assetsRemoveAllHelp: "只删素材库里的拷贝，你原来的文件不受影响。",
        assetsRemovedAllFlash: "已全部移除",
        assetsRemoveFailed: { String(format: "移除失败：%@", $0) },
        assetsTipDisable: "点击禁用",
        assetsTipEnable: "点击启用",
        assetsTipDelete: "从素材库删除",
        importAdded: { String(format: "导入 %d 张", $0) },
        importSkippedDuplicates: { String(format: "跳过重复 %d 张", $0) },
        importUnsupported: { String(format: "非图片 %d 个", $0) },
        importFailed: { String(format: "失败 %d 张", $0) },
        importNothing: "没有可导入的文件",
        importAndMore: { String(format: "%@ 等 %d 个", $0, $1) },
        importDuplicatesList: { String(format: "重复：%@", $0) },
        importUnsupportedList: { String(format: "非图片：%@", $0) },
        importFailedList: { String(format: "失败：%@", $0) },
        importFailureLine: { String(format: "%@：%@", $0, $1) },
        importSummaryWithDetail: { String(format: "%@ —— %@", $0, $1) },
        parenthesized: { String(format: "（%@）", $0) },
        detailSeparator: "；",
        importReasonUnreadable: "读不到文件",
        importReasonNotImage: "不是可识别的图片",
        importReasonUndecodable: "无法解码",
        importReasonWriteFailed: "写入失败",
        noticeSkipTitle: "你最近连续跳过了几次休息",
        noticeSkipBody: { String(format: "如果 %d 分钟的间隔太频繁，把间隔调长一些通常更容易坚持下来。", $0) },
        noticeSkipAction30: "改为 30 分钟",
        noticeSkipActionKeep: "保持当前间隔",
        noticeSkipActionMute: "不再提示",
        captionCredit: { String(format: "%@ · %d", $0, $1) },
    )
}
