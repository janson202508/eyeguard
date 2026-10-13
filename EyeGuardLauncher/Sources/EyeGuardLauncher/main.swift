import Foundation

// 与 EyeGuard 相同的约束：存在 main.swift 时不能用 @main，
// 所以入口在这里显式调用 LauncherApp.main()。
//
// 命令行开关（都不启动界面）：
//   --make-icon <目录>   生成 .iconset 供 iconutil 打包
//   --probe              问一次 EyeGuard 状态，用于排查控制通道
//   --action <动作>      驱动一次控制台操作，用于验证「控制台 → EyeGuard」链路

if let index = CommandLine.arguments.firstIndex(of: "--make-icon") {
    let target = index + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[index + 1]
        : "AppIcon.iconset"
    do {
        try AppIconMaker.writeIconset(to: URL(fileURLWithPath: target))
        print("已生成图标集：\(target)")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            "图标生成失败：\(error.localizedDescription)\n".data(using: .utf8)!
        )
        exit(1)
    }
}

if CommandLine.arguments.contains("--probe") {
    exit(ControlProbe.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--action"),
   index + 1 < CommandLine.arguments.count {
    exit(ActionRunner.run(CommandLine.arguments[index + 1]))
}

LauncherApp.main()
