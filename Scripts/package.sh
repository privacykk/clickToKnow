#!/bin/bash
# ClickToKnow 打包脚本：release 构建 → .app bundle → 代码签名 →（可选公证）→ DMG + zip 双格式分发件
#
# 用法：
#   ./Scripts/package.sh                          # 自动选择：本机有「ClickToKnow Local Signing」就用它，
#                                                 # 否则回退 ad-hoc（无需开发者账号，本地/内部分发）
#   SIGN_IDENTITY="Developer ID Application: 姓名 (TEAMID)" NOTARIZE=1 ./Scripts/package.sh
#                                                 # 正式分发：Developer ID + hardened runtime + 公证 + 装订
#
# 辅助功能授权与签名：系统按「代码签名要求」记录 TCC 授权，ad-hoc 的要求就是二进制 cdhash，
# 每次重新打包都会让列表里的旧授权失效（表现为「列表里有、却显示未授权」）。
# 一次性执行 ./Scripts/make_signing_cert.sh 生成固定证书后，覆盖安装不再丢授权。
#
# 可用环境变量：
#   APP_NAME        默认 ClickToKnow
#   BUNDLE_ID       默认 com.clicktoknow.app
#   VERSION         默认 0.2.1（写入 Info.plist，状态页「版本」读取同一来源）
#   BUILD_NUMBER    默认 1
#   APPEND_TIMESTAMP 默认 1；置 1 则把 TIMESTAMP 追加到 VERSION（如 0.2.1-20261120-163725），
#                   使每次构建的 zip/dmg/Info.plist 版本号互不覆盖；置 0 关闭
#   TIMESTAMP       默认当前时间（date +%Y%m%d-%H%M%S）；可显式指定以固定时间戳
#   SIGN_IDENTITY   未设置时自动探测本机稳定签名身份，找不到才用 "-"（ad-hoc）；
#                   正式签名填 "Developer ID Application: ... (TEAMID)"
#   NOTARIZE        默认 0；置 1 走 notarytool 公证 + stapler 装订（需先 store-credentials）
#   NOTARY_PROFILE  notarytool 钥匙串配置档名，默认 notarytool
#   SWIFT_BUILD_ARGS  追加给 swift build 的参数（如 SwiftPM 缓存路径重定向）
#   ARCHS           默认 "arm64 x86_64"（universal binary，lipo 合并）；
#                   只出单架构可设 ARCHS=arm64（构建更快、产物更小）
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-ClickToKnow}"
BUNDLE_ID="${BUNDLE_ID:-com.clicktoknow.app}"
VERSION="${VERSION:-0.2.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# 时间戳：默认追加到 VERSION，写入 Info.plist 的 CFBundleShortVersionString，
# 并体现在 zip/dmg 分发件名，使每次构建产物互不覆盖。
# APPEND_TIMESTAMP=0 关闭；TIMESTAMP 可显式指定以固定时间戳。
APPEND_TIMESTAMP="${APPEND_TIMESTAMP:-1}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
if [ "$APPEND_TIMESTAMP" = "1" ]; then
    VERSION="$VERSION-$TIMESTAMP"
fi
# 本机固定签名身份（Scripts/make_signing_cert.sh 创建）：用它签名后 TCC 授权要求变成
# 「bundle id + 证书叶子哈希」，覆盖安装不再失效；未显式指定签名身份时优先自动采用
LOCAL_SIGN_IDENTITY="ClickToKnow Local Signing"
SIGN_IDENTITY_WAS_SET="${SIGN_IDENTITY:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ -z "$SIGN_IDENTITY_WAS_SET" ] && security find-identity -v -p codesigning 2>/dev/null \
        | grep -qF "$LOCAL_SIGN_IDENTITY"; then
    SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
fi
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# 打包涉及签名/公证工具，优先使用完整 Xcode 工具链；
# 本机 CommandLineTools 存在 SDK 版本错配问题时也能正常工作
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCHS="${ARCHS:-arm64 x86_64}"

echo "==> 1/6 release 构建（archs: ${ARCHS}）"
# shellcheck disable=SC2086
if [ "$(echo "$ARCHS" | wc -w | tr -d ' ')" = "1" ]; then
    # 单架构：直接构建，产物在 .build/release/
    swift build -c release --arch "$ARCHS" ${SWIFT_BUILD_ARGS:-}
    BIN=".build/release/$APP_NAME"
