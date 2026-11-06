#!/bin/bash
# 发布门禁:确认「要发出去的那个包」就是用当前提交打的。
#
# 用法:
#   bash scripts/release-check.sh [版本号]      # 省略版本号时取 build/ 下最新的 full.zip
#
# 为什么需要它:1.8.8-dev 发布过一次实测事故 —— 包在 02:25 打好,02:59 和 03:16
# 又合进两个修复,但没人重新打包。GitHub 上 Latest 一直是 02:25 那个包,用户下载
# 装完症状分毫未变,而我们的自检脚本还把「应该是什么版本」写死成 02:59 的哈希,
# 于是升级成功的人也被判成「版本不符」。三处各差一个提交,谁也说不清谁是对的。
#
# 所以这里只认一条:**包里的核心脚本哈希必须等于 HEAD 的核心脚本哈希**。
# 其余检查都是为了在发不出去之前把话说清楚,而不是靠人记。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAILS=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
note() { printf '       %s\n' "$*"; }

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    LATEST=$(ls -t build/ClaudeSwitcher-*-macos-*-full.zip 2>/dev/null | head -1)
    [ -n "$LATEST" ] || { echo "FAIL: build/ 下没有 full.zip,先跑 bash scripts/package-macos.sh <版本号>" >&2; exit 1; }
    VERSION=$(basename "$LATEST" | sed -E 's/^ClaudeSwitcher-(.+)-macos-[^-]+-full\.zip$/\1/')
fi

ARCH_LABEL="$(uname -m)"
FULL="build/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-full.zip"
KIT="build/ClaudeSwitcher-$VERSION-installer-kit.zip"
APP_BUNDLE="build/Claude 环境检查器.app"

echo "==> 发布门禁 v$VERSION ($ARCH_LABEL)"
echo ""

# ---- 1. 源码清单自洽 ----
echo "[1] 源码 SHA256SUMS"
if shasum -a 256 -c SHA256SUMS >/dev/null 2>&1; then
    ok "仓库 SHA256SUMS 与工作树一致"
else
    bad "仓库 SHA256SUMS 与工作树不一致,先跑 scripts/gen-sums.sh"
    shasum -a 256 -c SHA256SUMS 2>&1 | grep -v ': OK$' | head -5 | while read -r line; do note "$line"; done
fi

HEAD_CORE=$(git show HEAD:core/claude-switch.sh 2>/dev/null | shasum -a 256 | awk '{print $1}')
SUMS_CORE=$(awk '$2=="core/claude-switch.sh" {print $1; exit}' SHA256SUMS)
if [ -z "$HEAD_CORE" ]; then
    bad "取不到 HEAD 的核心脚本(不在 git 仓库里?)"
elif [ "$HEAD_CORE" = "$SUMS_CORE" ]; then
    ok "SHA256SUMS 的核心哈希 = HEAD (${HEAD_CORE:0:12}…)"
else
    bad "SHA256SUMS 的核心哈希 ≠ HEAD"
    note "清单 ${SUMS_CORE:0:12}… / HEAD ${HEAD_CORE:0:12}… —— 改了 core 但没跑 gen-sums.sh"
fi

# ---- 2. 产物存在 ----
echo ""
echo "[2] 构建产物"
MISSING=0
for f in "$FULL" "$KIT" "$APP_BUNDLE/Contents/MacOS/ClaudeSwitcher"; do
    if [ -e "$f" ]; then ok "$f"; else bad "缺少 $f"; MISSING=1; fi
done
# 只有产物缺失才提前退出;别让 [1] 的失败连带跳过所有内容检查,
# 那样一次只报一个问题,用户得来回跑。
if [ "$MISSING" -gt 0 ]; then echo ""; echo "✗ 产物不全,后续检查跳过"; exit 1; fi

# zip 里取某个后缀对应的完整条目名(包内有一个顶层目录)
entry_for() {
    unzip -Z1 "$1" 2>/dev/null | awk -v suf="$2" 'index($0, suf) && substr($0, length($0)-length(suf)+1) == suf {print; exit}'
}
entry_hash() {
    local zip="$1" suffix="$2" name
    name=$(entry_for "$zip" "$suffix")
    [ -n "$name" ] || return 1
    unzip -p "$zip" "$name" 2>/dev/null | shasum -a 256 | awk '{print $1}'
}
entry_text() {
    local zip="$1" suffix="$2" name
    name=$(entry_for "$zip" "$suffix")
    [ -n "$name" ] || return 1
    unzip -p "$zip" "$name" 2>/dev/null
}

# ---- 3. 包里的核心必须等于 HEAD(这条是本次事故的根因) ----
echo ""
echo "[3] 包内核心脚本 = HEAD"
for pair in "full:$FULL" "kit:$KIT"; do
    label="${pair%%:*}"; zip="${pair#*:}"
    GOT=$(entry_hash "$zip" "/core/claude-switch.sh")
    if [ -z "$GOT" ]; then
        bad "$label 包里找不到 core/claude-switch.sh"
    elif [ "$GOT" = "$HEAD_CORE" ]; then
        ok "$label 核心 ${GOT:0:12}… = HEAD"
    else
        bad "$label 核心 ${GOT:0:12}… ≠ HEAD ${HEAD_CORE:0:12}…"
        note "这个包不是用当前提交打的:发布出去,本次修复对下载的人完全无效"
    fi
