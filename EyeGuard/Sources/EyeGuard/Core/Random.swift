import Foundation

/// 单调时钟。规格书 §3.3 不变量 4：所有运行时计时基于单调时钟，
/// 不混用墙上时钟，避免系统休眠后时间跳变导致误触发。
enum Monotonic {
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// 距指定截止时刻还剩多少秒。先转 Double 再相减，避免 UInt64 下溢。
    static func secondsRemaining(until deadline: UInt64) -> Double {
        (Double(deadline) - Double(now)) / 1_000_000_000
    }

    static func deadline(afterSeconds seconds: Double) -> UInt64 {
        now &+ UInt64(max(seconds, 0) * 1_000_000_000)
    }
}

/// 确定性伪随机数发生器（SplitMix64）。
/// 用于程序化占位素材的生成与渲染，保证同一素材每次渲染结果一致。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 返回 [0, 1) 区间的 Double
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    /// 返回 [lower, upper) 区间的 Double
    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + unit() * (upper - lower)
    }
}

/// 由字符串派生稳定的 64 位种子（FNV-1a），保证素材渲染可复现。
func stableSeed(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}
