import Foundation

// 显式入口。存在 main.swift 时不能再用 @main 标注 App 类型。
//
// --self-test      跑《需求规格书 v1》§9 的自动化验收项，跑完即退出，不启动菜单栏 UI。
// --shot-settings  把设置界面离屏渲染成 PNG，用于开发期自查（见 SettingsShot）。
// --shot-rest      把休息画面离屏**连拍**成 PNG，用于验证「换一张」真的重绘（见 RestShot）。
//                  可选再跟一个 `WxH` 指定窗口尺寸（默认取主屏实际点数）。
//                  布局对宽高比敏感，所以这个参数是必要的，不是方便。
//                  设 EYEGUARD_LAYOUT_PROBE=1 会额外打印各控件在窗口里的实际坐标。
// --probe-overlay  在**真实屏幕**上走一遍生产展示路径并测量控件坐标（见 OverlayProbe）。
//                  离屏渲染证明不了生产窗口的几何，这个能。
// --probe-keys     验证休息画面的键盘操作（← / → 换图）真的会被送到（见 KeyProbe）。
//                  事件会不会走到窗口取决于宿主视图有没有吃掉它，这个读代码看不出来。

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

if CommandLine.arguments.contains("--probe-overlay") {
    exit(OverlayProbe.run())
}

if CommandLine.arguments.contains("--probe-keys") {
    exit(KeyProbe.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--shot-settings") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : NSTemporaryDirectory() + "eyeguard-shots"
    exit(SettingsShot.run(outputDirectory: output))
}

if let index = CommandLine.arguments.firstIndex(of: "--shot-rest") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : NSTemporaryDirectory() + "eyeguard-rest-shots"
    var size: CGSize?
    if CommandLine.arguments.count > index + 2 {
        let text = CommandLine.arguments[index + 2]
        guard let parsed = RestShot.parseSize(text) else {
            print("窗口尺寸写法不对：\(text)（应形如 1920x1080）")
            exit(2)
        }
        size = parsed
    }
    exit(RestShot.run(outputDirectory: output, size: size))
}

if let index = CommandLine.arguments.firstIndex(of: "--shot-sheet") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : NSTemporaryDirectory() + "eyeguard-sheet"
    exit(SceneSheet.run(outputDirectory: output))
}

EyeGuardApp.main()
