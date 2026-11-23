#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "未找到 swift，请先安装 Xcode 或 Command Line Tools（xcode-select --install）。" >&2
  exit 1
fi

CONFIG="release"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP_DIR="build/WebWallpaper.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/WebWallpaper" "$APP_DIR/Contents/MacOS/WebWallpaper"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>WebWallpaper</string>
    <key>CFBundleIdentifier</key>
    <string>local.webwallpaper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>网页壁纸</string>
    <key>CFBundleDisplayName</key>
    <string>网页壁纸</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSCameraUsageDescription</key>
    <string>网页壁纸中的网页请求使用摄像头时需要此权限。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>网页壁纸中的网页请求使用麦克风时需要此权限。</string>
    <key>NSLocationUsageDescription</key>
    <string>网页壁纸中的网页请求获取位置信息时需要此权限。</string>
</dict>
</plist>
PLIST

# 本机自用，使用 ad-hoc 签名即可
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "提示：ad-hoc 签名失败，不影响本机运行。"

echo "构建完成：$(pwd)/$APP_DIR"
