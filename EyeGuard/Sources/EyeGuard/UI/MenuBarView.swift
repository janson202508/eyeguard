import SwiftUI
import AppKit

/// 菜单栏图标。跟随 phase 变化，因此需要观察 Scheduler。
struct MenuBarLabel: View {
    @ObservedObject var scheduler: Scheduler

    var body: some View {
        Image(systemName: scheduler.menuBarIconName)
    }
}

/// 菜单栏菜单。规格书 FR-7.2。
struct MenuBarView: View {
    @ObservedObject var scheduler: Scheduler

    /// 当前语言的文案表。整个文件只在这里取一次 —— 分散写 `Strings.english`
    /// 之类的字面量会让语言设置变成摆设，而且没有编译错误。
    private var s: Strings { scheduler.strings }

    var body: some View {
        Text(scheduler.statusText)

        if scheduler.phase == .resting {
            Text(s.menuShowingCategory(scheduler.currentAsset?.category.displayName(s) ?? "—"))
        }

        Divider()

        Button(s.menuRestNow) { scheduler.restNow() }
            .disabled(scheduler.phase == .resting || scheduler.phase == .sleeping)

        Button(s.menuSnooze(scheduler.configStore.config.snoozeMinutes)) { scheduler.snoozeFromMenu() }
            .disabled(scheduler.phase == .resting)

        if scheduler.phase == .paused {
            Button(s.menuResume) { scheduler.resume() }
        } else {
            Menu(s.menuPause) {
                Button(s.menuPauseIndefinitely) { scheduler.pauseIndefinitely() }
                Divider()
                Button(s.menuPause30) { scheduler.pause(minutes: 30) }
                Button(s.menuPause60) { scheduler.pause(minutes: 60) }
                Button(s.menuPauseToday) { scheduler.pauseUntilTomorrow() }
            }
        }

        Divider()

        Button(s.menuSettings) { SettingsWindowController.shared.show() }
        Button(s.menuQuit) { NSApp.terminate(nil) }
    }
}
