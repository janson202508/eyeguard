#!/bin/bash
#
# 把 EyeGuard 和 EyeGuard 控制台安装到 /Applications，
# 之后就能从「启动台 / 聚焦搜索 / 访达」直接打开，不用再进这个目录。
#
# 用法：
#   bash install.sh              构建并安装
#   bash install.sh --no-build   跳过构建，只安装当前已有的产物
#   bash install.sh --uninstall  卸载（同时结束正在运行的实例）
#
# 两个程序的分工：
#   EyeGuard            菜单栏常驻，到点全屏提醒。没有 Dock 图标。
#   EyeGuard 控制台      有窗口的开关面板，负责启动 / 暂停 / 恢复 / 退出 EyeGuard。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EYEGUARD_APP="EyeGuard.app"
LAUNCHER_APP="EyeGuardLauncher.app"

DO_BUILD=1
DO_UNINSTALL=0

for arg in "$@"; do
    case "$arg" in
        --no-build)  DO_BUILD=0 ;;
        --uninstall) DO_UNINSTALL=1 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done

# 目标目录：优先 /Applications；没有写权限就退到 ~/Applications
if [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "!! /Applications 不可写，改装到 $DEST（聚焦搜索同样能找到）"
fi

stop_running() {
    pkill -f "$EYEGUARD_APP/Contents/MacOS/EyeGuard" 2>/dev/null || true
    pkill -f "$LAUNCHER_APP/Contents/MacOS/EyeGuardLauncher" 2>/dev/null || true
    sleep 1
}

if [ "$DO_UNINSTALL" -eq 1 ]; then
    echo "==> 结束正在运行的实例"
    stop_running
    echo "==> 从 $DEST 移除"
    rm -rf "$DEST/$EYEGUARD_APP" "$DEST/$LAUNCHER_APP"
    echo
    echo "已卸载。"
    echo "注意：设置与状态仍保留在 ~/Library/Application Support/EyeGuard/，"
    echo "     需要一并清除请手动删除该目录。"
    exit 0
fi

if [ "$DO_BUILD" -eq 1 ]; then
    echo "==> 构建 EyeGuard"
    bash "$ROOT/EyeGuard/build.sh" release
    echo
    echo "==> 构建 EyeGuard 控制台"
    bash "$ROOT/EyeGuardLauncher/build.sh" release
    echo
fi

for app in "$ROOT/EyeGuard/build/$EYEGUARD_APP" "$ROOT/EyeGuardLauncher/build/$LAUNCHER_APP"; do
    if [ ! -d "$app" ]; then
        echo "!! 找不到构建产物：$app" >&2
        echo "   先跑一次 bash install.sh（不带 --no-build）" >&2
        exit 1
    fi
done

echo "==> 结束正在运行的实例"
stop_running

echo "==> 安装到 $DEST"
rm -rf "$DEST/$EYEGUARD_APP" "$DEST/$LAUNCHER_APP"
cp -R "$ROOT/EyeGuard/build/$EYEGUARD_APP" "$DEST/"
cp -R "$ROOT/EyeGuardLauncher/build/$LAUNCHER_APP" "$DEST/"

# 让聚焦/启动台立刻认得，不用等系统慢慢扫描
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST/$EYEGUARD_APP" "$DEST/$LAUNCHER_APP" 2>/dev/null || true

echo
echo "==> 完成"
echo
echo "现在可以这样用："
echo "  · 打开「$DEST/EyeGuard 控制台.app」—— 一个窗口，一个大开关"
echo "  · 或在聚焦搜索里输入 EyeGuard 直接打开控制台"
echo
echo "控制台里的三个动作："
echo "  启动护眼 / 暂停提醒（可恢复） / 退出护眼"
