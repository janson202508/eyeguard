import Foundation

// MARK: - 场景类别

/// 素材的语义分类。配额见规格书附录 A，合计 50 张。
///
/// `custom` 是给「我自己导入的图片」用的类别：配额 0，因此程序化占位素材
/// 一张都不会生成到它名下。它存在的理由是选片算法需要类别才能工作 ——
/// 分轮调度靠「每轮各类别各取一张」来保证相邻两次不雷同，用户导入的图片
/// 若没有类别，就会落进「无类别」这个既无法调度也无法均衡的状态。
enum SceneCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case custom, mountain, ocean, forest, lake, desert, snow, starfield, grassland, canyon, aerial

    var id: String { rawValue }

    /// 显示名。文案表由调用方传入，而不是在这里读「当前语言」——
    /// 全局可变语言会让「这个字符串到底是用哪种语言渲染的」变得不可推理，
    /// 而 `--shot-settings` 这类离屏工装恰恰需要能指定语言。
    func displayName(_ s: Strings) -> String {
        switch self {
        case .custom:    return s.catCustom
        case .mountain:  return s.catMountain
        case .ocean:     return s.catOcean
        case .forest:    return s.catForest
        case .lake:      return s.catLake
        case .desert:    return s.catDesert
        case .snow:      return s.catSnow
        case .starfield: return s.catStarfield
        case .grassland: return s.catGrassland
        case .canyon:    return s.catCanyon
        case .aerial:    return s.catAerial
        }
    }

    var quota: Int {
        switch self {
        case .custom:                                return 0
        case .mountain, .ocean, .aerial:             return 6
        case .forest, .lake, .starfield, .grassland: return 5
        case .desert, .snow, .canyon:                return 4
        }
    }

    /// 该类别的默认色调倾向，用于占位素材生成与夜间筛选
    var defaultTone: Tone {
        switch self {
        case .custom:                                     return .neutral
        case .starfield, .snow, .ocean, .lake, .mountain: return .cool
        case .desert, .canyon:                            return .warm
        case .forest, .grassland, .aerial:                return .neutral
        }
    }

    /// 是否是「我自己导入的图片」这一类别
    var isCustom: Bool { self == .custom }
}

enum Tone: String, Codable, CaseIterable, Hashable {
    case cool, warm, neutral

    func displayName(_ s: Strings) -> String {
        switch self {
        case .cool:    return s.toneCool
        case .warm:    return s.toneWarm
        case .neutral: return s.toneNeutral
        }
    }
}

enum AssetSource: String, Codable, CaseIterable, Hashable {
    case imported, bundled, downloaded, placeholder

    func displayName(_ s: Strings) -> String {
        switch self {
        case .imported:    return s.sourceImported
        case .bundled:     return s.sourceBundled
        case .downloaded:  return s.sourceDownloaded
        case .placeholder: return s.sourcePlaceholder
        }
    }

    /// 是否是「用户自己导入的图片」。
    /// 这类素材按**张**启用/禁用，而内置场景按**类别**启用/禁用 ——
    /// 两套粒度的理由见 `AppConfig.isAssetEnabled`。
    var isUserImport: Bool { self == .imported }
}

// MARK: - 素材

struct SceneAsset: Codable, Identifiable, Hashable {
    let id: String
    /// 本地文件名。为 nil 时使用程序化渲染（占位素材）
    let fileName: String?
    /// 可变：用户导入图片后可以在设置里改它归属的类别
    var category: SceneCategory
    let source: AssetSource
    let sourceURL: URL?
    let photographer: String?
    let license: String
    let width: Int
    let height: Int
    let byteSize: Int
    /// 纵深评分 1–5。引导式定位下这是核心指标，见规格书附录 A
    let depthScore: Double
    let tone: Tone
    /// 用户导入时的原始文件名，仅用于界面展示。
    /// 落盘文件名是内容哈希（`user-<hash>.jpg`），拿它当标题没法看。
    var originalName: String?
    /// 图片介绍（FR-11）：这张图拍的是哪儿、或者是什么场景。
    ///
    /// 双语**具名字段**而不是字典：字典少一个键只在运行时变成空串，
    /// 具名字段少一个就编译不过。用户导入的图片没有介绍，为 nil，
    /// 界面据此整行不显示。
    var captionEn: String?
    var captionZh: String?
    /// 这条介绍的依据（取自 Commons 的哪个字段 / 是否 GPS 反查 / 是否类别锚点）。
    /// **只写不读** —— 它是「介绍不得编造」这条红线的审计线索，
    /// 落盘数据不本地化（FR-10.8）。
    var captionSource: String?
    /// 拍摄年份。取自 Commons 的 `DateTimeOriginal`（四种形态，解析出 4 位年份）。
    /// 解析不出就是 nil —— 不猜。
    var shotYear: Int?
    /// 小字介绍（FR-11.9）：主行是**名称**，这一行是**可核查组件重组**的一句
    /// （`类别 · 年月`）。地区不进来 —— 它在主行上。理由见 `build_captions.py`
    /// 的 `make_blurb`。用户导入的图片没有这个，为 nil，整行不显示。
    var blurbEn: String?
    var blurbZh: String?
    /// 小字介绍用了哪些组件（`类别` / `时间`）。只写不读，同 `captionSource`。
    var blurbSource: String?
    var shownCount: Int
    var lastShownAt: Date?

