#!/bin/bash
# Claude 环境检查器 - macOS 打包脚本（本地与 CI 共用）
# 用法: bash scripts/package-macos.sh [版本号]
# 产物: build/ClaudeSwitcher-<版本>-macos-<架构>.zip
#       build/ClaudeSwitcher-<版本>-macos-<架构>.dmg
#       build/ClaudeSwitcher-<版本>-installer-kit.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.0.0-dev}"
case "$VERSION" in
    ''|*[!0-9A-Za-z._-]*)
        echo "✗ 版本号只能包含字母、数字、点、下划线和连字符: $VERSION" >&2
        exit 1
        ;;
esac

APP_NAME="Claude 环境检查器"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  ARCH_LABEL="arm64" ;;
    x86_64) ARCH_LABEL="x86_64" ;;
    *)      ARCH_LABEL="$ARCH" ;;
esac
ZIP="$BUILD/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-app-only.zip"
DMG="$BUILD/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-app-only.dmg"
KIT_NAME="ClaudeSwitcher-$VERSION"
KIT_ZIP="$BUILD/ClaudeSwitcher-$VERSION-installer-kit.zip"
# 一体化包:kit 的全部内容 + 编译好的 App + 双击即装的入口,别的机器只需这一个文件。
FULL_NAME="ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-full"
FULL_ZIP="$BUILD/$FULL_NAME.zip"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-package.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$BUILD"
rm -rf "$APP" "$ZIP" "$DMG" "$KIT_ZIP" "$FULL_ZIP"

echo "==> 编译 $APP_NAME $VERSION ($ARCH_LABEL)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# -Xfrontend -disable-sandbox:SwiftUI 的 @State 是宏,展开要跑 swift-plugin-server。
# 编译器把插件关进沙箱时,插件会返回 malformed response,报出来的却是一堆
# 「@State 不存在 / cannot assign to property」的假错误。安装器早就加了这个开关,
# 打包脚本没加 —— 同一份源码两套结果,构建机上会莫名其妙编不过。
swiftc -O -parse-as-library -warnings-as-errors -Xfrontend -disable-sandbox \
    -target "$ARCH-apple-macos13.0" \
    "$ROOT/app/main.swift" \
    -o "$APP/Contents/MacOS/ClaudeSwitcher" \
    -framework SwiftUI -framework AppKit

echo "==> 生成图标"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for SZ in 16 32 128 256 512; do
    sips -z "$SZ" "$SZ" "$ROOT/assets/icon-2048.png" \
        --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
    sips -z $((SZ * 2)) $((SZ * 2)) "$ROOT/assets/icon-2048.png" \
        --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
	<key>CFBundleIdentifier</key><string>local.claude-switcher</string>
	<key>CFBundleName</key><string>Claude 环境检查器</string>
	<key>CFBundleDisplayName</key><string>Claude 环境检查器</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if codesign --force --deep -s - "$APP" >/dev/null 2>&1; then
    echo "✓ ad-hoc 签名完成"
else
    echo "⚠️ ad-hoc 签名失败，继续打包"
fi

NOTE="$WORK/安装说明.txt"
cat > "$NOTE" <<'NOTE_EOF'
这是仅包含 macOS 界面 App 的安装包，不含核心脚本与守护进程。

首次使用请下载 installer-kit.zip，解压后双击 installer/安装.command。
若已安装过核心脚本，可把本 App 拖入「应用程序」覆盖旧版界面。

未安装核心脚本时，App 会提示「还差一步：安装核心脚本」并提供下载入口。
NOTE_EOF

echo "==> 生成 macOS zip(app-only)"
APP_STAGE="$WORK/appstage"
mkdir -p "$APP_STAGE"
ditto "$APP" "$APP_STAGE/$APP_NAME.app"
cp "$NOTE" "$APP_STAGE/安装说明.txt"
python3 "$ROOT/scripts/make-zip.py" "$APP_STAGE" "$ZIP"

echo "==> 生成 DMG(app-only)"
DMG_STAGE="$WORK/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
cp "$NOTE" "$DMG_STAGE/安装说明.txt"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> 生成 installer kit"
KIT_ROOT="$WORK/$KIT_NAME"
mkdir -p "$KIT_ROOT"
for FILE in README.md README.en.md AGENTS.md SECURITY.md LICENSE; do
    cp "$ROOT/$FILE" "$KIT_ROOT/"
done
for DIR in core daemons installer app; do
    ditto "$ROOT/$DIR" "$KIT_ROOT/$DIR"
