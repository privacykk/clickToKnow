#!/bin/bash
# ClickToKnow 卸载脚本
#
# 顺序有讲究：钥匙串条目必须在删除 .app 之前处理（条目的访问控制只信任原应用），
# 所以钥匙串清理排在删应用之前：
#   1) 定位 .app → 2) 退出进程 → 3) 删钥匙串密钥 → 4) 清 UserDefaults
#   → 5) 处理自启/登录项 → 6) 删 .app → 7) 处理生词本与 .env → 8) 残留清单
#
# 用法：
#   ./Scripts/uninstall.sh            # 默认：卸载应用与凭据，保留生词本与 ~/.clicktoknow
#   ./Scripts/uninstall.sh --purge     # 彻底卸载：额外删除 history.json（含整个数据目录）与 ~/.clicktoknow
#   ./Scripts/uninstall.sh --dry-run   # 预演：逐条打印将执行的操作（含钥匙串目标账号），零副作用
#   ./Scripts/uninstall.sh --help      # 显示本帮助
#
#   --all 是 --purge 的旧名，继续支持。
#
# 可用环境变量（默认值与 Sources 里的常量一一对应）：
#   APP_NAME          默认 ClickToKnow
#   APP_PATH          显式指定 .app 路径；默认依次探测 /Applications、~/Applications
#   BUNDLE_ID         默认 com.clicktoknow.app（Scripts/package.sh 允许打包时覆盖，卸载需与安装时一致）
#   PREFS_SUITE       默认 ClickToKnow（AppConfig.swift 显式 suite）
#   KEYCHAIN_SERVICE  默认 ClickToKnow（KeychainSecretStore.swift）
#
# 无法脚本化的残留（脚本会明确列出，不会假装清理干净）：
#   辅助功能 TCC 授权条目、SMAppService 开机自启注册（无公开 CLI，sfltool dumpbtm 需 root）。
set -euo pipefail

APP_NAME="${APP_NAME:-ClickToKnow}"
PREFS_SUITE="${PREFS_SUITE:-ClickToKnow}"
BUNDLE_ID="${BUNDLE_ID:-com.clicktoknow.app}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-ClickToKnow}"
PREFS_KEY="apiProfiles"                                      # AppConfig.Key.apiProfiles
LEGACY_KEYCHAIN_ACCOUNT="apiKey"                             # AppConfig.legacyKeychainAccount
ENV_DIR="$HOME/.clicktoknow"                                 # EnvLoader 读取的 .env 目录
SUPPORT_DIR="$HOME/Library/Application Support/ClickToKnow"  # HistoryStore 的数据目录
HISTORY_FILE="$SUPPORT_DIR/history.json"                     # HistoryStore 的生词本文件

PURGE=0
DRY_RUN=0

usage() {
    cat <<'EOF'
ClickToKnow 卸载脚本

用法：
  ./Scripts/uninstall.sh            默认：卸载应用与凭据，保留生词本与 ~/.clicktoknow
  ./Scripts/uninstall.sh --purge    彻底卸载：额外删除 history.json 与 ~/.clicktoknow
  ./Scripts/uninstall.sh --dry-run  预演：只打印将要执行的操作，不产生任何改动
  ./Scripts/uninstall.sh --help     显示本帮助

  --all 等同于 --purge（旧名，保留兼容）。

可用环境变量：APP_NAME / APP_PATH / BUNDLE_ID / PREFS_SUITE / KEYCHAIN_SERVICE
EOF
}

for arg in "$@"; do
    case "$arg" in
        --purge|--all) PURGE=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "未知参数：${arg}（支持 --purge / --all / --dry-run / --help）" >&2; exit 1 ;;
    esac
done

# ---------- 小工具 ----------

say()  { echo "==> $*"; }
note() { echo "    $*"; }
warn() { echo "    ⚠️  $*"; }

# dry-run 下只打印命令行本身（用 %q 让带空格/特殊字符的参数一眼看清）
print_cmd() {
    printf '    [dry-run]'
    printf ' %q' "$@"
    printf '\n'
}

# 破坏性操作统一走 run / run_quiet：dry-run 只打印，绝不执行
run() {
    if [ "$DRY_RUN" = "1" ]; then print_cmd "$@"; return 0; fi
    "$@"
}

run_quiet() {
    if [ "$DRY_RUN" = "1" ]; then print_cmd "$@"; return 0; fi
    "$@" >/dev/null 2>&1
}

