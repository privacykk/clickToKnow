#!/bin/bash
# ClickToKnow 卸载脚本：退出进程 → 删除 .app → 清理配置（UserDefaults）与钥匙串密钥 → 提示手动收尾
#
# 用法：
#   ./Scripts/uninstall.sh              # 标准卸载（保留 ~/.clicktoknow/.env）
#   ./Scripts/uninstall.sh --all        # 连同 ~/.clicktoknow 目录一起删除
#   ./Scripts/uninstall.sh --dry-run    # 只打印将执行的操作，不实际改动
#
# 可用环境变量：
#   APP_NAME    默认 ClickToKnow
#   APP_PATH    显式指定 .app 路径；默认依次探测 /Applications、~/Applications
#
# 注意：macOS 不允许脚本删除 TCC（辅助功能）授权条目，需卸载后手动到
# 「系统设置 → 隐私与安全 → 辅助功能」移除 ClickToKnow 条目。
set -euo pipefail

APP_NAME="${APP_NAME:-ClickToKnow}"
PREFS_SUITE="ClickToKnow"                 # AppConfig 显式 suite（见 AppConfig.swift）
BUNDLE_ID="com.clicktoknow.app"           # 打包默认 bundle id（系统窗口状态等自动写入）
KEYCHAIN_SERVICE="ClickToKnow"            # 钥匙串 service（见 KeychainSecretStore.swift）
ENV_DIR="$HOME/.clicktoknow"              # README 引导用户手动创建的 .env 目录
PURGE_ENV=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --all)     PURGE_ENV=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "未知参数：$arg（支持 --all / --dry-run / --help）" >&2; exit 1 ;;
    esac
done

run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] $*"
    else
        "$@"
    fi
}

# 定位 .app：显式 APP_PATH 优先，否则探测两个常见安装位置
APP="${APP_PATH:-}"
if [ -z "$APP" ]; then
    if [ -d "/Applications/$APP_NAME.app" ]; then
        APP="/Applications/$APP_NAME.app"
    elif [ -d "$HOME/Applications/$APP_NAME.app" ]; then
        APP="$HOME/Applications/$APP_NAME.app"
    fi
fi
# 防呆：只接受以 /<APP_NAME>.app 结尾、且确实是 bundle 的路径，避免误删
if [ -n "$APP" ]; then
    case "$APP" in
        */"$APP_NAME".app) ;;
        *) echo "APP_PATH「${APP}」不符合 …/${APP_NAME}.app 形态，已跳过应用删除" >&2; APP="" ;;
    esac
fi
if [ -n "$APP" ] && [ ! -f "$APP/Contents/Info.plist" ]; then
    echo "「${APP}」不是有效的 .app bundle，已跳过应用删除" >&2
    APP=""
fi

echo "==> 1/5 退出运行中的 $APP_NAME"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] 退出进程 $APP_NAME"
    else
        # 先走 AppleEvent 优雅退出，失败再强制结束
        osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    fi
else
    echo "    未在运行，跳过"
fi

echo "==> 2/5 删除应用本体"
if [ -n "$APP" ]; then
    run rm -rf "$APP"
    echo "    已处理：$APP"
else
    echo "    未找到已安装的 $APP_NAME.app（/Applications 与 ~/Applications 均无），跳过"
fi

echo "==> 3/5 清理 UserDefaults 配置（suite: ${PREFS_SUITE} / ${BUNDLE_ID}）"
run defaults delete "$PREFS_SUITE" >/dev/null 2>&1 || true
run defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> 4/5 删除钥匙串密钥（service: ${KEYCHAIN_SERVICE}）"
if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    run security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || \
        echo "    ⚠️ 钥匙串删除被拒，可在「钥匙串访问」中搜索 ${KEYCHAIN_SERVICE} 手动删除"
else
    echo "    无密钥条目，跳过"
fi

echo "==> 5/5 处理 $ENV_DIR"
if [ -d "$ENV_DIR" ]; then
    if [ "$PURGE_ENV" = "1" ]; then
        run rm -rf "$ENV_DIR"
        echo "    已处理：$ENV_DIR"
    else
        echo "    保留：${ENV_DIR}（含你手动创建的 .env；如需一并删除请加 --all）"
    fi
else
    echo "    不存在，跳过"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "✅ dry-run 结束，未实际改动；去掉 --dry-run 再执行即为真实卸载。"
else
    cat <<EOF

✅ 卸载完成。
还需手动收尾一项：系统设置 → 隐私与安全 → 辅助功能，移除残留的 $APP_NAME 条目
（TCC 授权数据库受 SIP 保护，无法脚本化删除；不删也无害，重装时会重新匹配）。
EOF
fi
