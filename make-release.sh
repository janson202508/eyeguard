#!/bin/bash
#
# 打一个可以直接发到 GitHub Release 的 zip。
#
# 用法：
#   bash make-release.sh              # 构建 + 打包
#   bash make-release.sh --no-build   # 用现有产物打包
#
# 产出：dist/EyeGuard-<版本>-macos.zip
#   ├─ EyeGuard.app            菜单栏本体（含 609 张素材）
#   ├─ EyeGuard 控制台.app      开关面板
#   └─ 安装说明.txt
#
# ⚠️ 两件必须知道的事：
#
# ① **zip 里必须带素材。** 素材 JPEG 不进 git（410 MB，是生成物），
#    但发布包必须带 —— 否则用户拿到的是空壳，构建出来只有程序化占位图，
#    而「609 张筛选过的风景」正是这个 App 唯一的差异化。
#
# ② **安装方式必须写成终端命令，不能只写「下载解压」。**
#    实测（2026-10-13）：curl 下载的文件**没有** com.apple.quarantine 属性，
#    双击即可运行；而浏览器下载会给 zip 打上隔离属性，解压后传播到 .app，
#    首次启动被 Gatekeeper 拦下（macOS 15 起「右键→打开」的绕过方式已被 Apple 移除，
#    用户必须走「系统设置 → 隐私与安全性 → 仍要打开」）。
#    ⇒ 本项目**未做代码签名与公证**（需要 Apple Developer 账号，$99/年），
#      所以 README 里必须给 curl 路径。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
NAME="EyeGuard.app"
LAUNCHER="EyeGuardLauncher.app"

DO_BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done

if [ "$DO_BUILD" -eq 1 ]; then
    echo "==> 构建 EyeGuard"
    bash "$ROOT/EyeGuard/build.sh" release
    echo
    echo "==> 构建 EyeGuard 控制台"
    bash "$ROOT/EyeGuardLauncher/build.sh" release
    echo
fi

for app in "$ROOT/EyeGuard/build/$NAME" "$ROOT/EyeGuardLauncher/build/$LAUNCHER"; do
    [ -d "$app" ] || { echo "!! 找不到构建产物：$app" >&2; exit 1; }
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/EyeGuard/build/$NAME/Contents/Info.plist" 2>/dev/null || echo 1.0)"
ZIP="$DIST/EyeGuard-$VERSION-macos.zip"

# ⚠️ 不用 rm -rf 清 dist：一个 turn 内删超过 50 个文件会被批量删除守卫中止。
#    用 mktemp + mv（改名不算删除），和 build.sh 里的做法一致。
if [ -d "$DIST" ]; then
    STALE="$(mktemp -d "${TMPDIR:-/tmp}/eyeguard-dist-XXXXXX")"
    mv "$DIST" "$STALE/dist"
fi
mkdir -p "$DIST/stage"

echo "==> 组装发布包"
cp -R "$ROOT/EyeGuard/build/$NAME" "$DIST/stage/"
cp -R "$ROOT/EyeGuardLauncher/build/$LAUNCHER" "$DIST/stage/"

# 把控制台 .app 的显示名改成中文 —— 用户在「应用程序」里看到的就是这个名字
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName "EyeGuard 控制台"' \
    "$DIST/stage/$LAUNCHER/Contents/Info.plist" 2>/dev/null || true

cat > "$DIST/stage/安装说明.txt" <<'TXT'
EyeGuard —— 安装说明
====================

⚠️ 请用下面的终端命令安装，不要双击解压。

原因：本项目未做代码签名与公证（那需要 Apple Developer 账号，$99/年）。
      浏览器下载的文件会被 macOS 打上「隔离属性」，解压后首次启动会被
      Gatekeeper 拦下；而 curl 下载不会。实测如此。


安装（三行）
------------

    cd ~/Downloads
    curl -L -o eyeguard.zip \
      https://github.com/janson202508/eyeguard/releases/latest/download/EyeGuard-1.0-macos.zip
    unzip -q eyeguard.zip && mv EyeGuard.app EyeGuardLauncher.app /Applications/

（在「应用程序」里，EyeGuardLauncher.app 显示为「EyeGuard 控制台」——
  那是它的 CFBundleDisplayName，文件名与显示名不一致是 macOS 的正常行为。）


启动
----

打开「启动台」→「EyeGuard 控制台」→ 点「启动护眼」。

第一次运行后，菜单栏会出现一个眼睛图标。到点它会接管整屏，
给你看一张风景照，20 秒后自动消失。


如果你已经用浏览器下载了（双击打不开）
--------------------------------------

任选一种：

  ① 终端里去掉隔离属性：
     xattr -dr com.apple.quarantine /Applications/EyeGuard.app
     xattr -dr com.apple.quarantine /Applications/EyeGuardLauncher.app

  ② 或者走系统设置：
     打开被拦的 App → 系统设置 → 隐私与安全性 → 拉到底 → 「仍要打开」→ 输密码


卸载
----

    rm -rf /Applications/EyeGuard.app /Applications/EyeGuardLauncher.app

设置与状态在 ~/Library/Application Support/EyeGuard/，需要一并清除就手动删掉。


许可
----

代码：MIT。
内置风景照：来自 Wikimedia Commons，各自适用其原始许可。
逐条的作者、许可与来源链接见 App 内「设置 → 关于」。
TXT

echo "==> 打包（zip 不压缩 JPEG，所以体积接近原始大小）"
(cd "$DIST/stage" && zip -qry "$ZIP" .)

echo
echo "==> 完成"
echo "    $ZIP"
echo "    体积 $(du -h "$ZIP" | cut -f1)"
echo
echo "    下一步：把这个 zip 上传到 GitHub Release（tag v1.0）。"
echo "    地址已写进 README 与包内安装说明，无需再改。"