done

# 两个包之间也不能各说各话
FULL_CORE=$(entry_hash "$FULL" "/core/claude-switch.sh")
KIT_CORE=$(entry_hash "$KIT" "/core/claude-switch.sh")
if [ -n "$FULL_CORE" ] && [ "$FULL_CORE" = "$KIT_CORE" ]; then
    ok "full 包与 kit 包核心一致"
else
    bad "full 包与 kit 包的核心不一致"
fi

# ---- 4. App 版本与图标 ----
echo ""
echo "[4] 随包 App"
PLIST="$APP_BUNDLE/Contents/Info.plist"
APPVER=$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null)
if [ "$APPVER" = "$VERSION" ]; then
    ok "Info.plist 版本 = $VERSION"
else
    bad "Info.plist 版本 = ${APPVER:-读不到},期望 $VERSION"
fi
if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    ICNS_BYTES=$(wc -c < "$APP_BUNDLE/Contents/Resources/AppIcon.icns" | tr -d ' ')
    if [ "$ICNS_BYTES" -gt 10000 ]; then
        ok "图标资源 ${ICNS_BYTES} 字节"
    else
        bad "图标资源只有 ${ICNS_BYTES} 字节,基本是空的"
    fi
else
    bad "随包 App 没有 Contents/Resources/AppIcon.icns"
fi
if [ "$(plutil -extract CFBundleIconFile raw "$PLIST" 2>/dev/null)" = "AppIcon" ]; then
    ok "CFBundleIconFile = AppIcon"
else
    bad "CFBundleIconFile 不是 AppIcon"
fi
FULL_APP_VER=$(entry_text "$FULL" "/Contents/Info.plist" | plutil -extract CFBundleShortVersionString raw - 2>/dev/null)
if [ "$FULL_APP_VER" = "$VERSION" ]; then
    ok "full 包内 App 版本 = $VERSION"
else
    bad "full 包内 App 版本 = ${FULL_APP_VER:-读不到},期望 $VERSION"
fi

# ---- 5. 别再写死「应该是什么版本」 ----
echo ""
echo "[5] 诊断/安装脚本不许写死版本"
for pair in "full:$FULL" "kit:$KIT"; do
    label="${pair%%:*}"; zip="${pair#*:}"
    DIAG=$(entry_text "$zip" "/scripts/diagnose-install.sh")
    if [ -z "$DIAG" ]; then
        bad "$label 缺少 scripts/diagnose-install.sh"
    elif printf '%s' "$DIAG" | grep -Eq 'expect_sha256=[0-9a-fA-F]{64}'; then
        bad "$label 的 diagnose-install.sh 仍写死 expect_sha256"
        note "写死的那个值迟早会和 main 分叉,升级成功的人会被判成版本不符"
    else
        ok "$label diagnose-install.sh 从 SHA256SUMS 取期望值"
    fi
    INST=$(entry_text "$zip" "/installer/install.command")
    if [ -z "$INST" ]; then
        bad "$label 缺少 installer/install.command"
    elif printf '%s' "$INST" | grep -Eq 'CFBundleShortVersionString</key><string>1\.0<'; then
        bad "$label 的安装器仍把版本写死 1.0"
    else
        ok "$label 安装器写真实版本"
    fi
    if [ -z "$(entry_for "$zip" "/VERSION")" ]; then
        bad "$label 缺少 VERSION 文件"
    elif entry_text "$zip" "/VERSION" | grep -Fqx "$VERSION"; then
        ok "$label 带 VERSION=$VERSION"
    else
        bad "$label 的 VERSION 内容不是 $VERSION"
    fi
done

# ---- 6. 包内清单自校验 ----
echo ""
echo "[6] 包内 SHA256SUMS 自校验"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/claude-release-check.XXXXXX")
for pair in "full:$FULL" "kit:$KIT"; do
    label="${pair%%:*}"; zip="${pair#*:}"
    rm -rf "$TMP/$label"; mkdir -p "$TMP/$label"
    if unzip -q "$zip" -d "$TMP/$label" 2>/dev/null; then
        TOP=$(find "$TMP/$label" -mindepth 1 -maxdepth 1 -type d | head -1)
        if ( cd "$TOP" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ); then
            ok "$label 包内 shasum -c 通过"
        else
            bad "$label 包内 shasum -c 失败"
            ( cd "$TOP" && shasum -a 256 -c SHA256SUMS 2>&1 | grep -v ': OK$' | head -3 | while read -r line; do note "$line"; done )
        fi
    else
        bad "$label 解压失败"
    fi
done
rm -rf "$TMP"

# ---- 结论 ----
echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "✓ 发布门禁通过:v$VERSION 的产物与 HEAD(${HEAD_CORE:0:12}…) 一致,可以打 tag 发布"
    exit 0
fi
echo "✗ 发布门禁失败:$FAILS 项。不要发这个包 —— 用户装完会和现在一模一样。"
exit 1
