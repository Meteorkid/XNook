#!/bin/bash
# 创建（或复用）一个稳定的本地代码签名身份。
#
# 为什么需要：ad-hoc 签名（codesign -s -）的 designated requirement 是 cdhash，
# 每次重新构建 cdhash 都会变，macOS 就把它当成另一个应用——系统设置里的开关还是
# 打开的，但授权对新的二进制已经失效，于是出现「明明授权了却仍显示未授权」。
# 用固定证书签名后，requirement 变成 identifier + certificate leaf，跨构建稳定，
# TCC 授权就能沿用到后续版本。
#
# 用法：scripts/setup-signing-identity.sh
# 之后 build-app.sh 会自动发现这个身份并使用它（可用 XNOOK_SIGN_ADHOC=1 强制 ad-hoc）。

set -euo pipefail

IDENTITY="${XNOOK_SIGN_IDENTITY:-XNook Local Signing}"
KEYCHAIN="${XNOOK_SIGN_KEYCHAIN:-$HOME/Library/Keychains/xnook-signing.keychain-db}"
PASSWORD_FILE="${XNOOK_SIGN_PASSWORD_FILE:-$HOME/.xnook-signing/password}"

mkdir -p "$(dirname "$PASSWORD_FILE")"
chmod 700 "$(dirname "$PASSWORD_FILE")"

if [[ ! -f "$PASSWORD_FILE" ]]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
fi
PASSWORD="$(cat "$PASSWORD_FILE")"

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "==> 创建签名钥匙串：$KEYCHAIN"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
# 解锁 6 小时足够一次构建；不设置自动锁定以免长构建中途失败。
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$IDENTITY"; then
    echo "==> 已存在签名身份：$IDENTITY"
else
    echo "==> 生成自签名代码签名证书：$IDENTITY"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -subj "/CN=$IDENTITY" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false" 2>/dev/null

    # macOS 的 security 读不了 OpenSSL 3 的默认 PKCS#12 参数，必须用旧算法。
    if ! openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/id.p12" -passout "pass:$PASSWORD" -name "$IDENTITY" -legacy 2>/dev/null; then
        openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/id.p12" -passout "pass:$PASSWORD" -name "$IDENTITY" \
            -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
    fi

    security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    # 允许 codesign 在非交互构建里直接使用私钥，否则会弹「codesign 想使用钥匙串」。
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

echo
echo "签名身份就绪："
security find-identity -p codesigning "$KEYCHAIN"
echo
echo "下一步：直接运行 ./build-app.sh，脚本会自动使用该身份。"
echo "撤销：security delete-keychain \"$KEYCHAIN\""
