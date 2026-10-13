# EyeGuard 控制台

一个窗口、一个大开关，用来启停 EyeGuard。

EyeGuard 本体是「菜单栏常驻、没有 Dock 图标」的形态 —— 这是对的，但它意味着
「启动」要去找 `.app`、「退出」要去点菜单栏，日常用起来别扭。控制台就是为了
消掉这点摩擦。

## 怎么用

安装（会同时构建两个程序并放到 `/Applications`）：

```bash
cd ..
bash install.sh
```

之后从**启动台**或**聚焦搜索**打开「EyeGuard 控制台」。窗口里只有几件事：

| 控件 | 行为 |
|---|---|
| 主按钮 | 未运行 → **启动护眼**；运行中 → **暂停提醒**；已暂停 → **恢复提醒** |
| 立即休息 / 跳过这次休息 | 运行中时手动触发一次休息；正在休息时变成跳过 |
| 设置… | 打开 EyeGuard 的设置窗口 |
| 退出护眼 | 真正结束 EyeGuard 进程 |
| 定位 EyeGuard… | 自动找不到时手动指定 `.app` 位置 |

### 「暂停」和「退出」的区别

这是两个不同的需求，都保留了：

- **暂停提醒** —— 进程继续常驻菜单栏，随时一键恢复。适合开会、看片。
  计时会重新开始，不保留暂停前的进度。
- **退出护眼** —— 进程真的结束，不占内存。下次要用得重新启动。

暂停**不跨重启**：退出程序即视为重新开始。这是刻意的 —— 忘掉暂停只是多被
提醒一次，忘掉恢复则是护眼程序彻底静默，后者的失效方向危险得多。

## 界面

| 状态 | 截图 |
|---|---|
| 未运行 | `screenshots/01-未运行.png` |
| 计时中 | `screenshots/02-计时中.png` |
| 已暂停 | `screenshots/03-已暂停.png` |
| 顺延中 | `screenshots/04-顺延中.png` |

> ⚠️ 这四张**裁掉了底部状态栏**。原因：那一栏会显示定位到的 App 路径，
> 而从构建目录运行时它就是本机绝对路径（含用户名）。裁掉是最干净的脱敏方式 ——
> 比在图上涂改诚实，也比重新截图省事（「顺延中」那个状态需要真的制造系统状态）。
> 状态栏本身显示的是「定位 EyeGuard…」与「退出护眼」，不影响这四张要表达的内容。

顺延态会把**原因**写出来（「因『你不在』顺延」「因『会议中』顺延」），
而不是只让倒计时停住 —— 倒计时不动但不说为什么，是这类程序最让人烦躁的地方。

## 架构

两个独立进程，用 `DistributedNotificationCenter` 通信。

```
EyeGuard 控制台                          EyeGuard
  LauncherModel                            ControlChannel
       │                                        │
       │  ── control {action: pause} ─────────► │  handleControl()
       │                                        │      ↓
       │  ◄── status {phase, remaining, …} ──── │  statusSnapshot
       │                                        │
   每秒发一次 status 请求做心跳 + 刷新倒计时
```

### 为什么是 DistributedNotificationCenter

XPC 需要 launchd 配置，Unix socket 要管 socket 文件的生命周期，两者都比这个
场景需要的重。两个程序都是本机非沙箱应用、同一用户，分布式通知是成本最低、
且**不需要任何权限**的方案。已实测跨进程可用（含 ad-hoc 签名的两个独立二进制）。

### 「在不在运行」怎么判断

不是去查进程表，而是**发一次 `status` 请求看有没有回复**。
这直接测的是「控制通道是否活着」，也就是我们真正关心的事。好处是绕开了
「从终端直接启动的进程是否被 LaunchServices 登记」这类各版本行为不一致的坑。

超时策略：正常情况 2.5 秒无回复即判掉线；刚点过「启动」给 10 秒宽限期
（应用启动 + 注册观察者要时间）；冷启动首次探测给 1.2 秒。

### 协议定义有两份副本

`ControlProtocol` 在两侧各定义了一份（`Sources/EyeGuardLauncher/ControlProtocol.swift`
与 `EyeGuard/Sources/EyeGuard/Core/ControlChannel.swift`）。两个工程是独立的
SPM package，共用一个 target 需要把 EyeGuard 拆成 library + executable，
代价大于收益。**改一边务必改另一边** —— 不一致的表现是「按钮点了没反应」
这种最难查的静默失败。

## 命令行开关

三个都不启动界面，用于测试与排查：

```bash
APP="/Applications/EyeGuardLauncher.app/Contents/MacOS/EyeGuardLauncher"

"$APP" --probe                  # 问一次状态，退出码 0=在跑 1=没跑
"$APP" --action start           # 启动 EyeGuard
"$APP" --action pause           # 暂停
"$APP" --action resume          # 恢复
"$APP" --action rest            # 立即休息
"$APP" --action skip            # 跳过当前休息
"$APP" --action quit            # 退出 EyeGuard
"$APP" --make-icon <目录>        # 生成 .iconset 供 iconutil 打包
```

`--action` 走的是**和按钮完全相同的 `LauncherModel` 方法**，只把「谁来调用」
从 SwiftUI 换成了命令行。它存在的理由很实际：用界面点击做自动化验证需要
「辅助功能」授权才能合成鼠标事件，在受控环境里往往给不了。

## 构建

```bash
bash build.sh release        # 产出 build/EyeGuardLauncher.app
```

图标是**代码生成**的（`AppIconMaker.swift`，纯 CoreGraphics 绘制，不依赖窗口
服务器），`build.sh` 调用 `--make-icon` 生成 `.iconset` 后用 `iconutil` 打成
`.icns`。这样图标能随品牌色调整，也不必在版本控制里放二进制文件。

### 环境注意

- `swift build` **必须加 `--disable-sandbox`**（已写进 `build.sh`）：
  SPM 默认对 `Package.swift` 求值再套一层 `sandbox-exec`，与本机外层沙箱嵌套
  会失败，报 `Invalid manifest`，极易误判成 `Package.swift` 写错。
- `build.sh` 没有可执行位，用 `bash build.sh`。
- `swiftc` 直接调用会报 `unable to load standard library`（只装了 Command Line
  Tools 的机器上缺 SDK），所以图标生成器做成主程序的一个开关而不是独立脚本。

## 已知限制

- **窗口内的按钮点击无法自动化测试**：需要「辅助功能」授权才能合成鼠标事件。
  已用 `--action` 覆盖同一条代码路径；按钮到方法的绑定只有几行，靠人工点一次确认。
- **控制通道不校验来源**：同机同用户的任何进程都能发这些指令。
  对个人自用工具可以接受；如果要分发，需要换成带校验的 XPC。
- **没有开机自启**：控制台刻意不做这件事。EyeGuard 自己的设置里有
  「开机自动启动」，两处都放会变成两个真相来源。
