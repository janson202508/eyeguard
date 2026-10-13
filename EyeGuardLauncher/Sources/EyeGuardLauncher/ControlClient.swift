import Foundation

/// 控制通道的客户端（跑在启动器里）。
///
/// 心跳设计：启动器每秒发一次 `status` 请求，EyeGuard 回一份快照。
/// 用「有没有收到回复」判断对方在不在，而不是去查进程表 ——
/// 这直接测的是**控制通道是否活着**，也就是我们真正关心的事。
/// 好处是绕开了「从终端直接启动的进程是否被 LaunchServices 登记」这类
/// 各版本行为不一致的坑。
final class ControlClient {
    private let center = DistributedNotificationCenter.default()
    private var observers: [NSObjectProtocol] = []

    private var onState: ((RemoteState) -> Void)?
    private var onEvent: ((String) -> Void)?

    func start(onState: @escaping (RemoteState) -> Void,
               onEvent: @escaping (String) -> Void) {
        self.onState = onState
        self.onEvent = onEvent

        observers.append(center.addObserver(forName: ControlProtocol.status,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            guard let info = note.userInfo, let state = RemoteState(userInfo: info) else { return }
            self?.onState?(state)
        })

        observers.append(center.addObserver(forName: ControlProtocol.event,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            guard let name = note.userInfo?["event"] as? String else { return }
            self?.onEvent?(name)
        })
    }

    deinit {
        observers.forEach { center.removeObserver($0) }
    }

    func send(_ action: ControlProtocol.Action) {
        center.postNotificationName(ControlProtocol.control,
                                    object: nil,
                                    userInfo: ["action": action.rawValue],
                                    deliverImmediately: true)
    }
}
