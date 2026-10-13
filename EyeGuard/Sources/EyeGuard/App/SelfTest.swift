import Foundation

/// 自检。覆盖《需求规格书 v1》§9 验收标准中可自动化的部分。
///
/// 用法：EyeGuard --self-test
///
/// 之所以把它做进主程序而不是独立的测试 target：SPM 不允许两个 target
/// 共享同一批源文件，而本机只装了 Command Line Tools，引入 XCTest 还要
/// 额外配置。一个隐藏的命令行开关能以最低成本换来可重复的验收。
enum SelfTest {

    /// AC-4 / AC-5 / AC-6 的取片统计。
    ///
    /// 抽成独立类型 + 函数，是为了让「真实素材库」与「反向对照用的退化素材库」
    /// 走**同一段**统计逻辑。两条路径各写一份的话，规则会漂移，而漂移的那一份
    /// 在静默漏判时是看不见的。
    private struct PickStatistics {
        var rounds = 0
        var totalPicks = 0
        var totalRepeats = 0
        var totalAdjacentSame = 0
        /// 「取片时仍有多个类别可选」却依然同类的次数 —— 这才是真正的违约。
        /// 规格书 §4 步骤 2 明确写着：**仅剩 1 个类别时放宽**该约束并记日志。
        var forcedAdjacentSame = 0
        /// 取片时仍有多个类别可选的次数。对照量，用来防止上面的判据假通过。
        var multiOptionPicks = 0
        var worstDeviation = 0
        /// 单类别尾段的轮数上界 = 最大类别规模 − 次大类别规模。
        var tailBound = 0
        var largestCategory = 0
        var smallestCategory = 0
        var runnerUpCategory = 0

        /// 多类别可选取片占比的下限。
        ///
        /// 真实素材库（627 张 / 10 类）实测 98.3%，因为单类别尾段只占 9/627。
        /// 取 0.75 是留足余量；退化到单类别池时该值为 0，必须被判失败。
        static let multiOptionFloor = 0.75

        var multiOptionRatio: Double {
            Double(multiOptionPicks) / Double(max(totalPicks, 1))
        }

        var sizeSpread: Int { largestCategory - smallestCategory }

        var spreadNote: String {
            "最大类别 \(largestCategory) 张 − 最小类别 \(smallestCategory) 张"
        }

        /// AC-5 的全部判据。三条缺一不可 —— 后两条的作用是防止第一条假通过。
        var ac5Satisfied: Bool {
            forcedAdjacentSame == 0
                && totalAdjacentSame <= rounds * tailBound
                && multiOptionRatio >= PickStatistics.multiOptionFloor
        }
    }

    /// 对给定素材库跑 `rounds` 轮完整取片，统计 AC-4 / AC-5 / AC-6。
    private static func measurePicks(pool: [SceneAsset], rounds: Int) -> PickStatistics {
        var stats = PickStatistics()
        stats.rounds = rounds
        stats.totalPicks = rounds * pool.count

        // 分布均衡只对「素材库里真的有的类别」有意义。
        // 遍历 SceneCategory.allCases 会把 custom（配额 0，永远 0 张）也算进来，
        // 于是偏差恒等于最大配额 —— 那是统计口径错误，不是算法问题。
        let categoriesInPool = Set(pool.map(\.category))

        // AC-6 的判据：偏差不超过「最大类别规模 − 最小类别规模」。
        //
        // 这正是分轮调度的**可证明上界** —— 每轮每类各取一张，某类取满即退出，
        // 所以一个完整循环里每类的取片次数恰好等于它自己的素材数，
        // 任意两类之差的上界就是规模差。
        //
        // ⚠️ 老版本把阈值硬编码成 2。那只在「各类配额 4–6 张」时成立；
        // 素材库扩容后各类规模差必然变大（250 张时可达 10 以上），
        // 硬编码 2 会变成**假警报** —— 而假警报会训练人忽略真警报。
        // 判据必须从素材库的实际构成算出来，不能写死。
        let poolSizes = categoriesInPool.map { category in
            pool.filter { $0.category == category }.count
        }.sorted(by: >)

        stats.largestCategory = poolSizes.first ?? 0
        stats.smallestCategory = poolSizes.last ?? 0
        stats.runnerUpCategory = poolSizes.count > 1 ? poolSizes[1] : 0

        // 尾段被迫同类的上界：单类别尾段的轮数 = 最大类别规模 − 次大类别规模。
        //
        // 分轮调度是「每轮每类各取一张」，所以只要各类规模不等，最大的那一类
        // 必然剩下「最大 − 次大」轮只能独自出片。这个数**从素材库构成算出来**，
        // 不写死 —— 写死会在下次扩容时变成假警报。
        stats.tailBound = max(0, stats.largestCategory - stats.runnerUpCategory)

        for _ in 0..<rounds {
            var bag = ShuffleBagState()
            var picks: [SceneAsset] = []
            // 每次取片前「仍有余量的类别数」，用来区分「被迫同类」与「算法违约」
            var availableBefore: [Int] = []
            for _ in 0..<pool.count {
                let remainingCategories = bag.remainingByCategory.values
                    .filter { !$0.isEmpty }.count
                if let asset = AssetPicker.pick(pool: pool, bag: &bag, isNight: false) {
                    picks.append(asset)
                    availableBefore.append(remainingCategories)
                }
            }

            stats.totalRepeats += picks.count - Set(picks.map(\.id)).count

            for index in 1..<picks.count where picks[index].category == picks[index - 1].category {
                stats.totalAdjacentSame += 1
                if index < availableBefore.count, availableBefore[index] > 1 {
                    stats.forcedAdjacentSame += 1
                }
            }

            // 对照量：有多少次取片是「仍有多个类别可选」的。
            // 如果这个数很小，说明分类没分对 —— 「0 次违约」就成了假通过。
            stats.multiOptionPicks += availableBefore.filter { $0 > 1 }.count

            let counts = categoriesInPool.map { category in
                picks.filter { $0.category == category }.count
            }
            stats.worstDeviation = max(stats.worstDeviation, (counts.max() ?? 0) - (counts.min() ?? 0))
        }

        return stats
    }

