import AppKit

/// 验证休息画面的键盘操作真的会被送到 —— FR-3.12。
///
/// 用法：`EyeGuard --probe-keys`
///
/// ## 为什么需要它
///
/// `RestOverlayWindow.keyDown` 只有在事件**真的走到窗口**时才会被调用。
/// 而事件会不会走到窗口，取决于 SwiftUI 的宿主视图有没有把它吃掉 ——
/// 这是**读代码看不出来**的：`NSHostingView` 对方向键的处理没有任何文档承诺，
/// 今天不吃不代表以后不吃（SwiftUI 一旦给它加上键盘焦点导航，方向键就被
/// 提前消费了，而症状是「按键毫无反应」，非常难查）。
///
/// 所以这里造一个真实的 `NSEvent`，走完整的分发路径，看素材有没有真的换。
///
/// ## 三种事件都要验
///
/// | 事件 | 期望 |
/// |---|---|
/// | ← / → | 换图，**并把单次休息重新计时** |
/// | ← / → 且 `isARepeat` | **不**换（否则按住不放会把 state.json 打成每秒几十次写入） |
/// | 无关按键（例如 A） | **不**换（别把整个键盘吞掉） |
///
/// 最后一条容易被忽略，但它是「只处理该处理的键」这条纪律的守卫。
enum KeyProbe {

    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124

    private static var failures = 0

    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempHome = NSTemporaryDirectory() + "eyeguard-keyprobe-\(UUID().uuidString)"
        setenv("EYEGUARD_HOME", tempHome, 1)
        defer {
            unsetenv("EYEGUARD_HOME")
            try? FileManager.default.removeItem(atPath: tempHome)
        }

        let configStore = ConfigStore()
        configStore.persistenceSuspended = true
        let scheduler = Scheduler(configStore: configStore,
                                  sceneLibrary: SceneLibrary())
        let controller = RestOverlayController()
        scheduler.presenter = controller

        // 定时器必须跑起来。
        //
        // 第 7 项要验「换图重置倒计时」，而 `restRemainingSeconds` 是**由定时器
        // 驱动**的：不启动定时器，读数永远停在满值，「按完等于满值」就恒成立 ——
        // 那一项会退化成永远通过的检查。生产环境走的是 `AppEnvironment.start()`，
        // 这里与它保持一致。
        scheduler.start()