    init(id: String,
         fileName: String? = nil,
         category: SceneCategory,
         source: AssetSource,
         sourceURL: URL? = nil,
         photographer: String? = nil,
         license: String = "—",
         width: Int = 2560,
         height: Int = 1440,
         byteSize: Int = 0,
         depthScore: Double,
         tone: Tone,
         originalName: String? = nil,
         captionEn: String? = nil,
         captionZh: String? = nil,
         captionSource: String? = nil,
         shotYear: Int? = nil,
         blurbEn: String? = nil,
         blurbZh: String? = nil,
         blurbSource: String? = nil,
         shownCount: Int = 0,
         lastShownAt: Date? = nil) {
        self.id = id
        self.fileName = fileName
        self.category = category
        self.source = source
        self.sourceURL = sourceURL
        self.photographer = photographer
        self.license = license
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.depthScore = depthScore
        self.tone = tone
        self.originalName = originalName
        self.captionEn = captionEn
        self.captionZh = captionZh
        self.captionSource = captionSource
        self.shotYear = shotYear
        self.blurbEn = blurbEn
        self.blurbZh = blurbZh
        self.blurbSource = blurbSource
        self.shownCount = shownCount
        self.lastShownAt = lastShownAt
    }

    /// 界面上显示的名字。
    ///
    /// 用户导入的图用**原始文件名**（落盘名是内容哈希 `user-<hash>.jpg`，没法看）；
    /// 预置素材没有 `originalName`，退回落盘文件名；都没有才退回类别名。
    func displayName(_ s: Strings) -> String {
        originalName ?? fileName ?? category.displayName(s)
    }

    /// 图片介绍。新增语言时**必须**在这里显式加分支 —— 否则会静默退回英文
    /// 而不是崩掉，那正是本项目最想消灭的失败模式。
    func caption(_ language: Language) -> String? {
        switch language {
        case .en:     return captionEn
        case .zhHans: return captionZh
        }
    }

    /// 小字介绍（FR-11.9）。同 `caption(_:)`：**新增语言必须显式加分支**。
    ///
    /// 空串按「没有」处理 —— 生成器写回时会把空值删键，但手改 manifest 或
    /// 将来换生成器都可能留下空串，而空串会让界面多渲染一行空白。
    func blurb(_ language: Language) -> String? {
        let raw: String?
        switch language {
        case .en:     raw = blurbEn
        case .zhHans: raw = blurbZh
        }
        guard let text = raw, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return text
    }

    /// 介绍下方的出处行：`作者 · 年份`。两者都没有则为 nil。
    ///
    /// 作者与年份都来自图源元数据，是可核查的；用户导入的图片两者都没有，
    /// 这一行自然不显示。
    func credit(_ s: Strings) -> String? {
        switch (photographer, shotYear) {
        case let (name?, year?): return s.captionCredit(name, year)
        case let (name?, nil):   return name
        case let (nil, year?):   return String(year)
        case (nil, nil):         return nil
        }
    }
}

extension Strings {
    /// **开发者输出**（`--self-test`、`--shot-*` 打出来的日志）固定用这一份。
    ///
    /// 刻意不跟随用户的界面语言设置 —— 自检结果是拿来做判断依据的，
    /// 同一台机器跑两次得到两种语言的输出，既没法 grep 也没法逐行比对。
    /// 界面文案一律用 `config.strings`，只有开发者路径才用这里。
    static let developer = Strings.english
}