    static func run() -> Int32 {
        var failures: [String] = []

        print("EyeGuard 自检 —— 对照《需求规格书 v1》§9 验收标准")
        print(String(repeating: "=", count: 46))

        // 用 App 实际会加载的那一套素材来测。如果这里用程序化占位素材、
        // 而 App 加载的是 bundle 里的真实照片，自检通过就等于没测。
        let pool = SceneLibrary.builtInPool()
        let source = pool.first?.source ?? .placeholder
        print("素材库：\(pool.count) 张（来源：\(source.displayName(.developer))）")

        // 附录 A 类别配额。
        //
        // ⚠️ 2026-10-11 判据从 `== quota` 改成 `>= quota`。
        //
        // 附录 A 的 50 张配额看起来是「总数上限」，但它的真实作用只有一个：
        // **保证 10 个类别都有素材、没有哪一类被饿死** —— 分轮调度要求每轮
        // 每个类别都能取到一张，某类为空就会让「相邻两次类别不同」这条约束
        // 在尾段失效。
        //
        // 素材库扩容到 250+ 张之后，`== quota` 必然失败。那是**判据过时**，
        // 不是素材库有问题：配额的真实语义一直是「下限」。因此降级为「不得低于」，
        // 并把不达标的类别逐个打出来（只报一个 bool 没法定位是哪一类）。
        let quotaShortfalls = SceneCategory.allCases.filter { category in
            pool.filter { $0.category == category }.count < category.quota
        }
        let quotaOK = quotaShortfalls.isEmpty
        print("  各类别不低于附录 A 配额：\(quotaOK ? "是" : "否")")
        if !quotaOK {
            for category in quotaShortfalls {
                let actual = pool.filter { $0.category == category }.count
                print("    ! \(category.displayName(.developer))：实际 \(actual) 张，配额 \(category.quota) 张")
            }
            failures.append("附录 A 类别配额不符")
        }

        // FR-4.6：预置库中 depthScore >= 4 的占比应 >= 70%
        let deepCount = pool.filter { $0.depthScore >= 4 }.count
        let deepRatio = Double(deepCount) / Double(max(pool.count, 1))
        print(String(format: "  depthScore >= 4 占比：%.1f%%（要求 >= 70%%）", deepRatio * 100))
        if deepRatio < 0.70 { failures.append("FR-4.6 depthScore >= 4 占比不足") }

        // AC-4 / AC-5 / AC-6
        let rounds = 200
        let stats = measurePicks(pool: pool, rounds: rounds)

        print("")
        print("连续 \(rounds) 轮 × \(pool.count) 次取片（共 \(stats.totalPicks) 次）：")
        print("  AC-4 素材重复总数：\(stats.totalRepeats)（要求 0）")
        print("  AC-5 相邻同类别次数：\(stats.totalAdjacentSame)"
              + "（其中 \(stats.forcedAdjacentSame) 次发生在仍有多个类别可选时，要求 0）")
        print("       尾段被迫同类上界：\(stats.tailBound) 次/轮"
              + "（= 最大类别 \(stats.largestCategory) − 次大类别 \(stats.runnerUpCategory)）")

        // 对照量：必须证明「仍有多个类别可选」是一种**常态**，否则上面那个 0 毫无意义。
        //
        // 反例：素材库只剩一个类别时 remainingCategories 恒为 1，
        // forcedAdjacentSame 恒为 0；而 tailBound = 最大 − 次大 = n − 0 = n，
        // 上界断言也恒成立 —— 整套 AC-5 会静默退化成「永远通过」。
        // 一个永远通过的检查等于没有检查，所以给它配一条**下限**。
        print("  AC-5 对照量：\(stats.multiOptionPicks)/\(stats.totalPicks) 次取片时仍有多个类别可选"
              + String(format: "（%.1f%%，单类别可选 %d 次）",
                       stats.multiOptionRatio * 100, stats.totalPicks - stats.multiOptionPicks))
        print("  AC-6 类别分布最大偏差：\(stats.worstDeviation)"
              + "（要求 <= \(stats.sizeSpread)，即 \(stats.spreadNote)）")

        if stats.totalRepeats != 0 { failures.append("AC-4 出现素材重复") }
        if stats.forcedAdjacentSame != 0 {
            failures.append("AC-5 仍有多个类别可选时出现相邻同类别")
        }
        if stats.totalAdjacentSame > rounds * stats.tailBound {
            failures.append("AC-5 相邻同类别超出尾段上界")
        }
        if stats.multiOptionRatio < PickStatistics.multiOptionFloor {
            failures.append("AC-5 对照量异常：多类别可选取片仅占"
                            + String(format: "%.1f%%", stats.multiOptionRatio * 100)
                            + "，相邻同类判据可能因分类失效而假通过")
        }
        if stats.worstDeviation > stats.sizeSpread { failures.append("AC-6 类别分布偏差超限") }

        // 反向对照：把同一套判据套到一个**已知会失效**的素材库上，确认它真的判失败。
        //
        // 退化池只保留规模最大的那一个类别。此时 AC-5 的「违约次数」与「尾段上界」
        // 两条都会自动成立（理由见上面的注释），唯一可能的拦截点就是多类别可选取片
        // 占比 —— 如果连它也不报错，说明这条下限是空的，等于没有检查。
        let countsByCategory = Dictionary(grouping: pool, by: \.category).mapValues(\.count)
        if let biggest = countsByCategory.max(by: { $0.value < $1.value })?.key {
            let degenerate = measurePicks(pool: pool.filter { $0.category == biggest }, rounds: 5)
            let tripped = !degenerate.ac5Satisfied
            print("  AC-5 反向对照（仅 \(biggest.displayName(.developer)) \(degenerate.totalPicks) 次取片）："
                  + (tripped
                     ? "通过（判据正确判失败，多类别可选占比 "
                       + String(format: "%.0f%%", degenerate.multiOptionRatio * 100) + "）"
                     : "失败（判据在退化素材库上仍判通过，等于没有检查）"))
            if !tripped { failures.append("AC-5 反向对照未触发") }
        }

        // 夜间筛选：不应出现暖调与雪景（FR-4.7）
        var nightViolations = 0
        var nightBag = ShuffleBagState()
        for _ in 0..<(pool.count * 2) {
            if let asset = AssetPicker.pick(pool: pool, bag: &nightBag, isNight: true) {
                if asset.tone == .warm || asset.category == .snow { nightViolations += 1 }
            }
        }
        print("  FR-4.7 夜间选中暖调/雪景次数：\(nightViolations)（要求 0）")
        if nightViolations != 0 { failures.append("FR-4.7 夜间筛选失效") }

        // AppConfig 容错解码：缺字段、含未知字段都不应崩溃
        print("")
        if let data = #"{"workIntervalMinutes": 30, "unknownKey": 1}"#.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            let ok = decoded.workIntervalMinutes == 30 && decoded.restDurationSeconds == 20
            print("AppConfig 缺字段容错：\(ok ? "通过（保留 30，其余取默认）" : "失败")")
            if !ok { failures.append("AppConfig 容错解码结果不正确") }
        } else {
            print("AppConfig 缺字段容错：失败（解码抛错）")
            failures.append("AppConfig 缺字段时解码失败")
        }

