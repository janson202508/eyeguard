import Foundation

/// EyeGuard 的相位。与 EyeGuard 侧同名枚举一一对应。
///
/// 这里刻意重新声明而不是复用：跨进程传的是 `rawValue` 字符串，
/// 那份字符串才是真正的契约。重新声明让「协议变更」在两边都留下痕迹。
enum RemotePhase: String {
    case working, prewarning, resting, snoozed, suppressed, paused, sleeping

    var displayName: String {
        switch self {
        case .working:    return "计时中"
        case .prewarning: return "即将休息"
        case .resting:    return "休息中"
        case .snoozed:    return "已延后"
        case .suppressed: return "顺延中"
        case .paused:     return "已暂停"
        case .sleeping:   return "休眠中"
        }
    }
}

/// 从 EyeGuard 回传的状态快照。
struct RemoteState: Equatable {
    var phase: RemotePhase = .working
    var remainingSeconds: Int = 0
    var restRemainingSeconds: Int = 0
    var restTotalSeconds: Int = 0
    var skipUnlocked: Bool = false
    var isNight: Bool = false
    var intervalMinutes: Int = 20
    var restDurationSeconds: Int = 20
    var suppressionReasons: [String] = []
    var pausedUntil: Date?

    /// 解析失败返回 nil —— 宁可显示「未连接」，也不要拿一份半截状态去渲染界面。
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["phase"] as? String,
              let phase = RemotePhase(rawValue: raw) else { return nil }

        self.phase = phase
        remainingSeconds     = userInfo["remainingSeconds"] as? Int ?? 0
        restRemainingSeconds = userInfo["restRemainingSeconds"] as? Int ?? 0
        restTotalSeconds     = userInfo["restTotalSeconds"] as? Int ?? 0
        skipUnlocked         = userInfo["skipUnlocked"] as? Bool ?? false
        isNight              = userInfo["isNight"] as? Bool ?? false
        intervalMinutes      = userInfo["intervalMinutes"] as? Int ?? 20
        restDurationSeconds  = userInfo["restDurationSeconds"] as? Int ?? 20
        if let raw = userInfo["suppressionReasons"] as? String, !raw.isEmpty {
            suppressionReasons = raw.split(separator: ",").map(String.init)
        }
        if let since1970 = userInfo["pausedUntil"] as? Double {
            pausedUntil = Date(timeIntervalSince1970: since1970)
        }
    }

    /// 主文案。刻意与 EyeGuard 的 `statusText` 措辞对齐，避免两处说法不一致。
    var headline: String {
        switch phase {
        case .working, .snoozed, .prewarning:
            return "距离下次休息"
        case .resting:
            return "休息中"
        case .paused:
            return "已暂停提醒"
        case .suppressed:
            return "顺延中"
        case .sleeping:
            return "休眠中"
        }
    }

    /// 环里显示的数字。暂停/休眠态没有倒计时意义，返回 nil 让界面显示图标。
    var ringText: String? {
        switch phase {
        case .working, .prewarning, .snoozed:
            return Self.mmss(remainingSeconds)
        case .resting:
            return "\(restRemainingSeconds)"
        case .paused, .sleeping, .suppressed:
            return nil
        }
    }

    /// 环的填充比例 0…1
    var ringProgress: Double {
        switch phase {
        case .working, .prewarning, .snoozed:
            let total = Double(max(intervalMinutes, 1) * 60)
            return min(max(1 - Double(remainingSeconds) / total, 0), 1)
        case .resting:
            guard restTotalSeconds > 0 else { return 0 }
            let elapsed = restTotalSeconds - restRemainingSeconds
            return min(max(Double(elapsed) / Double(restTotalSeconds), 0), 1)
        case .paused, .sleeping, .suppressed:
            return 1
        }
    }

    /// 副标题：把「为什么在顺延」讲清楚，否则用户只会看到倒计时不动。
    var detail: String {
        switch phase {
        case .working:    return "正在计时，到点会全屏提醒你抬头看远处"
        case .prewarning: return "\(remainingSeconds) 秒后接管屏幕"
        case .snoozed:    return "已延后，到点会再次提醒"
        case .resting:    return skipUnlocked ? "可以跳过了" : "跳过按钮 \(max(restRemainingSeconds - restTotalSeconds + 3, 0)) 秒后可用"
        case .paused:
            if let until = pausedUntil {
                return "暂停至 \(Self.clock.string(from: until))"
            }
            return "手动暂停中，不会打扰你"
        case .suppressed:
            let names = suppressionReasons.map(Self.reasonName).joined(separator: "、")
            return names.isEmpty ? "条件不满足，已顺延" : "因「\(names)」顺延"
        case .sleeping:
            return "电脑休眠或已锁屏"
        }
    }

    private static func reasonName(_ raw: String) -> String {
        switch raw {
        case "idle":       return "你不在"
        case "fullscreen": return "全屏中"
        case "camera":     return "会议中"
        case "manual":     return "手动暂停"
        case "sleeping":   return "休眠"
        default:           return raw
        }
    }

    static func mmss(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
