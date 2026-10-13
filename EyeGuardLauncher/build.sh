#!/bin/bash
#
# 构建「EyeGuard 控制台」并组装成可双击运行的 .app。
#
# 与 EyeGuard 主程序同样的路线：本机只装了 Command Line Tools（没有 Xcode），
# 所以走 SPM 构建 + 手工组装 bundle。区别是本程序是**普通应用**（有 Dock 图标、
# 有窗口），Info.plist 里刻意不写 LSUIElement。
#
# 需要 --disable-sandbox：SPM 默认会对 Package.swift 的求值再套一层 sandbox-exec，
# 与本机外层沙箱嵌套会失败（sandbox_apply: Operation not permitted），
# 表现为 Invalid manifest，极易误判成 Package.swift 写错。
#
# 用法：bash build.sh [debug|release]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="EyeGuardLauncher"
DISPLAY_NAME="EyeGuard 控制台"
BUNDLE_ID="info.xiaolu.eyeguard.launcher"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --disable-sandbox

BIN_PATH="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "!! 找不到可执行文件：$BIN_PATH" >&2
    exit 1
fi

echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> 生成应用图标"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN_PATH" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP_BUNDLE"

echo "==> 完成：$APP_BUNDLE"