        if let data = "{}".data(using: .utf8),
           let decoded = try? JSONDecoder().decode(RuntimeState.self, from: data) {
            print("RuntimeState 空对象解码：通过（phase = \(decoded.phase.rawValue)）")
        } else {
            print("RuntimeState 空对象解码：失败")
            failures.append("RuntimeState 空对象解码失败")
        }

        // 测试模式：档位解锁与关闭时的值收敛
        print("")
        let normal = AppConfig()
        let normalOK = normal.availableIntervalOptions == AppConfig.intervalOptions
            && normal.availableDurationOptions == AppConfig.durationOptions
            && normal.effectiveWakeCooldownSeconds == 60
        print("测试模式关闭时保持常规档位：\(normalOK ? "通过" : "失败")")
        if !normalOK { failures.append("测试模式关闭时档位不正确") }

        var testing = AppConfig()
        testing.testModeEnabled = true
        let testOK = testing.availableIntervalOptions.first == 1
            && testing.availableDurationOptions.first == 5
            && testing.effectiveWakeCooldownSeconds == 5
        print("测试模式开启时解锁 1 分钟 / 5 秒 / 冷却 5 秒：\(testOK ? "通过" : "失败")")
        if !testOK { failures.append("测试模式档位未解锁") }

        // 关键回归：关掉测试模式后若仍停在 1 分钟，Picker 的 selection
        // 会落在一个不存在的选项上、界面显示空白。必须收敛回常规档位。
        // 这里先把四个值真的压到测试档位，否则测的是「默认值恰好合法」这种假通过。
        testing.workIntervalMinutes = 1
        testing.restDurationSeconds = 5
        testing.idleThresholdMinutes = 1
        testing.snoozeMinutes = 1
        testing.testModeEnabled = false
        testing.clampToAvailableOptions()
        let clampOK = testing.workIntervalMinutes == 20
            && testing.restDurationSeconds == 20
            && testing.idleThresholdMinutes == 5
            && testing.snoozeMinutes == 5
        print("关闭测试模式后收敛回常规档位：\(clampOK ? "通过" : "失败")"
              + "（间隔 \(testing.workIntervalMinutes) 分钟）")
        if !clampOK { failures.append("关闭测试模式后档位未收敛") }