done
mkdir -p "$KIT_ROOT/assets" "$KIT_ROOT/docs" "$KIT_ROOT/scripts"
cp "$ROOT/assets/icon-2048.png" "$KIT_ROOT/assets/"
cp "$ROOT/docs/screenshot.png" "$KIT_ROOT/docs/"
# 「新 App + 旧核心」时的急救脚本。只装了 app-only 包的人也需要能升级核心。
cp "$ROOT/scripts/upgrade-core.sh" "$KIT_ROOT/scripts/"
# 「点了修复没反应」的一键诊断。随包带上,目标机没网也能跑(另可从 main raw 获取)。
cp "$ROOT/scripts/diagnose-fix.sh" "$KIT_ROOT/scripts/"
# 只读自检:版本 / App bundle / 图标 / 脚本注册 / 内核首条规则。随包带一份,
# 用户不必联网也能拿到与包内代码同版本的诊断脚本。
cp "$ROOT/scripts/diagnose-install.sh" "$KIT_ROOT/scripts/"
# 安装器从这里读版本号写进 Info.plist。少了它,现场编译出来的界面只能标 0.0.0-dev。
printf '%s\n' "$VERSION" > "$KIT_ROOT/VERSION"
cp "$ROOT/SHA256SUMS" "$KIT_ROOT/SHA256SUMS"
# zip 里的中文名在 macOS「归档实用工具」下会变成乱码(连 zip 写了 UTF-8 标记
# 也一样)。所以安装入口用纯 ASCII,一体化包更是不留任何中文文件名。
cp "$KIT_ROOT/installer/安装.command" "$KIT_ROOT/installer/install.command"
cp "$KIT_ROOT/installer/卸载.command" "$KIT_ROOT/installer/uninstall.command"
cat > "$KIT_ROOT/INSTALL.command" <<'ASCII_EOF'
#!/bin/bash
# 唯一安装入口。文件名和它调用的路径全是 ASCII,任何解压工具都弄不乱。
HERE="$(cd "$(dirname "$0")" && pwd)"
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true
cd "$HERE" || exit 1
exec bash "$HERE/installer/install.command"
ASCII_EOF
cat > "$KIT_ROOT/README-INSTALL.txt" <<'ASCII_EOF'
INSTALL - read this first / 先看这里

只认 INSTALL.command 这一个入口,双击它。
首次被系统拦下:右键 -> 打开 -> 再点「打开」。
按提示确认代理组 / 地区,输入一次开机密码,桌面出现「Claude 环境检查器」。

Only double-click INSTALL.command. Ignore every other .command file in this
folder, especially ones whose names look garbled (a...command) - they are from
old packages and cannot be opened. Never paste a garbled name into a terminal.

包内已经带上编译好的 App、核心脚本、守护进程与安装器:
不需要 Xcode、不需要另下别的包、不需要再跑升级命令。
Needs macOS 13+, Apple Silicon, python3, a running proxy client, Claude desktop.

一体化包(*-full.zip)内所有文件名均为 ASCII,解压后不会出现乱码。
安装入口及其内部路径全是 ASCII,不受解压工具影响。

装好后若「一键修复」看起来没生效,进入本目录在终端跑一次:
  bash scripts/diagnose-fix.sh
它会原样执行一次修复并记录每一步,把桌面的 claude-fix-diagnosis.txt 发回即可。

只升级了核心脚本(upgrade-core.sh)的人注意:升级完必须再跑一次
  ~/.local/bin/claude-switch.sh fix
因为置顶规则写在 Clash Verge 的全局脚本里,升级本身不会重写它,也不会重启客户端。

只想看状态、不改任何东西,跑这个:
  bash scripts/diagnose-install.sh
它会打印核心脚本 sha256 与发布清单里的期望值、App 版本、图标资源、内核首条规则。
菜单栏看不到图标时也先跑它:App 是 LSUIElement(本来就没有程序坞图标),
唯一常驻入口是菜单栏;双击桌面 App 会重新打开窗口。
ASCII_EOF
chmod +x "$KIT_ROOT/INSTALL.command" "$KIT_ROOT/installer/install.command" \
         "$KIT_ROOT/installer/uninstall.command" \
         "$KIT_ROOT/installer/安装.command" "$KIT_ROOT/installer/卸载.command" \
         "$KIT_ROOT/scripts/upgrade-core.sh" "$KIT_ROOT/scripts/diagnose-fix.sh" \
         "$KIT_ROOT/scripts/diagnose-install.sh"
for ITEM in \
    README.md README.en.md AGENTS.md SECURITY.md LICENSE SHA256SUMS VERSION \
    INSTALL.command README-INSTALL.txt installer/install.command \
    core/claude-switch.sh daemons/claude-bodyguard.sh installer/安装.command \
    app/main.swift assets/icon-2048.png docs/screenshot.png \
    scripts/upgrade-core.sh scripts/diagnose-fix.sh scripts/diagnose-install.sh; do
    if [ ! -e "$KIT_ROOT/$ITEM" ]; then
        echo "✗ installer kit 缺少 $ITEM" >&2
        exit 1
    fi
