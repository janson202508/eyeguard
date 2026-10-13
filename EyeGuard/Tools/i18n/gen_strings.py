#!/usr/bin/env python3
"""生成 EyeGuard 的双语文案表。

权威数据在本脚本的 TABLE 里（同时导出 Tools/i18n/strings.json 供人工核对），
产物是 Sources/EyeGuard/Models/Strings.swift。

为什么用「生成」而不是「手写 Swift」：
  近 170 条文案分两个语言、散在十几个文件里，手写必然漏。生成之后，
  `Strings` 的每个字段都是 `let`，**少一条就编译不过** —— 把「漏翻译」
  从「上线后才发现」变成「构建时就知道」。同时 JSON 可以整份交给别人核对。

用法：
    python3 Tools/i18n/gen_strings.py            # 生成
    python3 Tools/i18n/gen_strings.py --check    # 只校验两语言键集是否一致
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SWIFT_OUT = os.path.join(ROOT, "Sources", "EyeGuard", "Models", "Strings.swift")
JSON_OUT = os.path.join(HERE, "strings.json")

HAN = re.compile(r"[\u4e00-\u9fff]")

# ---------------------------------------------------------------------------
# 文案表
#
# 元组：(key, 类型, en, zh-Hans)
#   类型 s   普通字符串                    -> let key: String
#   类型 i   一个整数参数                  -> let key: (Int) -> String
#   类型 str 一个字符串参数                -> let key: (String) -> String
#   类型 is  整数 + 字符串                 -> let key: (Int, String) -> String
#   类型 iis 两个整数 + 一个字符串         -> let key: (Int, Int, String) -> String
#   类型 ss  两个字符串                    -> let key: (String, String) -> String
#
# ⚠️ 类型为 i/str/is/iis/ss 的，en 与 zh 里写的是 **printf 格式串**。
# ---------------------------------------------------------------------------

TABLE = [
    # ---------------- 通用 ----------------
    ("appName",                    "s", "EyeGuard", "EyeGuard"),
    ("settingsWindowTitle",        "s", "EyeGuard Settings", "EyeGuard 设置"),
    ("commonCancel",               "s", "Cancel", "取消"),
    ("commonDelete",               "s", "Delete", "删除"),
    ("countScenes",                "i", "%d scenes", "%d 张"),
    ("countScenesTotal",           "i", "%d total", "共 %d 张"),
    ("countScenesEnabled",         "i", "%d enabled", "%d 张启用"),

    # ---------------- 场景类别 ----------------
    ("catCustom",      "s", "My Images",  "我的图片"),
    ("catMountain",    "s", "Mountains",  "山峦"),
    ("catOcean",       "s", "Ocean",      "海洋"),
    ("catForest",      "s", "Forest",     "森林"),
    ("catLake",        "s", "Lakes",      "湖泊"),
    ("catDesert",      "s", "Desert",     "沙漠"),
    ("catSnow",        "s", "Snow",       "雪原"),
    ("catStarfield",   "s", "Starfield",  "星空"),
    ("catGrassland",   "s", "Grassland",  "草原"),
    ("catCanyon",      "s", "Canyon",     "峡谷"),
    ("catAerial",      "s", "Aerial",     "高空俯瞰"),

    # ---------------- 色调 ----------------
    ("toneCool",    "s", "Cool",    "冷调"),
    ("toneWarm",    "s", "Warm",    "暖调"),
    ("toneNeutral", "s", "Neutral", "中性"),

    # ---------------- 素材来源 ----------------
    ("sourceImported",    "s", "My Images",  "我的图片"),
    ("sourceBundled",     "s", "Bundled",    "预置"),
    ("sourceDownloaded",  "s", "Downloaded", "已下载"),
    ("sourcePlaceholder", "s", "Placeholder","占位素材"),

    # ---------------- 状态 ----------------
    ("phaseWorking",    "s", "Counting down", "计时中"),
    ("phasePrewarning", "s", "Break soon",    "即将休息"),
    ("phaseResting",    "s", "Resting",       "休息中"),
    ("phaseSnoozed",    "s", "Snoozed",       "已延后"),
    ("phaseSuppressed", "s", "Suppressed",    "顺延中"),
    ("phasePaused",     "s", "Paused",        "已暂停"),
    ("phaseSleeping",   "s", "Sleeping",      "休眠中"),

    # ---------------- 展示屏幕 ----------------
    ("targetMouseScreen", "s", "Screen with pointer", "鼠标所在屏幕"),
    ("targetMainScreen",  "s", "Main screen",         "主屏幕"),
    ("targetAllScreens",  "s", "All screens",         "全部屏幕"),

    # ---------------- 顺延原因 ----------------
    ("reasonIdle",       "s", "User away",                "用户离开"),
    ("reasonFullscreen", "s", "Fullscreen / presenting",  "前台全屏 / 演示中"),
    ("reasonCamera",     "s", "Camera in use (in a meeting)", "摄像头被占用（会议中）"),
    ("reasonManual",     "s", "Paused manually",          "手动暂停"),
    ("reasonSleeping",   "s", "Screen locked or asleep",  "锁屏或系统休眠"),

    # ---------------- 状态文案（菜单栏 / 通知） ----------------
    ("statusNextBreak",      "str", "Next break in %@",  "距离下次休息 %@"),
    ("statusResting",        "i",   "Resting · %d s left", "休息中 · 还剩 %d 秒"),
    ("statusSuppressed",     "s",   "Suppressed",        "顺延中"),
    ("statusSuppressedWith", "str", "Suppressed: %@",    "顺延中：%@"),
    ("statusPausedUntil",    "str", "Paused until %@",   "已暂停至 %@"),
    ("statusPaused",         "s",   "Paused",            "已暂停"),
    ("statusSleeping",       "s",   "Sleeping",          "休眠中"),
    ("listSeparator",        "s",   ", ",                "、"),

    # ⛔️ 主文案池（prompt01–05 / promptFallback）与 FR-6 于 2026-10-13 随引导句一起取消。
    #    旧文案（恢复时用）：
    #      抬头，看向 6 米外的某个细节 / Look up at something 20 feet away
    #      看向窗外最远的那个点     / Look at the farthest point outside the window
    #      离开屏幕，望向房间尽头   / Look away from the screen, to the far end of the room
    #      抬头，找一个最远的物体看清它 / Look up and bring the farthest object into focus
    #      望向远处，让眼睛换个焦距 / Look into the distance and let your eyes refocus
    #      抬头，看向远处           / Look up into the distance   （fallback）

    # ---------------- 菜单栏 ----------------
    ("menuShowingCategory",  "str", "Showing: %@",     "正在展示：%@"),
    ("menuRestNow",          "s",   "Take a Break Now","立即休息"),
    ("menuSnooze",           "i",   "Snooze %d min",   "延后 %d 分钟"),
    ("menuResume",           "s",   "Resume Reminders","恢复提醒"),
    ("menuPause",            "s",   "Pause",           "暂停"),
    ("menuPauseIndefinitely","s",   "Until I Resume",  "直到手动恢复"),
    ("menuPause30",          "s",   "30 minutes",      "30 分钟"),
    ("menuPause60",          "s",   "1 hour",          "1 小时"),
    ("menuPauseToday",       "s",   "No More Today",   "今天不再提醒"),
    ("menuSettings",         "s",   "Settings…",       "设置…"),
    ("menuQuit",             "s",   "Quit EyeGuard",   "退出 EyeGuard"),

    # ---------------- 休息画面 ----------------
    ("restEmptyLibrary", "s", "No scenes available — add background images in Settings",
                             "素材库为空，可在设置里添加背景图片"),
    ("restNextScene",    "s", "Next scene", "换一张"),
    ("restSkip",         "s", "Skip",       "跳过"),
    ("restSkipUnlockIn", "i", "Skip available in %d s", "跳过将在 %d 秒后可用"),

    # ---------------- 设置 · 标签页 ----------------
    ("tabGeneral",     "s", "General",     "常规"),
    ("tabSuppression", "s", "Suppression", "顺延"),
    ("tabDisplay",     "s", "Display",     "显示"),
    ("tabAssets",      "s", "Scenes",      "素材"),
    ("tabAbout",       "s", "About",       "关于"),

    # ---------------- 设置 · 关于 / 许可（FR-12） ----------------
    # CC BY / CC BY-SA 要求**署名 + 许可声明 + 链接**三件套。
    # 这三条文案 + 下面那个逐条列表就是「三件套」的界面载体 ——
    # 缺了它，分发带 CC 素材的 App 就是侵权。
    ("aboutCodeLicense", "s",
        "Code released under the MIT license.",
        "代码以 MIT 许可发布。"),
    ("aboutPhotoNote", "s",
        "The built-in photos come from Wikimedia Commons. Each keeps its own license — "
        "the code license above does not cover them.",
        "内置风景照来自 Wikimedia Commons，各自适用其原始许可 —— 上面的代码许可不覆盖它们。"),
    ("aboutLicenseSummary", "s", "License summary", "授权分布"),
    ("aboutCredits", "i", "Photo credits (%d)", "素材来源（共 %d 条）"),

    # ---------------- 设置 · 常规 ----------------
    ("secLanguage",   "s", "Language", "语言"),
    ("labelLanguage", "s", "Interface language", "界面语言"),
    ("helpLanguage", "s",
        "The interface and the photo descriptions follow the same setting.",
        "界面与图片介绍都跟随这一项。"),

    ("secRhythm", "s", "Rhythm", "节奏"),
    ("labelWorkInterval", "s", "Reminder interval", "提醒间隔"),
    ("unitMinutes",       "i", "%d min", "%d 分钟"),
    ("labelRestDuration", "s", "Break length", "单次休息时长"),
    ("unitSeconds",       "i", "%d s", "%d 秒"),
    ("labelPrewarning",   "s", "Heads-up before", "提前预告"),

    ("secSkipSnooze",      "s", "Skip & snooze", "跳过与延后"),
    ("labelSkipUnlock",    "s", "\"Skip\" unlock delay", "「跳过」解锁延迟"),
    ("skipUnlockImmediate","s", "Immediately", "立即可跳过"),
    ("labelSnoozeLength",  "s", "Snooze length", "延后时长"),
    ("helpSkipUnlock", "s",
        "The delay before Skip appears is deliberate: skipping should cost a little "
        "resolve. A frictionless skip is no reminder at all.",
        "跳过按钮延迟出现，是为了让「跳过」需要一点决心 —— 完全无摩擦的跳过等于没有提醒。"),

    ("secLaunch",         "s", "Startup", "启动"),
    ("toggleLaunchAtLogin","s", "Launch at login", "开机自动启动"),

    ("secTesting",     "s", "Testing", "测试"),
    ("toggleTestMode", "s", "Developer test mode", "开发者测试模式"),
    ("helpTestMode", "s",
        "Unlocks 1/2/5-minute intervals and 5/10-second breaks, and shortens the wake "
        "cooldown to 5 seconds, so the whole \"auto-trigger\" path can run a full cycle "
        "in about a minute. Leave it off for normal use — a reminder every minute is "
        "harassment, not eye care.",
        "解锁 1/2/5 分钟的间隔与 5/10 秒的休息时长，唤醒冷却缩短到 5 秒，"
        "让「自动触发」这条核心路径能在一分多钟内跑完一轮。"
        "正常使用时请关闭 —— 1 分钟提醒一次是骚扰，不是护眼。"),

    # ---------------- 设置 · 顺延 ----------------
    ("secIdle",              "s", "Idle", "空闲"),
    ("toggleSuppressIdle",   "s", "Suppress while you're away", "用户离开时顺延"),
    ("labelIdleThreshold",   "s", "Idle threshold", "空闲判定阈值"),
    ("helpIdleThreshold", "s",
        "Once you've been idle for this long it counts as \"already rested\", and the "
        "timer resets.",
        "空闲达到阈值会被视为「已经休息过」，计时器重置。"),

    ("secForeground",             "s", "Foreground", "前台场景"),
    ("toggleSuppressFullscreen",  "s", "Suppress in fullscreen apps / presentations",
                                       "全屏应用 / 演示中顺延"),
    ("toggleSuppressCamera",      "s", "Suppress while the camera is in use (in a meeting)",
                                       "摄像头被占用（会议中）顺延"),
    ("helpFullscreen", "s",
        "Detected as \"the window's top edge covers the menu bar and it matches the "
        "screen size\". A maximised window is not mistaken for fullscreen.",
        "判定为「窗口顶边覆盖菜单栏且尺寸与屏幕一致」。最大化窗口不会被误判为全屏。"),

    ("secOther",        "s", "Other", "其他"),
    ("helpWakeCooldown", "i",
        "After waking from sleep or unlocking, reminders wait at least %d seconds "
        "before they can fire.",
        "从休眠唤醒或解锁后，至少等待 %d 秒才允许触发提醒。"),
    ("helpDoNotDisturb", "s",
        "macOS has no public API for Do Not Disturb / Focus, so this version doesn't "
        "use it as an automatic signal. Use \"Pause\" in the menu bar instead.",
        "「勿扰 / 专注模式」在 macOS 上没有公开 API，本版本不作为自动判断依据，"
        "请使用菜单栏的「暂停」。"),

    # ---------------- 设置 · 显示 ----------------
    ("secMultiDisplay",   "s", "Multiple displays", "多屏"),
    ("labelDisplayTarget","s", "Show on", "展示屏幕"),

    ("secNight",          "s", "Night", "夜间"),
    ("toggleNightDimming","s", "Dim automatically at night", "夜间自动压暗"),
    ("labelNightStart",   "s", "Night starts", "夜间开始"),
    ("labelNightEnd",     "s", "Night ends",   "夜间结束"),
    ("helpNightDimming", "s",
        "At night the scene is dimmed and bright scenes are avoided, so a sudden "
        "full-screen white flash doesn't hit your eyes.",
        "夜间会压暗画面并避开高亮度素材，避免突然的全屏白亮刺激。"),

    # ---------------- 设置 · 素材 ----------------
    ("assetsInRotationLabel", "s", "In rotation", "当前参与轮播"),
    ("assetsNoneWarning", "s",
        "No scenes are enabled. The break screen will fall back to a plain colour — "
        "the reminder still works, there's just no picture.",
        "没有任何可用素材。休息画面会退化成纯色背景 —— 提醒照常，只是没有配图。"),
    ("assetsAllBundledInfo", "s",
        "You're using only the landscape photos shipped with the app. Use the buttons "
        "below to import your own images.",
        "当前全部使用随 App 分发的预置风景照。点下面的按钮可以导入你自己的图片。"),
    ("assetsAllPlaceholderInfo", "s",
        "You're using only the procedurally generated placeholder scenes (abstract "
        "colour blocks). Use the buttons below to import your own images.",
        "当前全部使用程序化生成的占位场景（抽象色块）。点下面的按钮导入你自己的图片。"),
    # 这两个键的「预置风景照 / 占位场景」是**写在句子里**的，不是传进来的参数。
    # 早期版本把名词当第三个参数传，结果是 `String(format:)` 收到一个用不上的
    # 参数（格式串里只有两个 %d）—— 类型声明骗过了编译器，运行时静默丢弃。
    # 中英文的名词位置不同，让每种语言各写一整句才是唯一不会错的做法。
    ("assetsMixedSummaryBundled", "ii",
        "Imported %d images; %d bundled landscape photos are also in rotation.",
        "已导入 %d 张图片，另有 %d 张预置风景照在轮播中。"),
    ("assetsMixedSummaryPlaceholder", "ii",
        "Imported %d images; %d placeholder scenes are also in rotation.",
        "已导入 %d 张图片，另有 %d 张占位场景在轮播中。"),
    ("assetsDisableBuiltIn", "s", "Turn off built-in scenes", "关闭内置场景"),
    ("assetsDisabledBuiltInFlash", "s",
        "Built-in scenes are off — only your own images will rotate",
        "已关闭内置场景，现在只轮播你的图片"),
    ("assetsMyImages",   "s", "My Images",  "我的图片"),
    ("assetsAddImages",  "s", "Add Images…", "添加图片…"),
    ("assetsAddFolder",  "s", "Add Folder…", "添加文件夹…"),
    ("assetsRemoveAll",  "s", "Remove All",  "全部移除"),
    # 一整句，不在调用点拼「格式说明」+「降采样说明」两个片段：
    # 英文句号后要空格、中文句号后不要，粘起来必有一边是错的。
    ("assetsImportFormatsHelp", "s",
        "Supports JPG / PNG / HEIC / WebP / TIFF / BMP / GIF. Images wider than 2560 "
        "pixels are downsampled automatically, so the library doesn't grow for no reason.",
        "支持 JPG / PNG / HEIC / WebP / TIFF / BMP / GIF。"
        "超过 2560 像素的图会自动降采样，避免素材库无谓地变大。"),

    # 「预置风景照 / 占位场景」这两个名词**没有单独的键** —— 它们写在上面的
    # 整句里。单独列一个键再由调用点拼进去，等于把语序决定权交给代码。
    ("assetsBuiltInTitle",        "s", "Built-in scenes", "内置场景"),
    ("assetsInRotationToggle",    "s", "In rotation", "参与轮播"),
    # 同样是一整句。中文的「（来源 …）」用全角括号紧跟在前半句后，英文用半角括号
    # 且前面要空格 —— 只有整句交给译者才能两边都对。
    ("assetsBuiltInRealPhotosHelp", "i",
        "%d real landscape photos shipped with the app (from Wikimedia Commons; see each "
        "image's original page for its licence). Enable or disable by category — the "
        "category is the unit the picker uses to avoid showing two similar scenes in a row.",
        "随 App 分发的 %d 张真实风景照（来源 Wikimedia Commons，许可见各图原始页面）。"
        "按类别启用/禁用 —— 类别是选片算法保证「相邻两次画面不雷同」的单位。"),
    ("assetsBuiltInPlaceholdersHelp", "s",
        "Procedurally generated placeholder scenes, used to exercise the whole flow "
        "before any real scenes are available. Enable or disable by category — the "
        "category is the unit the picker uses to avoid showing two similar scenes in a row.",
        "程序化生成的占位场景，用来在还没有真实素材时跑通流程。"
        "按类别启用/禁用 —— 类别是选片算法保证「相邻两次画面不雷同」的单位。"),

    ("assetsPickPanelTitle",  "s", "Choose background images", "选择背景图片"),
    ("assetsImportButton",    "s", "Import", "导入"),
    ("assetsPickFolderPanel", "s", "Choose a folder containing background images",
                                   "选择包含背景图片的文件夹"),
    ("assetsPickFolderNote", "s",
        "Only images directly inside this folder are taken; subfolders are not scanned.",
        "只取这个文件夹里直接包含的图片，不会递归子文件夹"),
    ("assetsWriteFailed", "str",
        "Could not write to the scene library: %@",
        "写入素材库失败：%@"),

    ("assetsCategoryPromptTitle", "s", "Which category should these images belong to?",
                                       "这批图片算作哪一类？"),
    ("assetsCategoryPromptHelp", "s",
        "The category keeps two consecutive scenes from looking alike. If you're not "
        "sure, pick \"My Images\" — you can change each one later.",
        "类别用于保证相邻两次展示的画面不雷同。不确定就选「我的图片」，之后可以逐张修改。"),
    ("assetsReassignFailed", "str",
        "Could not change the category: %@", "改类别失败：%@"),

    ("assetsDeleteConfirmTitle", "str", "Delete \"%@\"?", "删除「%@」？"),
    ("assetsDeleteConfirmHelp", "s",
        "This also deletes the copy in the scene library. Your original file is untouched.",
        "会同时删掉素材库里这份拷贝。你原来的文件不受影响。"),
    ("assetsDeletedFlash", "s", "Deleted", "已删除"),
    ("assetsDeleteFailed", "str", "Delete failed: %@", "删除失败：%@"),

    ("assetsRemoveAllConfirm", "i", "Remove all %d imported images?",
                                     "移除全部 %d 张导入的图片？"),
    ("assetsRemoveAllHelp", "s",
        "Only the copies in the scene library are deleted; your original files are "
        "untouched.",
        "只删素材库里的拷贝，你原来的文件不受影响。"),
    ("assetsRemovedAllFlash", "s", "All removed", "已全部移除"),
    ("assetsRemoveFailed",    "str", "Remove failed: %@", "移除失败：%@"),

    ("assetsTipDisable", "s", "Click to disable", "点击禁用"),
    ("assetsTipEnable",  "s", "Click to enable",  "点击启用"),
    ("assetsTipDelete",  "s", "Remove from library", "从素材库删除"),

    # ---------------- 导入结果 ----------------
    #
    # ⚠️ 英文这四条写成**小写的名词短语**，因为它们会被 `listSeparator`
    # 拼成一行列表："8 imported, 2 duplicates skipped"。
    # 若写成 "Imported 8" / "Skipped 2"，逗号后面会出现大写动词，是明显的英文病句。
    ("importAdded",             "i", "%d imported", "导入 %d 张"),
    ("importSkippedDuplicates", "i", "%d duplicates skipped", "跳过重复 %d 张"),
    ("importUnsupported",       "i", "%d non-image files", "非图片 %d 个"),
    ("importFailed",            "i", "%d failed", "失败 %d 张"),
    ("importNothing",           "s", "Nothing to import", "没有可导入的文件"),
    ("importAndMore",           "si", "%@ and %d more", "%@ 等 %d 个"),
    ("importDuplicatesList",    "str", "Duplicates: %@", "重复：%@"),
    ("importUnsupportedList",   "str", "Not images: %@", "非图片：%@"),
    ("importFailedList",        "str", "Failed: %@", "失败：%@"),
    # 「文件名 + 原因」的连接符：英文用半角冒号加空格，中文用全角冒号。
    ("importFailureLine",       "ss", "%@: %@", "%@：%@"),
    # 「摘要 —— 明细」的连接符同样是语言相关的（破折号长度不同）。
    ("importSummaryWithDetail", "ss", "%@ — %@", "%@ —— %@"),
    ("parenthesized",           "str", "(%@)", "（%@）"),
    ("detailSeparator",         "s", "; ", "；"),
    ("importReasonUnreadable",  "s", "Could not read file", "读不到文件"),
    ("importReasonNotImage",    "s", "Not a recognizable image", "不是可识别的图片"),
    ("importReasonUndecodable", "s", "Could not decode", "无法解码"),
    ("importReasonWriteFailed", "s", "Write failed", "写入失败"),
    # ⚠️ `SceneAsset.license` **不在这里**：它是**落盘的字段，不是界面文案**
    # （全仓只有写入、没有读取渲染）。存进去的值一旦随界面语言变，
    # manifest.json 里就会出现「同一批导入的图，license 一半英文一半中文」——
    # 那是用界面设置污染了数据。要改就改成一个与语言无关的稳定标识，
    # 而不是把它接进文案表。

    # ---------------- 跳过连击提示（系统通知） ----------------
    # ⚠️ 正文是**一整句**，不是「前半句 + 后半句」两段拼起来。
    # 英文前半句以逗号结尾、后半句以小写字母开头，中间**必须有一个空格**；
    # 中文按全角标点习惯不加空格。粘两段必然有一边是错的。
    ("noticeSkipTitle", "s", "You've skipped several breaks in a row",
                             "你最近连续跳过了几次休息"),
    ("noticeSkipBody",  "i",
        "If a %d-minute interval feels too frequent, a longer interval is usually "
        "easier to stick with.",
        "如果 %d 分钟的间隔太频繁，把间隔调长一些通常更容易坚持下来。"),
    ("noticeSkipAction30",   "s", "Use 30 minutes", "改为 30 分钟"),
    ("noticeSkipActionKeep", "s", "Keep current interval", "保持当前间隔"),
    ("noticeSkipActionMute", "s", "Don't ask again", "不再提示"),

    # ---------------- 图片介绍（FR-11） ----------------
    # 介绍下方的出处行「作者 · 年份」。作者名与年份都是数据（不翻译），
    # 这里只是把两者拼成一行 —— 所以它是一个**带格式符的整句**，
    # 而不是在调用点自己拼 "作者 + \" · \" + 年份"。
    ("captionCredit", "si", "%@ · %d", "%@ · %d"),

]

CLOSURE_TYPE = {
    "i":   ("(Int) -> String",            ["$0"]),
    "ii":  ("(Int, Int) -> String",       ["$0", "$1"]),
    "str": ("(String) -> String",         ["$0"]),
    "is":  ("(Int, String) -> String",    ["$0", "$1"]),
    "si":  ("(String, Int) -> String",    ["$0", "$1"]),
    "iis": ("(Int, Int, String) -> String", ["$0", "$1", "$2"]),
    "ss":  ("(String, String) -> String", ["$0", "$1"]),
}

# 每种类型的**参数顺序**，必须与格式串里格式符的出现顺序一致：
#   i = 整数（%d），s = 字符串（%@）
#
# ⚠️ 这条检查是因为 `importAndMore` 曾经声明成 `is`（整数在前）而格式串是
# `"%@ and %d more"`（字符串在前）才补上的。当时的检查只数了「格式符个数」，
# 个数对得上（都是 2），所以一路编译通过、跑起来也「看着正常」——
# 只是 `String(format:)` 把字符串当整数读。**数个数是不够的，顺序也要管。**
KIND_PARAMS = {
    "s":   "",
    "i":   "i",
    "ii":  "ii",
    "str": "s",
    "is":  "is",
    "si":  "si",
    "iis": "iis",
    "ss":  "ss",
}


def spec_kinds(fmt):
    """把格式串里的格式符按出现顺序译成 'i'（整数）/ 's'（字符串）。"""
    out = []
    for m in re.finditer(r"%([-+ #0]*[0-9]*(?:\.[0-9]+)?[@dioufegsxX])", fmt):
        out.append("i" if m.group(1)[-1] in "diou" else "s")
    return "".join(out)


def swift_literal(s):
    out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{out}"'


def main():
    keys = [row[0] for row in TABLE]
    dupes = {k for k in keys if keys.count(k) > 1}
    if dupes:
        print("✗ 键重复：", sorted(dupes))
        return 1
    for key, kind, en, zh in TABLE:
        if not en.strip() or not zh.strip():
            print(f"✗ {key} 有语言缺内容")
            return 1
        # 英文里出现汉字 ⇒ 一定是「忘了翻，直接把中文抄过去了」。
        #
        # ⚠️ 这条检查**只能放在生成器里**，不能放到运行时的自检里：
        # 运行时拿到的是**渲染后的句子**，里面会嵌用户数据（文件名、地名），
        # 用户叫「风景.jpg」就会让「英文里有没有汉字」误报。
        # 这里看到的是**模板本身**，不受任何用户数据干扰。
        if HAN.search(en):
            print(f"✗ {key} 的英文里混进了汉字：{en!r}")
            return 1
        if kind != "s":
            # 参数个数**和顺序**都要与格式串一致。
            # 少了 → 运行时会读到垃圾（或崩溃）；多了 → 多传的参数被静默丢弃；
            # 顺序错了 → `String(format:)` 把字符串当整数读。这三种类型系统都拦不住
            # （`String(format:)` 收的是变参），只能在这里查。
            want = KIND_PARAMS[kind]
            for lang, fmt in (("en", en), ("zh-Hans", zh)):
                got = spec_kinds(fmt)
                if got != want:
                    print(f"✗ {key} 声明为 {kind}（参数顺序 {want or '无参数'}），"
                          f"但 {lang} 的格式串里是 {got or '无格式符'}：{fmt!r}")
                    return 1

    if "--check" in sys.argv:
        # 中文里没有汉字的多半是品牌名 / 纯符号（"EyeGuard"、"20-20-20"），属正常。
        # 只列出来给人扫一眼，不作失败 —— 硬判失败会制造假警报，
        # 而**假警报会训练人忽略真警报**。
        ascii_zh = [k for k, _, _, zh in TABLE if not HAN.search(zh)]
        if ascii_zh:
            print(f"· {len(ascii_zh)} 条中文不含汉字（品牌名/纯符号，正常）：{ascii_zh}")
        print(f"✓ {len(TABLE)} 条，键唯一，两语言齐备，格式符一致，英文无汉字")
        return 0

    # --- 导出 JSON（人工核对用） ---
    data = {k: {"type": t, "en": en, "zh-Hans": zh} for k, t, en, zh in TABLE}
    with open(JSON_OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    # --- 生成 Swift ---
    decls, en_args, zh_args = [], [], []
    for key, kind, en, zh in TABLE:
        if kind == "s":
            decls.append(f"    let {key}: String")
            en_args.append(f"        {key}: {swift_literal(en)},")
            zh_args.append(f"        {key}: {swift_literal(zh)},")
        else:
            ctype, params = CLOSURE_TYPE[kind]
            decls.append(f"    let {key}: {ctype}")
            en_args.append(f'        {key}: {{ String(format: {swift_literal(en)}, '
                           + ", ".join(params) + ") },")
            zh_args.append(f'        {key}: {{ String(format: {swift_literal(zh)}, '
                           + ", ".join(params) + ") },")

    body = f'''// ⚠️ 本文件由 `Tools/i18n/gen_strings.py` 从 `Tools/i18n/strings.json` 生成。
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
enum Language: String, Codable, CaseIterable, Identifiable, Hashable {{
    case en
    case zhHans = "zh-Hans"

    var id: String {{ rawValue }}

    /// 缺省语言。刻意**不跟随 macOS 系统语言** —— FR-10.1 明确要求默认英文。
    static let fallback: Language = .en

    /// 语言自称。
    ///
    /// 这一项**刻意不翻译**：用户误切到看不懂的语言时，选择列表里
    /// 必须至少有一项是他能认出来的。这也是 macOS 自己的做法。
    var endonym: String {{
        switch self {{
        case .en:     return "English"
        case .zhHans: return "简体中文"
        }}
    }}

    var strings: Strings {{
        switch self {{
        case .en:     return .english
        case .zhHans: return .simplifiedChinese
        }}
    }}
}}

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
struct Strings {{
{chr(10).join(decls)}
}}

extension Strings {{
    static let english = Strings(
{chr(10).join(en_args)}
    )

    static let simplifiedChinese = Strings(
{chr(10).join(zh_args)}
    )
}}
'''

    os.makedirs(os.path.dirname(SWIFT_OUT), exist_ok=True)
    with open(SWIFT_OUT, "w", encoding="utf-8") as f:
        f.write(body)

    print(f"✓ 生成 {SWIFT_OUT}")
    print(f"✓ 导出 {JSON_OUT}")
    print(f"  {len(TABLE)} 条文案 × 2 语言")
    return 0


if __name__ == "__main__":
    sys.exit(main())