        // testModeEnabled 必须参与持久化，否则重启就丢
        if let data = #"{"testModeEnabled": true}"#.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            print("testModeEnabled 可持久化：\(decoded.testModeEnabled ? "通过" : "失败")")
            if !decoded.testModeEnabled { failures.append("testModeEnabled 未参与解码") }
        } else {
            print("testModeEnabled 可持久化：失败（解码抛错）")
            failures.append("testModeEnabled 解码失败")
        }

        // FR-1.7 剩余计时还原。这组断言针对的是「偶尔早提醒一次」这类
        // 只在手工测试中极难复现的问题，所以必须自动化。
        print("")
        let now = Date()

        func savedState(phase: Phase = .working, remaining: Int, interval: Int, ageSeconds: TimeInterval) -> RuntimeState {
            var state = RuntimeState()
            state.phase = phase
            state.remainingSeconds = remaining
            state.intervalMinutes = interval
            state.savedAt = now.addingTimeInterval(-ageSeconds)
            return state
        }

        // 正常情形：间隔一致、刚关闭不久 → 接着上次的剩余时间走
        let carryOn = Scheduler.restoredRemaining(
            saved: savedState(remaining: 600, interval: 20, ageSeconds: 60),
            currentIntervalMinutes: 20, idleThresholdMinutes: 5, now: now)
        let carryOnOK = carryOn == 540
        print("FR-1.7 间隔一致时接着上次计时：\(carryOnOK ? "通过" : "失败")（剩余 \(Int(carryOn)) 秒，期望 540）")
        if !carryOnOK { failures.append("FR-1.7 剩余计时未正确延续") }

        // 间隔变过 → 必须重新完整计时，不能把 1 分钟间隔的剩余秒数
        // 搬到 20 分钟间隔下（否则会在启动半分钟后莫名提醒）
        let crossInterval = Scheduler.restoredRemaining(
            saved: savedState(remaining: 34, interval: 1, ageSeconds: 26),
            currentIntervalMinutes: 20, idleThresholdMinutes: 5, now: now)
        let crossOK = crossInterval == 1200
        print("FR-1.7 间隔变更后重新完整计时：\(crossOK ? "通过" : "失败")（剩余 \(Int(crossInterval)) 秒，期望 1200）")
        if !crossOK { failures.append("FR-1.7 跨间隔还原未重置") }

        // 关闭时长超过空闲阈值 → 视为已经休息过，重置
        let longAway = Scheduler.restoredRemaining(
            saved: savedState(remaining: 600, interval: 20, ageSeconds: 8 * 60),
            currentIntervalMinutes: 20, idleThresholdMinutes: 5, now: now)
        let longAwayOK = longAway == 1200
        print("FR-1.7 长时间关闭后重置计时：\(longAwayOK ? "通过" : "失败")（剩余 \(Int(longAway)) 秒，期望 1200）")
        if !longAwayOK { failures.append("FR-1.7 长时间关闭后未重置") }

        // 保存时正在休息 → 那次休息算数，重置
        let wasResting = Scheduler.restoredRemaining(
            saved: savedState(phase: .resting, remaining: 0, interval: 20, ageSeconds: 30),
            currentIntervalMinutes: 20, idleThresholdMinutes: 5, now: now)
        let wasRestingOK = wasResting == 1200
        print("FR-1.7 上次退出时正在休息则重置：\(wasRestingOK ? "通过" : "失败")（剩余 \(Int(wasResting)) 秒，期望 1200）")
        if !wasRestingOK { failures.append("FR-1.7 退出时正在休息未重置") }

        // 素材启用状态（「素材」标签页的全部逻辑都建立在这一个判定入口上）
        print("")
        let builtInSample = pool[0]                                  // 内置占位素材
        let importedSample = SceneAsset(
            id: "user-selftest",
            fileName: "user-selftest.jpg",
            category: .custom,
            source: .imported,
            depthScore: 4.0,
            tone: .neutral,
            originalName: "自检样本.jpg"
        )

        var enableConfig = AppConfig()
        let defaultEnabled = enableConfig.isAssetEnabled(builtInSample)
            && enableConfig.isAssetEnabled(importedSample)
        print("默认全部素材参与轮播：\(defaultEnabled ? "通过" : "失败")")
        if !defaultEnabled { failures.append("默认启用状态不正确") }

        // 关闭内置场景不应波及用户导入的图片 —— 这是「两者都要」的核心语义
        enableConfig.useBuiltInScenes = false
        let builtInOffOK = !enableConfig.isAssetEnabled(builtInSample)
            && enableConfig.isAssetEnabled(importedSample)
        print("关闭内置场景后仅剩我的图片：\(builtInOffOK ? "通过" : "失败")")
        if !builtInOffOK { failures.append("关闭内置场景波及了用户导入的图片") }

        // 内置按类别、导入按单张 —— 两套粒度不能互相串味
        enableConfig = AppConfig()
        enableConfig.setCategory(.ocean, enabled: false)
        let sameCategoryAsset = pool.first { $0.category == .ocean }
        let otherCategoryAsset = pool.first { $0.category == .mountain }
        let categoryOK = (sameCategoryAsset.map { !enableConfig.isAssetEnabled($0) } ?? false)
            && (otherCategoryAsset.map { enableConfig.isAssetEnabled($0) } ?? false)
            && enableConfig.isAssetEnabled(importedSample)
        print("按类别禁用只影响该类别：\(categoryOK ? "通过" : "失败")")
        if !categoryOK { failures.append("按类别禁用范围不正确") }

        enableConfig = AppConfig()
        enableConfig.setAsset(importedSample.id, enabled: false)
        let assetOK = !enableConfig.isAssetEnabled(importedSample)
            && enableConfig.isAssetEnabled(builtInSample)
        print("按单张禁用只影响该张：\(assetOK ? "通过" : "失败")")
        if !assetOK { failures.append("按单张禁用范围不正确") }

        // 恢复启用必须真的能恢复，且禁用列表不能留下重复项
        enableConfig.setAsset(importedSample.id, enabled: false)
        enableConfig.setCategory(.ocean, enabled: false)
        enableConfig.setAsset(importedSample.id, enabled: true)
        enableConfig.setCategory(.ocean, enabled: true)
        let restoreOK = enableConfig.disabledAssetIDs.isEmpty
            && enableConfig.disabledSceneCategories.isEmpty
            && enableConfig.isAssetEnabled(importedSample)
        print("重新启用后可回到初始状态：\(restoreOK ? "通过" : "失败")")
        if !restoreOK { failures.append("重新启用未清除禁用记录") }

        // 三个新字段必须参与持久化，否则重启就丢
        let enableJSON = #"{"useBuiltInScenes": false, "disabledSceneCategories": ["snow"], "disabledAssetIDs": ["user-a"]}"#
        if let data = enableJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            let persistOK = decoded.useBuiltInScenes == false
                && decoded.disabledSceneCategories == ["snow"]
                && decoded.disabledAssetIDs == ["user-a"]
            print("素材启用状态可持久化：\(persistOK ? "通过" : "失败")")
            if !persistOK { failures.append("素材启用状态未参与解码") }
        } else {
            print("素材启用状态可持久化：失败（解码抛错）")
            failures.append("素材启用状态解码失败")
        }

        // 空素材库：用户禁用了全部素材（或删光导入的图又关了内置场景）。
        // 选片必须安静地返回 nil，让休息画面退化成纯色背景 —— 而不是崩溃。
        print("")
        var emptyBag = ShuffleBagState()
        let emptyPick = AssetPicker.pick(pool: [], bag: &emptyBag, isNight: false)
        print("空素材库选片返回 nil：\(emptyPick == nil ? "通过" : "失败")")
        if emptyPick != nil { failures.append("空素材库选片未返回 nil") }

        let nightEmptyPick = AssetPicker.pick(pool: [], bag: &emptyBag, isNight: true)
        print("空素材库夜间选片返回 nil：\(nightEmptyPick == nil ? "通过" : "失败")")
        if nightEmptyPick != nil { failures.append("空素材库夜间选片未返回 nil") }

        // 只剩一个类别时的约束退化。这是「用户把内置场景全关掉、只留一个类别」
        // 的真实情形 —— 此时「相邻两次类别不同」在数学上不可能满足，
        // 算法必须优雅退化到「不重复」这一条，而不是返回 nil 或死循环。
        var singlePool: [SceneAsset] = []
        for index in 0..<3 {
            singlePool.append(SceneAsset(
                id: "single-\(index)",
                category: .custom,
                source: .imported,
                depthScore: 4.5,
                tone: .neutral
            ))
        }
        var singleBag = ShuffleBagState()
        var singlePicks: [String] = []
        for _ in 0..<12 {
            if let asset = AssetPicker.pick(pool: singlePool, bag: &singleBag, isNight: false) {
                singlePicks.append(asset.id)
            }
        }
        let singleNoNil = singlePicks.count == 12
        let singleCycleNoRepeat = Set(singlePicks.prefix(3)).count == 3
        print("单类别素材仍能连续出片：\(singleNoNil ? "通过" : "失败")（12 次取片取到 \(singlePicks.count) 张）")
        if !singleNoNil { failures.append("单类别素材出现取片失败") }
        print("单类别下「耗尽前不重复」仍成立：\(singleCycleNoRepeat ? "通过" : "失败")")
        if !singleCycleNoRepeat { failures.append("单类别下出现循环内重复") }

        // 素材库两路来源并存。早期版本是「manifest 非空就完全替代占位素材」，
        // 那样用户导入第一张图后内置场景会凭空消失，想留着对比都做不到。
        let libraryProbe = SceneLibrary()
        let coexistOK = libraryProbe.assets.count
            == libraryProbe.importedAssets.count + libraryProbe.builtInSceneAssets.count
            && libraryProbe.builtInSceneAssets.count == pool.count
        print("导入图片与内置场景并存：\(coexistOK ? "通过" : "失败")"
              + "（导入 \(libraryProbe.importedAssets.count) + 内置 \(libraryProbe.builtInSceneAssets.count)）")
        if !coexistOK { failures.append("素材库两路来源未并存") }

        // 全禁用后 enabledAssets 必须为空，且选片不崩溃
        var allOff = AppConfig()
        allOff.useBuiltInScenes = false
        let allOffOK = libraryProbe.enabledAssets(using: allOff).count
            == libraryProbe.importedAssets.count
        print("全关内置场景后启用集等于导入集：\(allOffOK ? "通过" : "失败")")
        if !allOffOK { failures.append("启用集过滤结果不正确") }

        // 导入链路端到端。这一段会在隔离目录里真的写盘（导入、落盘、写 manifest、
        // 重启重载、改类别、删除），全程不碰用户真实的素材库。
        failures.append(contentsOf: AssetImportSelfTest.run())

        // FR-6「主文案必须是指向真实空间的祈使句」于 2026-10-13 随引导句一起取消。
        // 那一段的关键词表（中文「抬头/远处/窗外」、英文 look up/away/distance）
        // 校验的对象已经不存在了 —— 留着只会变成一条永远通过的检查。

        // 图片介绍 FR-11：齐备、双语、可核查。
        //
        // 这一段作用在**落盘数据**上，而不是生成器的模板上。生成器只保证
        // 「模板没写错」，这里保证「真的落到了每一条素材上」—— 迁移脚本写漏一条、
        // manifest 被别的工具改坏，只有这里能发现。
        //
        // 「英文侧不得出现汉字」这条**可以**放在运行时，因为它查的是
        // `SceneAsset.captionEn`（纯数据），不是渲染后的句子 —— 后者会嵌用户
        // 文件名，用户叫「风景.jpg」就会误报（FR-10.6 那条教训）。
        print("")
        func hasHan(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        let noCaption = pool.filter { ($0.captionEn ?? "").isEmpty || ($0.captionZh ?? "").isEmpty }
        let enWithHan = pool.filter { hasHan($0.captionEn ?? "") }
        // ⚠️ 「两语言不同」与「中文侧有锚点」这两条必须**看整张卡片**（名称 + 小字介绍），
        //    不能只看 `captionZh`。v1.12 起，找不到地区时主行就是原文名称 ——
        //    两种语言**本来就该相同**（地名不做臆测翻译，FR-11.3），
        //    中文锚点由小字行的类别承担。按字段断言会变成 166 条假失败，
        //    而**假警报会训练人忽略真警报**。
        func card(_ a: SceneAsset, _ lang: Language) -> String {
            (a.caption(lang) ?? "") + "|" + (a.blurb(lang) ?? "")
        }
        let sameBoth  = pool.filter { card($0, .en) == card($0, .zhHans) }
        let zhNoHan   = pool.filter { !hasHan(card($0, .zhHans)) }
        let noSource  = pool.filter { ($0.captionSource ?? "").isEmpty }
        let tooLong   = pool.filter {
            ($0.captionEn ?? "").count > 60 || ($0.captionZh ?? "").count > 84
        }
        let badYear   = pool.filter { if let y = $0.shotYear { return y < 1826 || y > 2100 } else { return false } }
        // 出处行的署名（FR-11）。判据刻意只有三条，**不复制 Python 侧那份词表** ——
        // 抄一份过来必然漂移，而「一个永远通过的检查等于没有检查」。
        // 这里只挡「放不进一行」和「明显是网址/多行」的形态：
        // 清洗规则本身由 Tools/i18n/build_captions.py 的 clean_artist() 负责。
        // ⚠️ 网址要同时查 "http" 与 "www." —— 实测 "Thomas Wolf, www.foto-tw.de"
        //    这种只有 www 的形态，第一版漏掉了（反向对照当场抓到）。
        let badCredit = pool.filter {
            guard let p = $0.photographer else { return false }
            let low = p.lowercased()
            return p.count > 40 || p.contains("\n")
                || low.contains("http") || low.contains("www.")
        }

        print("  FR-11 图片介绍（预置 \(pool.count) 张）")
        print("    两种语言齐备     ：\(pool.count - noCaption.count)/\(pool.count)")
        print("    卡片两语言不同   ：\(pool.count - sameBoth.count)/\(pool.count)"
              + "（名称 + 小字介绍合起来看）")
        print("    英文侧无汉字     ：\(pool.count - enWithHan.count)/\(pool.count)")
        print("    中文侧有中文锚点 ：\(pool.count - zhNoHan.count)/\(pool.count)"
              + "（名称或小字介绍里得有中文）")
        print("    依据字段齐备     ：\(pool.count - noSource.count)/\(pool.count)"
              + "（说明每条介绍都能回溯到图源元数据 / GPS 反查 / 人工标注的类别）")
        print("    长度在上限内     ：\(pool.count - tooLong.count)/\(pool.count)（英文 <= 60，中文 <= 84）")
        print("    拍摄年份合理     ：\(badYear.isEmpty ? "通过" : "失败（\(badYear.count) 条越界）")")
        print("    署名放得进一行   ：\(badCredit.isEmpty ? "通过" : "失败（\(badCredit.count) 条）")"
              + "（<= 40 字、无换行、无网址）")
        for (name, list) in [("缺介绍", noCaption), ("两语言相同", sameBoth),
                             ("英文含汉字", enWithHan), ("中文无汉字", zhNoHan),
                             ("缺依据", noSource), ("超长", tooLong)] where !list.isEmpty {
            print("      ! \(name)：\(list.prefix(3).map(\.id))")
            failures.append("FR-11 \(name)：\(list.count) 条")
        }
        if !badYear.isEmpty { failures.append("FR-11 拍摄年份越界：\(badYear.count) 条") }
        if !badCredit.isEmpty {
            print("      ! 署名过长：\(badCredit.prefix(3).map { "\($0.id)=\($0.photographer ?? "")" })")
            failures.append("FR-11 署名放不进一行：\(badCredit.count) 条")
        }

        // ---- FR-11.9 小字介绍 ----
        //
        // 这一行是**可核查组件重组**（类别 · 年月），不是新写的内容。
        // 判据分两组：
        //   · 形态 —— 两语言齐备、不重复、不超长、语言纯净（与主行同一套思路）；
        //   · **分工** —— 小字行不得与主行说同一件事。这是本次设计里最容易
        //     退化的地方：主行是「<地区> · <名称>」、小字行是「类别 · 年月」，
        //     一旦有人把地区加回小字行，就会出现三行重复，而**画面看着仍然正常**。
        // ⚠️ 判据是「**至少一侧非空**」，不是「两侧都非空」。
        //    v1.12 的去重规则是「类别词已出现在主行里就跳过」—— 少数素材
        //    （名称本身就是类别词的 Apple 通用名壁纸：`湖泊` / `雪原` / `沙漠 · 沙丘`
        //    / `大峡谷` / `雾中森林`）因此**没有可写的内容，整行不显示**。
        //    那是正确行为：宁可少一行，也不要 `湖泊` 上面再写一遍 `湖泊`。
        //    用**比例**而不是清单来兜底 —— 清单会随素材库扩容腐坏（本项目踩过 5 次），
        //    比例是尺度无关的。上限 3% 相对实测 6/626 = 0.96% 留了三倍余量。
        let noBlurb  = pool.filter { $0.blurb(.en) == nil && $0.blurb(.zhHans) == nil }
        let blurbGap = pool.filter { ($0.blurb(.en) == nil) != ($0.blurb(.zhHans) == nil) }
        let blurbMissingLimit = pool.count * 3 / 100
        let blurbSame = pool.filter {
            guard let e = $0.blurb(.en), let z = $0.blurb(.zhHans) else { return false }
            return e == z
        }
        let blurbEnHan = pool.filter { hasHan($0.blurb(.en) ?? "") }
        let blurbZhNo  = pool.filter { ($0.blurb(.zhHans) ?? "").isEmpty == false
                                       && !hasHan($0.blurb(.zhHans) ?? "") }
        let blurbLong  = pool.filter {
            ($0.blurb(.en) ?? "").count > 40 || ($0.blurb(.zhHans) ?? "").count > 28
        }
        // 分工判据：主行与小字行的**首个组件不得相同**。
        //   主行 = `<地区> · <名称>`（地区在前）；小字行 = `类别 · 时间`（类别在前）。
        //   两者首段相同 = 同一个东西说了两遍。
        //
        // ⚠️ **不能用「字符串互相包含」**。第一版就是这么写的，误判 6 条：
        //    中文地名本身常含类别词 —— `羚羊峡谷` 含 `峡谷`、`死亡谷` 含 `谷`，
        //    而那是**名字的一部分**，不是重复的标签。比「组件」才比得准。
        func firstPart(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "" }
            return s.components(separatedBy: " · ").first ?? ""
        }
        let blurbEcho = pool.filter {
            let c = firstPart($0.caption(.zhHans))
            let b = firstPart($0.blurb(.zhHans))
            return !c.isEmpty && c == b
        }

        print("  FR-11.9 小字介绍（预置 \(pool.count) 张）")
        print("    至少一侧非空     ：\(pool.count - noBlurb.count)/\(pool.count)"
              + "（空的那些主行本身就是类别词，没有更多可核查信息；上限 \(blurbMissingLimit) 条）")
        print("    两侧同时有/无    ：\(pool.count - blurbGap.count)/\(pool.count)"
              + "（另一侧为空是允许的：中英文名里是否已含类别词并不一致）")
        print("    两语言确实不同   ：\(pool.count - blurbSame.count)/\(pool.count)")
        print("    英文侧无汉字     ：\(pool.count - blurbEnHan.count)/\(pool.count)")
        print("    中文侧有汉字     ：\(pool.count - blurbZhNo.count)/\(pool.count)")
        print("    长度在上限内     ：\(pool.count - blurbLong.count)/\(pool.count)（英文 <= 40，中文 <= 28）")
        print("    不与主行重复     ：\(pool.count - blurbEcho.count)/\(pool.count)"
              + "（地区归主行、类别归小字行，两者首段不得相同）")
        for (name, list) in [("两语言相同", blurbSame), ("英文含汉字", blurbEnHan),
                             ("中文无汉字", blurbZhNo), ("超长", blurbLong),
                             ("与主行重复", blurbEcho)] where !list.isEmpty {
            print("      ! \(name)：\(list.prefix(3).map(\.id))")
            failures.append("FR-11.9 \(name)：\(list.count) 条")
        }
        if noBlurb.count > blurbMissingLimit {
            print("      ! 小字介绍缺失 \(noBlurb.count) 条，超过上限 \(blurbMissingLimit)")
            print("        样例：\(noBlurb.prefix(5).map { "\($0.id)=\($0.captionZh ?? "")" })")
            failures.append("FR-11.9 小字介绍缺失 \(noBlurb.count) 条（上限 \(blurbMissingLimit)）")
        }

        for asset in pool.prefix(3) {
            print("    · \(asset.id)")
            print("        名称 en: \(asset.captionEn ?? "—")")
            print("        名称 zh: \(asset.captionZh ?? "—")")
            print("        小字 en: \(asset.blurbEn ?? "—")")
            print("        小字 zh: \(asset.blurbZh ?? "—")")
            print("        依据: \(asset.captionSource ?? "—")"
                  + " / 小字用: \(asset.blurbSource ?? "—")"
                  + (asset.shotYear.map { " · \($0)" } ?? ""))
        }

        print("")
        print(String(repeating: "-", count: 46))
        if failures.isEmpty {
            print("全部通过")
            return 0
        }
        print("未通过 \(failures.count) 项：")
        for failure in failures {
            print("  · \(failure)")
        }
        return 1
    }
}
