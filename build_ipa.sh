#!/bin/bash
# 一键构建 + 打包 AI 逆向助手 .ipa（需在 macOS 上运行，Xcode 16+）
set -e

cd "$(dirname "$0")"

echo "==> 构建 (Release)..."
xcodebuild -project AIReverse.xcodeproj -scheme AIReverse \
  -configuration Release -derivedDataPath build \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

APP=build/Build/Products/Release-iphoneos/AIReverse.app
if [ ! -d "$APP" ]; then
  echo "错误：找不到构建产物 $APP" >&2
  exit 1
fi

echo "==> 嵌入 entitlements（root + 无沙盒，TrollStore 安装保留）..."
ENTITLEMENTS=AIReverse/AIReverse.entitlements
if [ -f "$ENTITLEMENTS" ]; then
  BINARY="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"
  echo "已对 $BINARY 应用 entitlements"
else
  echo "警告：未找到 $ENTITLEMENTS，跳过签名"
fi

echo "==> 打包 Payload..."
rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/

echo "==> 生成 AIReverse.ipa ..."
ditto -c -k --keepParent build/Payload build/AIReverse.ipa
echo "完成: $(pwd)/build/AIReverse.ipa"
echo "用 TrollStore 打开该 .ipa 即可安装。"
