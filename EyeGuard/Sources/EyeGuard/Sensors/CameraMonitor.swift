import Foundation
import CoreMediaIO

/// FR-2.3 摄像头占用检测，用于判断「正在开会」。
///
/// 通过 CoreMediaIO 枚举所有视频设备，逐个查询
/// `kCMIODevicePropertyDeviceIsRunningSomewhere`。该属性为真表示
/// 有**任意**进程正在使用该设备（不限于本程序），这是公开 API。
///
/// 结果做 3 秒缓存：避免每 0.5 秒的 tick 都去查询内核属性。
final class CameraMonitor {
    private var cachedValue = false
    private var lastCheckAt = Date.distantPast
    private let cacheInterval: TimeInterval = 3

    func isCameraInUse() -> Bool {
        if Date().timeIntervalSince(lastCheckAt) < cacheInterval {
            return cachedValue
        }
        lastCheckAt = Date()
        cachedValue = Self.queryCameraInUse()
        return cachedValue
    }

    private static func queryCameraInUse() -> Bool {
        let devices = Self.videoDeviceIDs()
        guard !devices.isEmpty else { return false }

        for device in devices {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(0)
            )
            var isRunning: UInt32 = 0
            var usedSize: UInt32 = 0
            let status = CMIOObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &usedSize,
                &isRunning
            )
            if status == 0 && isRunning != 0 {
                return true
            }
        }
        return false
    }

    private static func videoDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0)
        )

        var dataSize: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == 0, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }

        var ids = [CMIOObjectID](repeating: 0, count: count)
        var usedSize: UInt32 = 0
        let dataStatus = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &usedSize,
            &ids
        )
        guard dataStatus == 0 else { return [] }
        return ids
    }
}
