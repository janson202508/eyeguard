import Foundation

/// 规格书 §4 选片算法。
///
/// ## 为什么是「分轮调度」而不是「加权随机」
///
/// 最初的实现是「按各类别剩余量加权随机抽取」。自检发现它在**尾段**会失效：
/// 当某个类别的素材剩到最后、其他类别已空时，只能连续从它取片，
/// 于是「相邻两次类别不同」这条约束被打破（实测 10000 次取片中出现 9 次）。
///
/// 改为分轮调度后，三条约束从「概率上成立」变成「可证明成立」：
///
/// 一轮 = 把当前仍有余量的类别洗牌排成一列，每个类别各取一张。
///
///   ① 素材库耗尽前不重复
///      取出即从袋中移除，只有全部类别都空时才重洗。
///   ② 相邻两次场景类别不同
///      轮内是「不同类别的排列」，天然满足；跨轮衔接处显式交换首元素避开上一轮的末位。
///   ③ 窗口内类别分布均衡
///      每个类别每轮恰好被取一次，因此任意类别的取片次数 = 它参与的轮数，
///      上界为最大配额、下界为最小配额，偏差不超过两者之差。
///
/// 按规格书附录 A 的配额（4–6 张），一个完整循环 50 次取片分布在 6 轮里，
/// 每轮类别数依次为 10、10、10、10、7、3 —— 全部远大于 1，因此约束 ② 成立。
///
/// ⚠️ 2026-10-12 修正：**约束 ② 只在「各类别规模接近」时成立。**
/// 规模不均衡时，尾段会只剩最大的那一个类别，只能连续取它 —— 这正是规格书
/// §4 步骤 2 里「仅剩 1 类时放宽并记日志」那条例外覆盖的情况。
///
/// 实测（627 张：lake 108 / mountain 99 / canyon 96 / … / grassland 24）：
///   单类别尾段轮数 = 最大类别 − 次大类别 = 108 − 99 = 9
///   每轮平均 8.5 次相邻同类（200 轮 × 627 次取片共 1699 次），全部落在尾段。
/// 素材库 392 张时最大两类同为 55 张，尾段恰好为空 —— 那是**碰巧**通过，
/// 不是算法保证了它。自检因此改为「只有仍有多个类别可选时的相邻同类才算违约」。
struct AssetPicker {

    /// 夜间不使用的素材：暖调刺眼，雪景整体亮度过高（FR-4.7）
    private static func isNightFriendly(_ asset: SceneAsset) -> Bool {
        asset.tone != .warm && asset.category != .snow
    }

    static func pick(pool: [SceneAsset],
                     bag: inout ShuffleBagState,
                     isNight: Bool,
                     log: (String) -> Void = { _ in }) -> SceneAsset? {
        guard !pool.isEmpty else { return nil }

        var byCategory: [SceneCategory: [SceneAsset]] = [:]
        for asset in pool {
            byCategory[asset.category, default: []].append(asset)
        }

        pruneStaleIDs(validIDs: Set(pool.map(\.id)), bag: &bag)

        // 全部耗尽 → 重洗，开启新的大循环
        let exhausted = bag.remainingByCategory.isEmpty
            || bag.remainingByCategory.values.allSatisfy { $0.isEmpty }
        if exhausted {
            refillCycle(byCategory: byCategory, bag: &bag, isNight: isNight)
            log("素材库耗尽，重洗开启新循环")
        }

        // 夜间：若当前循环剩余的素材里已经没有夜间可用项，按夜间规则重洗。
        //
        // 这里刻意不采用「退回全部类别」的兜底 —— 那会在深夜放出暖调或高亮
        // 雪景，正是最不该出现的画面。代价是夜间跨过日/夜交界时，
        // 「耗尽前不重复」的保证会提前中断一次。这个取舍是明确的：
        // 夜间不刺眼 优先于 不重复。
        if isNight, !hasNightFriendlyRemaining(byCategory: byCategory, bag: bag) {
            refillCycle(byCategory: byCategory, bag: &bag, isNight: true)
            log("夜间可用素材已耗尽，按夜间规则重洗")
        }

        if bag.roundOrder.isEmpty {
            startNewRound(byCategory: byCategory, bag: &bag, isNight: isNight, log: log)
        }

        guard let category = takeNextCategory(byCategory: byCategory,
                                              bag: &bag,
                                              isNight: isNight,
                                              log: log) else {
            return nil
        }

        let remainingIDs = bag.remainingByCategory[category.rawValue] ?? []
        let inBag = remainingIDs.compactMap { id in
            byCategory[category]?.first { $0.id == id }
        }
        guard !inBag.isEmpty else { return nil }

        // 夜间优先冷调/中性调
        var pickable = inBag
        if isNight {
            let nightFriendly = inBag.filter(isNightFriendly)
            if !nightFriendly.isEmpty { pickable = nightFriendly }
        }

        // FR-4.6：优先 depthScore >= 4；同档内保持随机
        let highDepth = pickable.filter { $0.depthScore >= 4 }
        let finalPool = highDepth.isEmpty ? pickable : highDepth
        guard let picked = finalPool.randomElement() else { return nil }

        bag.remainingByCategory[category.rawValue] = remainingIDs.filter { $0 != picked.id }
        bag.recentCategories.append(category.rawValue)
        if bag.recentCategories.count > 6 {
            bag.recentCategories.removeFirst(bag.recentCategories.count - 6)
        }
        bag.recentAssetIDs.append(picked.id)
        if bag.recentAssetIDs.count > 20 {
            bag.recentAssetIDs.removeFirst(bag.recentAssetIDs.count - 20)
        }

        return picked
    }