// MARK: - 状态机

/// 规格书 §3.1 的七个状态
enum Phase: String, Codable, CaseIterable {
    case working, prewarning, resting, snoozed, suppressed, paused, sleeping

    func displayName(_ s: Strings) -> String {
        switch self {
        case .working:    return s.phaseWorking
        case .prewarning: return s.phasePrewarning
        case .resting:    return s.phaseResting
        case .snoozed:    return s.phaseSnoozed
        case .suppressed: return s.phaseSuppressed
        case .paused:     return s.phasePaused
        case .sleeping:   return s.phaseSleeping
        }
    }
}

enum DisplayTarget: String, Codable, CaseIterable, Identifiable {
    case mouseScreen, mainScreen, allScreens

    var id: String { rawValue }

    func displayName(_ s: Strings) -> String {
        switch self {
        case .mouseScreen: return s.targetMouseScreen
        case .mainScreen:  return s.targetMainScreen
        case .allScreens:  return s.targetAllScreens
        }
    }
}

// MARK: - 配置

struct AppConfig: Codable, Equatable {
    /// 界面语言（FR-10）。默认英文，可在设置里修改。
    ///
    /// 图片介绍与界面**共用这一项**（FR-10.3）—— 不设两个开关。
    /// 理由很实际：文案和界面混用两种语言时，读者要在同一句话里切换语种，
    /// 而且没有任何一种组合是用户真正想要的。
    var language: Language = .fallback

    var workIntervalMinutes: Int = 20
    var restDurationSeconds: Int = 20
    var prewarningSeconds: Int = 10
    var skipUnlockSeconds: Int = 3
    var idleThresholdMinutes: Int = 5
    var wakeCooldownSeconds: Int = 60
    var snoozeMinutes: Int = 5
    var skipStreakThreshold: Int = 3

    var displayTarget: DisplayTarget = .mouseScreen

    var suppressOnIdle: Bool = true
    var suppressOnFullscreen: Bool = true
    var suppressOnCamera: Bool = true

    var nightDimmingEnabled: Bool = true
    var nightStartHour: Int = 22
    var nightEndHour: Int = 7

    var soundEnabled: Bool = false
    var launchAtLogin: Bool = false

    // MARK: - 素材启用状态
    //
    // 内置场景按**类别**禁用，用户导入的图片按**张**禁用。两套粒度不是随意选的：
    //   · 内置场景有 50 张占位素材，逐张勾选是折磨；而类别正是选片算法用来
    //     保证「相邻两次不雷同」的单位，按类别关掉语义上更准确。
    //   · 用户导入的图片数量少、彼此差异大，且「这张我不喜欢」是很自然的诉求，
    //     必须能精确到单张。

    /// 是否让内置场景（程序化占位 / 预置）参与轮播。
    /// 导入真实图片后通常应该关掉，否则占位色块会和真照片混在一起。
    var useBuiltInScenes: Bool = true

    /// 被禁用的内置场景类别（`SceneCategory.rawValue`）
    var disabledSceneCategories: [String] = []

    /// 被禁用的导入图片（`SceneAsset.id`）
    var disabledAssetIDs: [String] = []

    /// 该素材当前是否参与轮播。
    ///
    /// 单一判定入口 —— 选片、设置页统计、自检都调它，避免三处各写一份
    /// 略有出入的过滤条件（那种不一致最终会表现成「设置里显示 8 张，
    /// 实际只轮播 7 张」）。
    func isAssetEnabled(_ asset: SceneAsset) -> Bool {
        if asset.source.isUserImport {
            return !disabledAssetIDs.contains(asset.id)
        }
        return useBuiltInScenes && !disabledSceneCategories.contains(asset.category.rawValue)
    }

    mutating func setCategory(_ category: SceneCategory, enabled: Bool) {
        var list = Set(disabledSceneCategories)
        if enabled { list.remove(category.rawValue) } else { list.insert(category.rawValue) }
        disabledSceneCategories = list.sorted()
    }

    mutating func setAsset(_ id: String, enabled: Bool) {
        var list = Set(disabledAssetIDs)
        if enabled { list.remove(id) } else { list.insert(id) }
        disabledAssetIDs = list.sorted()
    }