done
python3 "$ROOT/scripts/make-zip.py" "$KIT_ROOT" "$KIT_ZIP" "$KIT_NAME"

echo "==> 生成一体化安装包 ($ARCH_LABEL, 免编译)"
# 不再让别的机器在 kit / app-only / 升级脚本之间做选择题:
# 一份包里同时带上编译好的 App、核心脚本、守护进程与安装器。
FULL_ROOT="$WORK/$FULL_NAME"
ditto "$KIT_ROOT" "$FULL_ROOT"
# 随包 App 也用 ASCII 名;安装器会认出它,装到桌面时仍叫「Claude 环境检查器」。
ditto "$APP" "$FULL_ROOT/ClaudeSwitcher.app"
# 一体化包里不留任何中文文件名。macOS 归档实用工具会把中文名解成
# 「ä¸é®åè£.command」之类,用户在 Finder 里看到那个乱码 .command 就会去点,
# 点了又报 no such file or directory。只保留 INSTALL.command 这一个入口,
# 从根上消灭「选错文件」的可能,而不是靠文档提醒用户别点。
rm -f "$FULL_ROOT/installer/安装.command" "$FULL_ROOT/installer/卸载.command"
# 仓库的 SHA256SUMS 列的是中文名安装器。一体化包只留 ASCII 名,清单也要同步
# 改写,否则用户跑 shasum -c 会报两个文件找不到。两个文件都是 cp 出来的副本,
# 内容逐字节相同,哈希不变,只换路径。
python3 - "$ROOT/SHA256SUMS" "$FULL_ROOT/SHA256SUMS" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
renames = {
    "installer/安装.command": "installer/install.command",
    "installer/卸载.command": "installer/uninstall.command",
}
out = []
with open(src, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        digest, sep, path = line.partition("  ")
        out.append(f"{digest}  {renames.get(path, path)}" if sep else line)
with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
( cd "$FULL_ROOT" && shasum -a 256 -c SHA256SUMS >/dev/null ) \
    || { echo "✗ 一体化包内 SHA256SUMS 校验失败" >&2; exit 1; }
chmod +x "$FULL_ROOT/INSTALL.command" \
         "$FULL_ROOT/installer/install.command" "$FULL_ROOT/installer/uninstall.command" \
         "$FULL_ROOT/scripts/upgrade-core.sh" "$FULL_ROOT/scripts/diagnose-fix.sh" \
         "$FULL_ROOT/scripts/diagnose-install.sh"
for ITEM in "INSTALL.command" "README-INSTALL.txt" \
            "ClaudeSwitcher.app/Contents/MacOS/ClaudeSwitcher" \
            "core/claude-switch.sh" "core/stun-probe.py" \
            "daemons/claude-bodyguard.sh" "installer/install.command" \
            "installer/uninstall.command" "scripts/upgrade-core.sh" \
            "scripts/diagnose-fix.sh" "scripts/diagnose-install.sh" \
            "VERSION" "SHA256SUMS"; do
    if [ ! -e "$FULL_ROOT/$ITEM" ]; then
        echo "✗ 一体化安装包缺少 $ITEM" >&2
        exit 1
    fi
done
for ITEM in "INSTALL.command" "installer/install.command" \
            "installer/uninstall.command" "scripts/upgrade-core.sh" \
            "scripts/diagnose-fix.sh" "scripts/diagnose-install.sh"; do
    [ -x "$FULL_ROOT/$ITEM" ] || { echo "✗ $ITEM 不可执行" >&2; exit 1; }
done
# 构建期硬门禁:一体化包里只要还有一个非 ASCII 文件名,就直接打包失败。
# 之前 1.8.5 版虽然给 zip 写了 UTF-8 标记,系统归档工具照样解成乱码。
NON_ASCII="$(python3 - "$FULL_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        if not name.isascii():
            print(os.path.relpath(os.path.join(base, name), root))
PY
)"
if [ -n "$NON_ASCII" ]; then
    echo "✗ 一体化包里还有非 ASCII 文件名(解压会乱码):" >&2
    echo "$NON_ASCII" >&2
    exit 1
fi
python3 "$ROOT/scripts/make-zip.py" "$FULL_ROOT" "$FULL_ZIP" "$FULL_NAME"

echo ""
echo "✓ 打包完成:"
for FILE in "$FULL_ZIP" "$ZIP" "$DMG" "$KIT_ZIP"; do
    [ -f "$FILE" ] || { echo "✗ 缺少产物 $FILE" >&2; exit 1; }
    printf '  %-58s %8s\n' "$(basename "$FILE")" "$(du -h "$FILE" | cut -f1)"
done