else
    # 多架构：逐架构构建后用 lipo 合并为 universal binary
    # （每个架构的 .build/release 产物会被下一次构建覆盖，先移开收集）
    SLICES=()
    for ARCH in $ARCHS; do
        # shellcheck disable=SC2086
        swift build -c release --arch "$ARCH" ${SWIFT_BUILD_ARGS:-}
        SLICE=".build/release/$APP_NAME-$ARCH"
        mv ".build/release/$APP_NAME" "$SLICE"
        SLICES+=("$SLICE")
    done
    BIN=".build/release/$APP_NAME"
    lipo -create -output "$BIN" "${SLICES[@]}"
    rm -f "${SLICES[@]}"
    echo "    universal binary 架构：$(lipo -archs "$BIN")"
fi
[ -f "$BIN" ] || { echo "未找到构建产物 $BIN" >&2; exit 1; }

echo "==> 2/6 组装 .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__APP_NAME__/$APP_NAME/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    Packaging/Info.plist.template > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 图标：仓库未提交 AppIcon.icns 时程序化生成一次（失败不阻断打包，仅无自定义图标）
if [ ! -f Packaging/AppIcon.icns ]; then
    echo "    生成应用图标…"
    swift Scripts/make_icon.swift Packaging/AppIcon.icns \
        || echo "    图标生成失败，使用系统默认图标" >&2
fi
if [ -f Packaging/AppIcon.icns ]; then
    cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 3/6 代码签名（identity: ${SIGN_IDENTITY}）"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ] && [ "$SIGN_IDENTITY" != "$LOCAL_SIGN_IDENTITY" ]; then
    # 正式分发：hardened runtime + 安全时间戳（公证硬性要求）
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --verbose=2 "$APP"

if [ "$NOTARIZE" = "1" ]; then
    [ "$SIGN_IDENTITY" != "-" ] || { echo "NOTARIZE=1 需要 Developer ID 签名身份" >&2; exit 1; }
    echo "==> 3.5 公证（notarytool profile: $NOTARY_PROFILE）"
    NOTARY_ZIP="$DIST/notary-upload.zip"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$NOTARY_ZIP"
    xcrun stapler staple "$APP"
    spctl -a -vvv -t install "$APP" || true
fi

echo "==> 4/6 打包 zip"
mkdir -p "$DIST"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
# ditto 而非 zip：保留签名所需的扩展属性与资源叉
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 5/6 生成 DMG（拖入 Applications 安装布局）"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGING="$DIST/dmg-staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"   # 打开 dmg 即见「App → Applications」拖拽布局
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
hdiutil verify "$DMG" >/dev/null && echo "    DMG 校验通过"

if [ "$SIGN_IDENTITY" != "-" ] && [ "$SIGN_IDENTITY" != "$LOCAL_SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = "1" ]; then
    # 此时 .app 已装订票据（3.5 步），DMG 再单独公证并装订，离线首启也免检
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG" || true
fi

echo "==> 6/6 完成"
echo "    应用：$APP"
echo "    分发件：$DMG"
echo "            $ZIP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    cat <<'EOF'
    ⚠️ 使用 ad-hoc 签名：
      1) 未经过公证，用户首次打开会被 Gatekeeper 拦截：
         系统设置 → 隐私与安全性 → 「仍要打开」（旧系统可右键 App → 打开），
         或终端执行：xattr -dr com.apple.quarantine /Applications/ClickToKnow.app
      2) 辅助功能授权按二进制 cdhash 记录，每次覆盖安装都会失效
         （系统设置里条目还在，却显示未授权）。一次性修复：
         ./Scripts/make_signing_cert.sh 生成固定签名身份后重新打包。
EOF
elif [ "$SIGN_IDENTITY" = "$LOCAL_SIGN_IDENTITY" ]; then
    cat <<EOF
    已使用本机固定签名身份「$SIGN_IDENTITY」：覆盖安装后辅助功能授权仍然有效。
    该证书只在本机受信任，分发给他人仍需「仍要打开」放行（或改用 Developer ID 公证分发）。
EOF
fi