    /// 用户选择「不再提示间隔调整建议」后置为 true
    var skipStreakHintDisabled: Bool = false

    /// 开发者测试模式：解锁 1/2/5 分钟的间隔与 5/10 秒的休息时长。
    /// 存在的理由很实际 —— 常规最小间隔是 15 分钟，验证「自动触发」这条
    /// 核心路径每轮都要等 15 分钟，迭代成本高到没人愿意测。
    var testModeEnabled: Bool = false

    static let intervalOptions = [15, 20, 30, 45]
    static let durationOptions = [20, 40, 60]
    static let prewarningOptions = [5, 10, 15, 20]
    static let skipUnlockOptions = [0, 3, 5, 10]
    static let idleThresholdOptions = [3, 5, 10, 15]
    static let snoozeOptions = [3, 5, 10, 15]

    // 测试模式专属：把几个「最短也有好几分钟」的档位解锁到 1 分钟级，
    // 否则 5 分钟空闲判定和 3 分钟延后会把快速循环测试整个卡住。
    static let testIntervalOptions = [1, 2, 5]
    static let testDurationOptions = [5, 10]
    static let testIdleThresholdOptions = [1, 2]
    static let testSnoozeOptions = [1]

    /// 生效的唤醒冷却时间。测试模式下缩短，否则 60 秒冷却会挡住短间隔的验证。
    var effectiveWakeCooldownSeconds: Int {
        testModeEnabled ? 5 : wakeCooldownSeconds
    }

    /// 当前可选的间隔。测试模式下把短间隔排在前面。
    var availableIntervalOptions: [Int] {
        testModeEnabled ? AppConfig.testIntervalOptions + AppConfig.intervalOptions
                        : AppConfig.intervalOptions
    }

    var availableDurationOptions: [Int] {
        testModeEnabled ? AppConfig.testDurationOptions + AppConfig.durationOptions
                        : AppConfig.durationOptions
    }

    var availableIdleThresholdOptions: [Int] {
        testModeEnabled ? AppConfig.testIdleThresholdOptions + AppConfig.idleThresholdOptions
                        : AppConfig.idleThresholdOptions
    }

    var availableSnoozeOptions: [Int] {
        testModeEnabled ? AppConfig.testSnoozeOptions + AppConfig.snoozeOptions
                        : AppConfig.snoozeOptions
    }

    /// 关闭测试模式后，把仍停在测试档位（如 1 分钟）的值收敛回常规档位。
    /// 不做这一步，Picker 的 selection 会落在一个不在选项里的值上，显示为空白。
    /// 必须在 testModeEnabled 置为 false **之后**调用，因为依赖 available* 的计算结果。
    mutating func clampToAvailableOptions() {
        if !availableIntervalOptions.contains(workIntervalMinutes) { workIntervalMinutes = 20 }
        if !availableDurationOptions.contains(restDurationSeconds) { restDurationSeconds = 20 }
        if !availableIdleThresholdOptions.contains(idleThresholdMinutes) { idleThresholdMinutes = 5 }
        if !availableSnoozeOptions.contains(snoozeMinutes) { snoozeMinutes = 5 }
    }

    init() {}

    /// 当前语言对应的文案表。
    ///
    /// 界面上取文案一律走这里，不要在视图里写 `Strings.english` 之类的字面量 ——
    /// 那样语言设置就成了摆设（而且这种漏改没有编译错误，只有肉眼能发现）。
    var strings: Strings { language.strings }

    /// 容错解码：任何一个字段缺失或类型不符都退回默认值，不整体失败。
    /// 这样后续新增配置项时，旧配置文件仍可正常读取。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }

        language              = value(.language,              defaults.language)
        workIntervalMinutes   = value(.workIntervalMinutes,   defaults.workIntervalMinutes)
        restDurationSeconds   = value(.restDurationSeconds,   defaults.restDurationSeconds)
        prewarningSeconds     = value(.prewarningSeconds,     defaults.prewarningSeconds)
        skipUnlockSeconds     = value(.skipUnlockSeconds,     defaults.skipUnlockSeconds)
        idleThresholdMinutes  = value(.idleThresholdMinutes,  defaults.idleThresholdMinutes)
        wakeCooldownSeconds   = value(.wakeCooldownSeconds,   defaults.wakeCooldownSeconds)
        snoozeMinutes         = value(.snoozeMinutes,         defaults.snoozeMinutes)
        skipStreakThreshold   = value(.skipStreakThreshold,   defaults.skipStreakThreshold)
        displayTarget         = value(.displayTarget,         defaults.displayTarget)
        suppressOnIdle        = value(.suppressOnIdle,        defaults.suppressOnIdle)
        suppressOnFullscreen  = value(.suppressOnFullscreen,  defaults.suppressOnFullscreen)
        suppressOnCamera      = value(.suppressOnCamera,      defaults.suppressOnCamera)
        nightDimmingEnabled   = value(.nightDimmingEnabled,   defaults.nightDimmingEnabled)
        nightStartHour        = value(.nightStartHour,        defaults.nightStartHour)
        nightEndHour          = value(.nightEndHour,          defaults.nightEndHour)
        soundEnabled          = value(.soundEnabled,          defaults.soundEnabled)
        launchAtLogin         = value(.launchAtLogin,         defaults.launchAtLogin)
        skipStreakHintDisabled = value(.skipStreakHintDisabled, defaults.skipStreakHintDisabled)
        testModeEnabled       = value(.testModeEnabled,       defaults.testModeEnabled)
        useBuiltInScenes      = value(.useBuiltInScenes,      defaults.useBuiltInScenes)
        disabledSceneCategories = value(.disabledSceneCategories, defaults.disabledSceneCategories)
        disabledAssetIDs      = value(.disabledAssetIDs,      defaults.disabledAssetIDs)
    }

    /// 当前是否处于夜间时段
    func isNight(at date: Date = Date()) -> Bool {
        guard nightDimmingEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: date)
        let start = nightStartHour
        let end = nightEndHour
        if start == end { return false }
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

// MARK: - 去重状态

/// 洗牌袋。规格书 §4 选片算法的全部状态都放在这里，可完整持久化。
struct ShuffleBagState: Codable, Equatable {
    /// SceneCategory.rawValue -> 该类别剩余未展示的素材 id（取出即不放回）
    var remainingByCategory: [String: [String]] = [:]
    /// 当前这一轮的类别顺序。每轮里每个类别各取一张，取完再开新一轮
    var roundOrder: [String] = []
    /// 最近展示过的场景类别（保留最近 6 次），用于「相邻两次不重复类别」
    var recentCategories: [String] = []
    /// 最近展示过的素材 id（保留最近 20 个），用于跨轮撞车规避
    var recentAssetIDs: [String] = []
}

/// 运行时可持久化状态，支持崩溃/重启后恢复剩余计时（FR-1.7）
struct RuntimeState: Codable {
    var phase: Phase = .working
    var remainingSeconds: Int = 0
    /// 保存这份剩余计时时所使用的提醒间隔（分钟）。
    ///
    /// 剩余秒数只有配上「当时的间隔」才有意义。早期版本没存这个字段，
    /// 于是用测试模式的 1 分钟间隔跑完一轮后再正常启动，会把 34 秒这种
    /// 剩余时间还原到 20 分钟间隔下 —— 用户会莫名其妙地在启动半分钟后就
    /// 被提醒一次。间隔对不上时宁可重新完整计时。
    var intervalMinutes: Int = 20
    var skipStreak: Int = 0
    var lastRestEndedAt: Date?
    var bag: ShuffleBagState = ShuffleBagState()
    var savedAt: Date = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RuntimeState()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        phase            = value(.phase, defaults.phase)
        remainingSeconds = value(.remainingSeconds, defaults.remainingSeconds)
        intervalMinutes  = value(.intervalMinutes, defaults.intervalMinutes)
        skipStreak       = value(.skipStreak, defaults.skipStreak)
        lastRestEndedAt  = (try? container.decode(Date.self, forKey: .lastRestEndedAt))
        bag              = value(.bag, defaults.bag)
        savedAt          = value(.savedAt, defaults.savedAt)
    }
}

// MARK: - 顺延原因

enum SuppressionReason: String, CaseIterable, Identifiable, Hashable {
    case idle, fullscreen, camera, manual, sleeping

    var id: String { rawValue }

    func displayName(_ s: Strings) -> String {
        switch self {
        case .idle:       return s.reasonIdle
        case .fullscreen: return s.reasonFullscreen
        case .camera:     return s.reasonCamera
        case .manual:     return s.reasonManual
        case .sleeping:   return s.reasonSleeping
        }
    }
}
