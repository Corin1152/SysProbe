#!/bin/bash
# 从上游 Release 取 ChargeLimiterDaemon，落到 Sources/ChargeControl/Resources/。
#
#   bash scripts/fetch-daemon.sh
#
# ══════════════════════════════════════════════════════════════════════════════
# 为什么不把这个二进制提交进仓库
# ══════════════════════════════════════════════════════════════════════════════
#
# ChargeLimiter 是 **GPL-3.0**，而 SysProbe 是 Apache-2.0 且仓库公开。把一个 GPL
# 作品的可执行文件当作资源提交进去，等于在**分发**它 —— 那会把整个仓库拖进
# copyleft。所以改成「构建时由脚本下载」：
#
#   · 仓库里不含任何 GPL 作品，只含一个下载地址和一段校验值；
#   · 下载这个动作由构建者发起，是构建者在自己机器上装了一个 GPL 程序，
#     与仓库的许可证无关。
#
# 这段逻辑与 `www/`（我们自己重写的前端）不同 —— 那一份是原创的，随包发布没问题。
#
# ══════════════════════════════════════════════════════════════════════════════
# 校验值
# ══════════════════════════════════════════════════════════════════════════════
#
# 上游 release 只提供整包 tipa，没有单独给 daemon 出校验值，所以这里记的是
# **1.7 那个 tipa 里**这个二进制的 sha256。换 VERSION 时必须一起换 ——
# 校验不通过脚本会直接报错退出，不会静默用错版本。
#
# 这个二进制就是「真正停充」的那部分：它以 root 跑，对 IOPMPS 服务写
# ExternalConnected。它的行为已经在一台 iPhone X / iOS 16.5.1 / TrollStore 上
# 验证过，所以宁可钉死版本，也不要跟着上游 main 分支漂。
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.7"
URL="https://github.com/lich4/ChargeLimiter/releases/download/${VERSION}/ChargeLimiter_${VERSION}.tipa"
EXPECTED_SHA256="167e73012df038e5992fbee3d7c2ac005f63a234392c30b5e59082836bef1d9a"

DEST="Sources/ChargeControl/Resources/ChargeLimiterDaemon"

# 已经有、且校验对得上，就不重复下载（CI 每次都是干净环境，这条主要是给本地用的）。
if [ -f "$DEST" ]; then
  if [ "$(shasum -a 256 "$DEST" | cut -d' ' -f1)" = "$EXPECTED_SHA256" ]; then
    echo "==> ChargeLimiterDaemon ${VERSION} already present, skipping download"
    exit 0
  fi
  echo "==> the existing ChargeLimiterDaemon does not match, refetching"
  rm -f "$DEST"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Downloading ChargeLimiter ${VERSION}"
echo "    $URL"
curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$work/cl.tipa" "$URL"

echo "==> Extracting ChargeLimiterDaemon"
unzip -q "$work/cl.tipa" 'Payload/ChargeLimiter.app/ChargeLimiterDaemon' -d "$work"

source_file="$work/Payload/ChargeLimiter.app/ChargeLimiterDaemon"
[ -f "$source_file" ] || { echo "::error::Payload/ChargeLimiter.app/ChargeLimiterDaemon is not in the tipa" >&2; exit 1; }

actual="$(shasum -a 256 "$source_file" | cut -d' ' -f1)"
if [ "$actual" != "$EXPECTED_SHA256" ]; then
  echo "::error::sha256 mismatch for ChargeLimiterDaemon" >&2
  echo "  expected: $EXPECTED_SHA256" >&2
  echo "  actual  : $actual" >&2
  echo "  The upstream release at ${VERSION} changed, or the download was tampered with." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$source_file" "$DEST"
# zip 会保留执行位，装到设备上才能被 posix_spawn 调起来。
chmod 755 "$DEST"

echo "==> ChargeLimiterDaemon ${VERSION} -> $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes, sha256 verified)"