    // MARK: - 轮次调度

    /// 从本轮队列取出下一个仍有余量的类别。队列走空则开新一轮。
    private static func takeNextCategory(byCategory: [SceneCategory: [SceneAsset]],
                                         bag: inout ShuffleBagState,
                                         isNight: Bool,
                                         log: (String) -> Void) -> SceneCategory? {
        if let category = dequeueAvailable(bag: &bag) {
            return category
        }
        // 本轮队列里全是已取空的类别（理论上不会发生），重开一轮兜底
        startNewRound(byCategory: byCategory, bag: &bag, isNight: isNight, log: log)
        return dequeueAvailable(bag: &bag)
    }

    private static func dequeueAvailable(bag: inout ShuffleBagState) -> SceneCategory? {
        while let raw = bag.roundOrder.first {
            bag.roundOrder.removeFirst()
            guard let category = SceneCategory(rawValue: raw) else { continue }
            if !(bag.remainingByCategory[raw] ?? []).isEmpty {
                return category
            }
        }
        return nil
    }

    /// 开启新一轮：把仍有余量的类别洗牌排成一列。
    private static func startNewRound(byCategory: [SceneCategory: [SceneAsset]],
                                      bag: inout ShuffleBagState,
                                      isNight: Bool,
                                      log: (String) -> Void) {
        let allAvailable = SceneCategory.allCases.filter {
            !(bag.remainingByCategory[$0.rawValue] ?? []).isEmpty
        }
        guard !allAvailable.isEmpty else { return }

        // 夜间只排入「至少还有一张夜间可用素材」的类别
        var available = allAvailable
        if isNight {
            let nightAvailable = allAvailable.filter { category in
                let ids = bag.remainingByCategory[category.rawValue] ?? []
                return ids.contains { id in
                    guard let asset = byCategory[category]?.first(where: { $0.id == id }) else {
                        return false
                    }
                    return isNightFriendly(asset)
                }
            }
            // 极端情况下（剩余的素材全是暖调/雪景）退回全部类别，避免无片可展示
            if !nightAvailable.isEmpty { available = nightAvailable }
        }

        var order = available.shuffled()

        // 约束 ②：跨轮衔接处也不能与上一轮最后展示的类别相同
        if order.count > 1, let lastRaw = bag.recentCategories.last, order[0].rawValue == lastRaw {
            order.swapAt(0, 1)
        }

        bag.roundOrder = order.map(\.rawValue)
        log("开启新一轮（\(order.count) 个类别）")
    }

    // MARK: - 素材库维护

    /// 当前循环里是否还存在至少一张夜间可用素材
    private static func hasNightFriendlyRemaining(byCategory: [SceneCategory: [SceneAsset]],
                                                 bag: ShuffleBagState) -> Bool {
        for (category, assets) in byCategory {
            let remaining = Set(bag.remainingByCategory[category.rawValue] ?? [])
            if assets.contains(where: { remaining.contains($0.id) && isNightFriendly($0) }) {
                return true
            }
        }
        return false
    }

    /// 素材库发生变动（新增下载素材、删除缓存）后，清掉袋中已不存在的 id
    private static func pruneStaleIDs(validIDs: Set<String>, bag: inout ShuffleBagState) {
        let existing = bag.remainingByCategory
        var cleaned: [String: [String]] = [:]
        for (key, ids) in existing {
            cleaned[key] = ids.filter { validIDs.contains($0) }
        }
        bag.remainingByCategory = cleaned
    }

    /// 重洗整个循环。最近展示过的素材排到队尾，用于跨循环撞车规避。
    ///
    /// `isNight` 为真时只把夜间可用的素材放进袋里，这样夜间循环里根本不存在
    /// 暖调与雪景，也就不会出现「剩下几张全是刺眼的」这种尾段困境。
    private static func refillCycle(byCategory: [SceneCategory: [SceneAsset]],
                                    bag: inout ShuffleBagState,
                                    isNight: Bool) {
        let recentlySeen = Set(bag.recentAssetIDs)
        var fresh: [String: [String]] = [:]

        for (category, assets) in byCategory {
            let eligible = isNight ? assets.filter(isNightFriendly) : assets
            guard !eligible.isEmpty else { continue }

            let shuffled = eligible.map(\.id).shuffled()
            let unseen = shuffled.filter { !recentlySeen.contains($0) }
            let seen = shuffled.filter { recentlySeen.contains($0) }
            fresh[category.rawValue] = unseen + seen
        }

        bag.remainingByCategory = fresh
        bag.roundOrder = []
    }
}
