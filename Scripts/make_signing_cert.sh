#!/bin/bash
# 生成本机专用的自签名代码签名证书（一次性），让 .app 的辅助功能（TCC）授权在覆盖安装后保持有效。
#
# 为什么需要：系统把辅助功能授权按「代码签名要求（csreq）」记录。
#   - ad-hoc 签名的要求就是二进制 cdhash → 每次重新打包 cdhash 都变，系统设置里的旧条目
#     随即失效，表现就是「列表里还有 ClickToKnow，却显示未授权」；
#   - 用固定证书签名后，要求变成「bundle id + 证书叶子哈希」→ 跨版本稳定，覆盖安装无需重授权。
#
# 用法：
#   ./Scripts/make_signing_cert.sh                 # 创建（已存在则直接跳过，可反复执行）
#   CERT_NAME="XXX" ./Scripts/make_signing_cert.sh # 自定义证书名
set -euo pipefail

CERT_NAME="${CERT_NAME:-ClickToKnow Local Signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
DAYS="${DAYS:-3650}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "签名身份已存在：$CERT_NAME（无需重复创建）"
    exit 0
fi

command -v openssl >/dev/null || { echo "缺少 openssl，无法生成证书" >&2; exit 1; }
[ -f "$KEYCHAIN" ] || { echo "找不到登录钥匙串：$KEYCHAIN" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# 私钥导出密码只用一次，落在临时目录，脚本结束即删
PASS="$(openssl rand -hex 16)"

echo "==> 生成自签名证书：$CERT_NAME（有效期 ${DAYS} 天）"
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -out "$WORK/cert.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASS" >/dev/null 2>&1

echo "==> 导入登录钥匙串（-A 允许 codesign 直接取用，避免每次签名弹密码框）"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -A >/dev/null

echo "==> 添加代码签名信任（可能弹出授权框，输入登录密码并允许）"
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"; then
    cat >&2 <<EOF

自动添加信任失败，手动做一次即可：
  1. 打开「钥匙串访问」→ 左侧「登录」→「证书」分类，找到「$CERT_NAME」
  2. 双击打开 → 展开「信任」→「代码签名」选择「始终信任」→ 关闭窗口并输入登录密码
  3. 重新运行本脚本验证
EOF
    exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "==> 完成：$CERT_NAME 已是有效的代码签名身份"
    echo "    之后 ./Scripts/package.sh 会自动用它签名，覆盖安装不再丢辅助功能授权"
else
    echo "证书已导入但仍是无效身份，请按上面的「钥匙串访问」步骤手动信任后重新运行" >&2
    exit 1
fi