# 需要手动处理的残留项，最后统一打印
RESIDUALS=()
add_residual() { RESIDUALS[${#RESIDUALS[@]}]="$1"; }

if [ "$DRY_RUN" = "1" ]; then
    echo "== 预演模式（--dry-run）：不会调用 security 写操作、不会 delete defaults、不会删除任何文件"
    echo
else
    echo "== 开始卸载 ${APP_NAME}（默认保留生词本与 .env；加 --purge 才彻底删除）"
    echo
fi

# ---------- 1/8 定位 .app ----------

say "1/8 定位应用本体"
APP="${APP_PATH:-}"
if [ -z "$APP" ]; then
    for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
        if [ -d "$candidate" ]; then APP="$candidate"; break; fi
    done
fi
# 防呆：只接受以 /<APP_NAME>.app 结尾、且确实是 bundle 的路径，避免误删
if [ -n "$APP" ]; then
    case "$APP" in
        */"$APP_NAME".app) ;;
        *) warn "APP_PATH「${APP}」不符合 …/${APP_NAME}.app 形态，已跳过应用删除"; APP="" ;;
    esac
fi
if [ -n "$APP" ] && [ ! -f "$APP/Contents/Info.plist" ]; then
    warn "「${APP}」不是有效的 .app bundle，已跳过应用删除"
    APP=""
fi
if [ -n "$APP" ]; then
    note "目标：$APP"
else
    note "未找到 $APP_NAME.app（/Applications 与 ~/Applications 均无）"
fi

# ---------- 2/8 退出进程 ----------

say "2/8 退出运行中的 $APP_NAME"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
        print_cmd osascript -e "tell application \"$APP_NAME\" to quit"
        print_cmd pkill -x "$APP_NAME"
    else
        # 先走 AppleEvent 优雅退出，失败再强制结束
        osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$APP_NAME" >/dev/null 2>&1 || true
        note "已请求退出进程"
    fi
else
    note "未在运行，跳过"
fi

# ---------- 3/8 钥匙串（必须早于删 .app） ----------

say "3/8 清理钥匙串密钥（service: ${KEYCHAIN_SERVICE}）"

KEYCHAIN_TARGETS=()
KEYCHAIN_ENUM_NOTE=""

# 从 UserDefaults 导出的 plist 里取 apiProfiles（JSON Data，plist 里是 base64），
# 解析出每个配置的 id，拼成钥匙串 account「profile-<uuid>」。
# 只读操作（defaults export 不写入），dry-run 也执行，以便打印目标账号。
collect_keychain_targets() {
    KEYCHAIN_TARGETS=()
    KEYCHAIN_ENUM_NOTE=""
    local plist_b64 json ids id
    if ! command -v plutil >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        KEYCHAIN_ENUM_NOTE="系统缺少 plutil/base64，无法从配置枚举钥匙串账号（仍会清理遗留账号）"
        return 0
    fi
    if ! command -v defaults >/dev/null 2>&1; then
        KEYCHAIN_ENUM_NOTE="系统缺少 defaults 命令，无法从配置枚举钥匙串账号（仍会清理遗留账号）"
        return 0
    fi
    if ! plist_b64="$(defaults export "$PREFS_SUITE" - 2>/dev/null \
            | plutil -extract "$PREFS_KEY" raw -o - - 2>/dev/null)"; then
        KEYCHAIN_ENUM_NOTE="配置里没有 ${PREFS_KEY}（从未配置过或已被清空），没有按配置保存的密钥账号"
        return 0
    fi
    if ! json="$(printf '%s' "$plist_b64" | base64 -D 2>/dev/null)"; then
        KEYCHAIN_ENUM_NOTE="${PREFS_KEY} 的数据无法经 base64 解码，跳过按配置枚举"
        return 0
    fi
    ids="$(printf '%s' "$json" \
        | grep -Eo '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/' \
        | sort -u || true)"
    if [ -z "$ids" ]; then
        KEYCHAIN_ENUM_NOTE="${PREFS_KEY} 为空，没有按配置保存的密钥账号"
        return 0
    fi
    while IFS= read -r id; do
        if [ -n "$id" ]; then
            KEYCHAIN_TARGETS[${#KEYCHAIN_TARGETS[@]}]="profile-${id}"
        fi
    done <<< "$ids"
}

KEYCHAIN_FAILED=0

# 删除单个 account：先查、再删、删后复验（多条目时循环删到查不到为止）
delete_keychain_account() {
    local account="$1"
    local attempt=0
    local max_attempts=5
    if [ "$DRY_RUN" = "1" ]; then
        print_cmd security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account"
        note "    （随后复验：security find-generic-password -s ${KEYCHAIN_SERVICE} -a ${account} 必须返回「找不到条目」）"
        return 0
    fi
    # security 的退出码 44 = errSecItemNotFound（确实没有该条目）；其它非零说明查询本身被拒，
    # 不能当成「本来就没有」，否则会漏报删不掉的条目。
    local find_status=0
    security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1 || find_status=$?
    if [ "$find_status" -eq 44 ]; then
        note "无条目，跳过：-a ${account}"
        return 0
    fi
    if [ "$find_status" -ne 0 ]; then
        warn "无法查询该条目（security 退出码 ${find_status}，通常是系统授权被拒）：-a ${account}"
        return 1
    fi
    while [ "$attempt" -lt "$max_attempts" ]; do
        if ! security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1; then
            break
        fi
        attempt=$((attempt + 1))
        if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1; then
            note "已删除并复验：-s ${KEYCHAIN_SERVICE} -a ${account}"
            return 0
        fi
    done
    warn "删除失败或复验仍存在：-s ${KEYCHAIN_SERVICE} -a ${account}"
    warn "可打开「钥匙串访问」搜索 ${KEYCHAIN_SERVICE} 手动删除该条目"
    return 1
}

if ! command -v security >/dev/null 2>&1; then
    warn "系统缺少 security 命令，跳过钥匙串清理"
    add_residual "钥匙串：未清理 service=${KEYCHAIN_SERVICE} 下的条目（本机缺少 security 命令），请用「钥匙串访问」手动删除"
else
    collect_keychain_targets
    if [ -n "$KEYCHAIN_ENUM_NOTE" ]; then
        note "$KEYCHAIN_ENUM_NOTE"
    fi
    if [ "${#KEYCHAIN_TARGETS[@]}" -gt 0 ]; then
        note "从配置解析出 ${#KEYCHAIN_TARGETS[@]} 个按配置的账号，逐个删除并复验："
        for account in "${KEYCHAIN_TARGETS[@]}"; do note "    - ${account}"; done
        for account in "${KEYCHAIN_TARGETS[@]}"; do
            delete_keychain_account "$account" || KEYCHAIN_FAILED=$((KEYCHAIN_FAILED + 1))
        done
    fi
    note "再清理单配置时代的遗留账号：${LEGACY_KEYCHAIN_ACCOUNT}"
    delete_keychain_account "$LEGACY_KEYCHAIN_ACCOUNT" || KEYCHAIN_FAILED=$((KEYCHAIN_FAILED + 1))
    if [ "$DRY_RUN" = "1" ]; then
        note "（dry-run：跳过 service 剩余条目复验，不访问钥匙串）"
    else
        svc_status=0
        security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || svc_status=$?
        if [ "$svc_status" -eq 44 ]; then
            note "复验通过：service ${KEYCHAIN_SERVICE} 下已无条目"
        elif [ "$svc_status" -eq 0 ]; then
            warn "service ${KEYCHAIN_SERVICE} 下仍有未识别的条目（可能是历史遗留账号）"
            add_residual "钥匙串：service=${KEYCHAIN_SERVICE} 下仍有未识别条目，请在「钥匙串访问」搜索 ${KEYCHAIN_SERVICE} 手动删除"
        else
            warn "无法复验 service ${KEYCHAIN_SERVICE}（security 退出码 ${svc_status}，通常是被拒绝授权）"
            add_residual "钥匙串：无法复验 service=${KEYCHAIN_SERVICE} 是否清理干净（security 退出码 ${svc_status}），请在「钥匙串访问」搜索 ${KEYCHAIN_SERVICE} 核对"
        fi
    fi
    if [ "$KEYCHAIN_FAILED" -gt 0 ]; then
        add_residual "钥匙串：${KEYCHAIN_FAILED} 个条目删除失败（多为系统授权弹窗被拒），请在「钥匙串访问」搜索 ${KEYCHAIN_SERVICE} 手动删除"
    fi
fi

# ---------- 4/8 UserDefaults ----------

say "4/8 清理 UserDefaults 配置（suite: ${PREFS_SUITE} / ${BUNDLE_ID}）"
run_quiet defaults delete "$PREFS_SUITE" || true
run_quiet defaults delete "$BUNDLE_ID" || true
if [ "$DRY_RUN" = "1" ]; then
    note "（dry-run：以上两条 defaults delete 不会执行）"
else
    note "已尝试删除两个 domain（不存在时系统会报错，已忽略）"
fi

# ---------- 5/8 自启 / 登录项 ----------

say "5/8 处理开机自启与登录项残留"
LAUNCH_AGENT_COUNT=0
if [ -d "$HOME/Library/LaunchAgents" ]; then
    for plist in "$HOME/Library/LaunchAgents"/*; do
        [ -e "$plist" ] || continue
        case "$(basename "$plist")" in
            *[Cc]lick[Tt]o[Kk]now*) ;;
            *) continue ;;
        esac
        LAUNCH_AGENT_COUNT=$((LAUNCH_AGENT_COUNT + 1))
        if [ "$DRY_RUN" = "1" ]; then
            print_cmd launchctl bootout "gui/$UID" "$plist"
            print_cmd rm -f "$plist"
        else
            launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
            rm -f "$plist"
            note "已移除传统 LaunchAgent：$plist"
        fi
    done
fi
if [ "$LAUNCH_AGENT_COUNT" = "0" ]; then
    note "未发现传统 LaunchAgent（本应用用 SMAppService.mainApp，不写 plist）"
fi
note "SMAppService 注册项没有公开 CLI 可查询或注销（sfltool dumpbtm 需 root），无法自动处理"
note "最干净的做法：卸载前先在 App 菜单里取消勾选「开机自启」；否则请见文末手动清单"
add_residual "登录项：系统设置 → 通用 → 登录项与扩展 → 若有 ClickToKnow（或显示为未知/已删除应用）条目，点「−」移除"

# ---------- 6/8 删 .app ----------

say "6/8 删除应用本体"
if [ -n "$APP" ]; then
    run rm -rf "$APP"
    if [ "$DRY_RUN" = "1" ]; then
        note "（dry-run：以上路径不会被删除）"
    else
        note "已处理：$APP"
    fi
else
    note "未找到已安装的 ${APP_NAME}.app（/Applications 与 ~/Applications 均无），跳过"
    add_residual "应用本体未找到：若装在其他位置，请设置 APP_PATH 重跑脚本或手动删除"
fi

# ---------- 7/8 用户数据（生词本 / .env） ----------

say "7/8 处理用户数据（生词本 / .env）"
if [ -e "$SUPPORT_DIR" ]; then
    if [ "$PURGE" = "1" ]; then
        run rm -rf "$SUPPORT_DIR"
        if [ "$DRY_RUN" = "1" ]; then
            note "彻底卸载：将删除 ${SUPPORT_DIR}（含生词本 ${HISTORY_FILE}）"
        else
            note "彻底卸载：已处理 ${SUPPORT_DIR}（含生词本 ${HISTORY_FILE}）"
        fi
    else
        note "保留：${SUPPORT_DIR}"
        note "      └ 生词本文件 ${HISTORY_FILE} 未删除（默认保留数据；如需一并删除请加 --purge）"
    fi
else
    note "无 ${SUPPORT_DIR}，跳过"
fi

if [ -d "$ENV_DIR" ]; then
    if [ "$PURGE" = "1" ]; then
        run rm -rf "$ENV_DIR"
        if [ "$DRY_RUN" = "1" ]; then
            note "彻底卸载：将删除 ${ENV_DIR}（含手动创建的 .env）"
        else
            note "彻底卸载：已处理 ${ENV_DIR}（含手动创建的 .env）"
        fi
    else
        note "保留：${ENV_DIR}（含手动创建的 .env；如需一并删除请加 --purge）"
    fi
else
    note "无 ${ENV_DIR}，跳过"
fi

# ---------- 8/8 收尾 ----------

say "8/8 收尾"
add_residual "辅助功能授权：系统设置 → 隐私与安全 → 辅助功能，移除残留的 ${APP_NAME} 条目（TCC 数据库受 SIP 保护，无法脚本化删除；不删也无害，重装时会重新匹配）"

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "✅ dry-run 结束：以上操作一个都没有执行（未调用 security 写操作、未执行 defaults delete、未删除任何文件）。"
    echo "   去掉 --dry-run 再执行即为真实卸载。"
else
    echo
    echo "✅ 自动清理完成。"
fi

echo
echo "-- 自动清理范围 --"
DEL_VERB="删除"
if [ "$DRY_RUN" = "1" ]; then DEL_VERB="将删除"; fi
echo "   ${DEL_VERB}：应用本体 ${APP:-（未找到）}"
echo "   ${DEL_VERB}：UserDefaults domain ${PREFS_SUITE} / ${BUNDLE_ID}"
echo "   ${DEL_VERB}：钥匙串 service ${KEYCHAIN_SERVICE} 下按配置账号与遗留账号 ${LEGACY_KEYCHAIN_ACCOUNT} 的条目"
if [ "$PURGE" = "1" ]; then
    echo "   ${DEL_VERB}：${SUPPORT_DIR}（生词本 history.json）与 ${ENV_DIR}"
else
    echo "   保留：${SUPPORT_DIR}（生词本 history.json）与 ${ENV_DIR}"
fi

if [ "${#RESIDUALS[@]}" -gt 0 ]; then
    echo
    echo "-- 仍需你手动处理（脚本无法安全代劳） --"
    i=0
    while [ "$i" -lt "${#RESIDUALS[@]}" ]; do
        echo "   $((i + 1)). ${RESIDUALS[$i]}"
        i=$((i + 1))
    done
fi

exit 0