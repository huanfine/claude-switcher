#!/bin/bash
# 发布门禁:Windows zip / Linux tar.gz 里的脚本必须等于当前仓库,
# 且必须真的带报告 v2 入口。避免「工作树修好了,发布包还是旧脚本」。
#
# 用法:
#   bash scripts/release-check-platforms.sh <版本号>
#   BUILD_DIR=/path/to/build bash scripts/release-check-platforms.sh <版本号>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

BUILD="${BUILD_DIR:-$ROOT/build}"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    LATEST=$(ls -t "$BUILD"/ClaudeSwitcher-*-windows.zip 2>/dev/null | head -1)
    [ -n "$LATEST" ] || {
        echo "FAIL: build/ 下没有 Windows zip,先跑发布打包或传入版本号" >&2
        exit 1
    }
    VERSION=$(basename "$LATEST" | sed -E 's/^ClaudeSwitcher-(.+)-windows\.zip$/\1/')
fi
case "$VERSION" in
    ''|*[!0-9A-Za-z._-]*)
        echo "FAIL: 非法版本号: $VERSION" >&2
        exit 1
        ;;
esac

WIN="$BUILD/ClaudeSwitcher-$VERSION-windows.zip"
LINUX="$BUILD/ClaudeSwitcher-$VERSION-linux.tar.gz"
WIN_TOP="ClaudeSwitcher-$VERSION-windows"
LINUX_TOP="ClaudeSwitcher-$VERSION-linux"
FAILS=0
TMP_MODE=$(mktemp -d "${TMPDIR:-/tmp}/claude-platform-mode.XXXXXX") || {
    echo "FAIL: 无法创建临时目录" >&2
    exit 1
}
trap 'rm -rf "$TMP_MODE"' EXIT

ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }

zip_has()  { unzip -Z1 "$1" 2>/dev/null | grep -Fx -e "$2" >/dev/null; }
tar_has()  { tar -tzf "$1" 2>/dev/null | grep -Fx -e "$2" >/dev/null; }
zip_hash() { unzip -p "$1" "$2" 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
tar_hash() { tar -xOzf "$1" "$2" 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
zip_text() { unzip -p "$1" "$2" 2>/dev/null | grep -F -e "$3" >/dev/null; }
tar_text() { tar -xOzf "$1" "$2" 2>/dev/null | grep -F -e "$3" >/dev/null; }

echo "==> 跨平台发布门禁 v$VERSION"

if [ -f "$WIN" ]; then ok "存在 $WIN"; else bad "缺少 $WIN"; fi
if [ -f "$LINUX" ]; then ok "存在 $LINUX"; else bad "缺少 $LINUX"; fi
if [ "$FAILS" -gt 0 ]; then
    echo ""
    echo "✗ 跨平台产物缺失,后续检查跳过"
    exit 1
fi

WIN_FILES=(
    windows/claude-switch.ps1
    windows/SwitcherUI.ps1
    windows/install.ps1
    windows/claude-bodyguard.ps1
    windows/README.md
    README.md AGENTS.md SECURITY.md LICENSE VERSION
)
LINUX_FILES=(
    linux/claude-switch.sh
    linux/install.sh
    linux/stun-probe.py
    linux/claude-bodyguard.sh
    linux/README.md
    README.md AGENTS.md SECURITY.md LICENSE
)

echo ""
echo "[1] Windows zip 清单"
for rel in "${WIN_FILES[@]}"; do
    if zip_has "$WIN" "$WIN_TOP/$rel"; then
        ok "$rel"
    else
        bad "Windows 包缺少 $rel"
    fi
done

echo ""
echo "[2] Linux tar.gz 清单"
for rel in "${LINUX_FILES[@]}"; do
    if tar_has "$LINUX" "$LINUX_TOP/$rel"; then
        ok "$rel"
    else
        bad "Linux 包缺少 $rel"
    fi
done

echo ""
echo "[3] 包内脚本 = 仓库 HEAD 工作树"
for rel in "${WIN_FILES[@]}"; do
    case "$rel" in
        windows/*.ps1)
            repo_hash=$(shasum -a 256 "$ROOT/$rel" 2>/dev/null | awk '{print $1}')
            pkg_hash=$(zip_hash "$WIN" "$WIN_TOP/$rel")
            if [ -n "$repo_hash" ] && [ "$repo_hash" = "$pkg_hash" ]; then
                ok "Windows $rel ${pkg_hash:0:12}…"
            else
                bad "Windows $rel 与仓库不一致 (包 ${pkg_hash:0:12}… / 仓库 ${repo_hash:0:12}…)"
            fi
            ;;
    esac
done
for rel in "${LINUX_FILES[@]}"; do
    case "$rel" in
        linux/*.sh|linux/*.py)
            repo_hash=$(shasum -a 256 "$ROOT/$rel" 2>/dev/null | awk '{print $1}')
            pkg_hash=$(tar_hash "$LINUX" "$LINUX_TOP/$rel")
            if [ -n "$repo_hash" ] && [ "$repo_hash" = "$pkg_hash" ]; then
                ok "Linux $rel ${pkg_hash:0:12}…"
            else
                bad "Linux $rel 与仓库不一致 (包 ${pkg_hash:0:12}… / 仓库 ${repo_hash:0:12}…)"
            fi
            ;;
    esac
done

echo ""
echo "[4] 报告 v2 入口"
WIN_REPORT="$WIN_TOP/windows/claude-switch.ps1"
for marker in "function Get-CheckReport" "checks = \$checks.ToArray()" "last-report.json" "'report' {"; do
    if zip_text "$WIN" "$WIN_REPORT" "$marker"; then
        ok "Windows 包含 $marker"
    else
        bad "Windows 缺少报告入口: $marker"
    fi
done
LINUX_REPORT="$LINUX_TOP/linux/claude-switch.sh"
for marker in "report_json()" "checkdetail [--json]" "report) report_json"; do
    if tar_text "$LINUX" "$LINUX_REPORT" "$marker"; then
        ok "Linux 包含 $marker"
    else
        bad "Linux 缺少报告入口: $marker"
    fi
done

echo ""
echo "[5] Linux 入口可执行位"
for rel in linux/claude-switch.sh linux/install.sh; do
    rm -rf "$TMP_MODE"
    mkdir -p "$TMP_MODE"
    if tar -xzf "$LINUX" -C "$TMP_MODE" "$LINUX_TOP/$rel" 2>/dev/null \
        && [ -x "$TMP_MODE/$LINUX_TOP/$rel" ]; then
        ok "Linux $rel 在 tar.gz 中可执行"
    else
        bad "Linux $rel 在 tar.gz 中缺少可执行位"
    fi
done

echo "[6] Windows VERSION"
WIN_VERSION=$(unzip -p "$WIN" "$WIN_TOP/VERSION" 2>/dev/null | tr -d '\r\n')
if [ "$WIN_VERSION" = "$VERSION" ]; then
    ok "Windows VERSION=$VERSION"
else
    bad "Windows VERSION=${WIN_VERSION:-读不到},期望 $VERSION"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "✓ 跨平台发布门禁通过:v$VERSION 的 Windows/Linux 包与仓库一致,报告入口齐全"
    exit 0
fi
echo "✗ 跨平台发布门禁失败:$FAILS 项"
exit 1