        scheduler.restNow()
        settle(1.2)

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0 is RestOverlayWindow }),
              let overlay = window as? RestOverlayWindow else {
            print("✗ 没有找到可见的 RestOverlayWindow")
            return 1
        }

        // 这一组诊断比断言本身还重要。
        //
        // 探针从 shell 启动，抢不到前台（macOS 对「抢焦点」的限制越来越严），
        // 所以这里 `NSApp.isActive` 必然是 false、窗口也不会成为 key window。
        // 这**不代表生产环境也这样** —— 生产环境已实测：
        // 展示期间 `lsappinfo front` 返回 `EyeGuard`，应用确实在前台。
        //
        // 结论怎么读：
        //   · 「按 → / ← 换图」这四条走的是 `NSApp.sendEvent` → 窗口的 keyDown。
        //     这条**要求窗口是 key window**，而 key window 状态从进程外观测不到，
        //     所以这四条只能证明「事件到达窗口后处理是对的」，不能外推。
        //   · 「经事件队列投递」那条走的是本地事件监听器，也就是**生产主路径**。
        //     它只要求**应用活跃** —— 这个前提是可观测、且已验证成立的。
        print("覆盖窗 frame \(NSStringFromRect(overlay.frame))  windowNumber=\(overlay.windowNumber)")
        print("  NSApp.isActive=\(NSApp.isActive)  isKeyWindow=\(overlay.isKeyWindow)  "
              + "isMainWindow=\(overlay.isMainWindow)")
        print("  keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")  "
              + "mainWindow=\(NSApp.mainWindow.map { String(describing: type(of: $0)) } ?? "nil")")
        if !NSApp.isActive {
            print("  ⓘ 探针进程抢不到前台（预期如此，从 shell 启动）。"
                  + "生产环境实测 `lsappinfo front` = EyeGuard，应用在前台。")
            print("    下面带「经事件队列」的那条走本地监听器 = 生产主路径；"
                  + "其余四条走窗口 keyDown，只能证明处理逻辑正确。")
        }
        print("")

        // ① → 换图
        expectChange("按 → 换图", key: rightArrow, characters: "\u{F703}", isRepeat: false,
                     scheduler: scheduler, window: overlay, shouldChange: true)

        // ② ← 换图
        expectChange("按 ← 换图", key: leftArrow, characters: "\u{F702}", isRepeat: false,
                     scheduler: scheduler, window: overlay, shouldChange: true)

        // ③ 按住不放（系统重复）必须不换
        expectChange("按住 → 不放（isARepeat）不换图", key: rightArrow,
                     characters: "\u{F703}", isRepeat: true,
                     scheduler: scheduler, window: overlay, shouldChange: false)

        // ④ 无关按键必须不换
        expectChange("按 A 不换图", key: 0, characters: "a", isRepeat: false,
                     scheduler: scheduler, window: overlay, shouldChange: false)

        // ⑤ 再走一遍**真实事件队列**（postEvent → nextEvent → sendEvent）。
        //    上面四条用的是 `NSApp.sendEvent` 直接投递 —— 那条路会**绕过本地
        //    事件监听器**，走的是窗口的 `keyDown`。而监听器恰恰是主路径
        //    （见 `RestOverlayController.installKeyMonitor` 的说明），
        //    所以这一条测的是主路径，必须过。
        let before = scheduler.currentAsset?.id
        postAndDispatch(key: rightArrow, characters: "\u{F703}", window: overlay)
        settle(0.5)
        let after = scheduler.currentAsset?.id
        record("经事件队列投递（走本地监听器）→ 换图",
               ok: after != nil && after != before,
               detail: "\(before ?? "nil") → \(after ?? "nil")")

        // ⑦ 换图必须**把单次休息重新计时**（FR-9.9 / AC-22）。
        //
        // 判据不能写成「按完等于满值」—— 刚进休息时本来就是满值，那是**假通过**。
        // 必须先让倒计时真的走掉几秒（读数下降），再按 →，确认读数**回到满值**。
        // 前半段（`drained < restTotal`）就是在防这一项自己变成空检查。
        //
        // 顺带验证「重新计时**不重置**跳过解锁状态」：解锁延迟的作用是防止
        // 休息一开始被反射性跳过，反复换图不该把用户重新锁在里面。
        let restTotal = scheduler.restTotalSeconds
        let skipWasUnlocked = scheduler.skipUnlocked
        settle(2.2)
        let drained = scheduler.restRemainingSeconds
        let assetBeforeSwitch = scheduler.currentAsset?.id

        postAndDispatch(key: rightArrow, characters: "\u{F703}", window: overlay)
        // 同步读：`nextScene()` 里是直接赋值，不必等下一次 tick。
        // 等一个 settle 再读反而会白白走掉一秒，把断言逼到边界上。
        let refilled = scheduler.restRemainingSeconds
        settle(0.5)
        let switched = scheduler.currentAsset?.id != assetBeforeSwitch

        record("换图后单次休息重新计时",
               ok: switched && drained < restTotal && refilled >= restTotal - 1,
               detail: "换图前 \(drained)/\(restTotal) → 换图后 \(refilled)/\(restTotal)"
                     + (switched ? "" : "（图没换，判据无效）"))

        record("重新计时不重置跳过解锁状态",
               ok: scheduler.skipUnlocked == skipWasUnlocked,
               detail: "\(skipWasUnlocked) → \(scheduler.skipUnlocked)"
                     + (skipWasUnlocked && !scheduler.skipUnlocked
                        ? "（重新上锁了 —— 反复换图会把用户困住）" : ""))

        print("")
        controller.dismiss()
        settle(0.8)

        // ⑥ 收起之后监听器必须**真的摘掉**，否则退出休息后方向键还会被吞。
        //    判据：把一条方向键事件投进队列再取出来 ——
        //    取得到说明没被吞（对），取不到（超时）说明监听器还在（错）。
        let swallowed = postAndCheckSwallowed(key: rightArrow,
                                              characters: "\u{F703}",
                                              window: overlay)
        record("收起后方向键不再被吞（监听器已摘除）", ok: !swallowed,
               detail: swallowed ? "事件被吞掉了 —— 监听器没摘干净"
                                 : "事件正常流回队列")

        print("")
        if failures == 0 {
            print("键盘验证：全部通过")
            return 0
        }
        print("键盘验证：\(failures) 项未通过")
        return 1
    }

    // MARK: - 断言

    private static func expectChange(_ title: String,
                                     key: UInt16,
                                     characters: String,
                                     isRepeat: Bool,
                                     scheduler: Scheduler,
                                     window: NSWindow,
                                     shouldChange: Bool) {
        let before = scheduler.currentAsset?.id
        guard let event = makeEvent(key: key, characters: characters,
                                    isRepeat: isRepeat, window: window) else {
            record(title, ok: false, detail: "NSEvent.keyEvent 返回 nil")
            return
        }
        NSApp.sendEvent(event)
        settle(0.5)
        let after = scheduler.currentAsset?.id

        let changed = (after != before)
        let ok = shouldChange ? (after != nil && changed) : !changed
        var detail = "\(before ?? "nil") → \(after ?? "nil")"
        if !shouldChange && changed { detail += "（不该变却变了）" }
        if shouldChange && !changed { detail += "（该变却没变 —— 事件大概被宿主视图吃掉了）" }
        record(title, ok: ok, detail: detail)
    }

    private static func postAndDispatch(key: UInt16, characters: String, window: NSWindow) {
        guard let event = makeEvent(key: key, characters: characters,
                                    isRepeat: false, window: window) else { return }
        NSApp.postEvent(event, atStart: false)
        // 不用 NSApp.run()：这里只要把刚投进去的那一条取出来再正常分发。
        if let pulled = NSApp.nextEvent(matching: .keyDown,
                                        until: Date().addingTimeInterval(0.5),
                                        inMode: .default,
                                        dequeue: true) {
            NSApp.sendEvent(pulled)
        }
    }

    /// 投一条方向键进队列再取出来，看它有没有被本地事件监听器吞掉。
    /// 取得到 = 没被吞；超时取不到 = 被吞了。
    private static func postAndCheckSwallowed(key: UInt16,
                                              characters: String,
                                              window: NSWindow) -> Bool {
        guard let event = makeEvent(key: key, characters: characters,
                                    isRepeat: false, window: window) else { return false }
        NSApp.postEvent(event, atStart: false)
        let pulled = NSApp.nextEvent(matching: .keyDown,
                                     until: Date().addingTimeInterval(0.4),
                                     inMode: .default,
                                     dequeue: true)
        return pulled == nil
    }

    private static func makeEvent(key: UInt16,
                                  characters: String,
                                  isRepeat: Bool,
                                  window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat,
                         keyCode: key)
    }

    private static func record(_ title: String, ok: Bool, detail: String) {
        print("  \(ok ? "✓" : "✗") \(title)    \(detail)")
        if !ok { failures += 1 }
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
