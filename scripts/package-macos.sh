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
cp "$ROOT/SHA256SUMS" "$KIT_ROOT/SHA256SUMS"
# zip 里的中文名在某些解压工具(macOS 归档实用工具)下会变成乱码。除了给 zip
# 写 UTF-8 标记,再提供一整套纯 ASCII 路径,乱码时也能照常双击安装。
cp "$KIT_ROOT/installer/安装.command" "$KIT_ROOT/installer/install.command"
cp "$KIT_ROOT/installer/卸载.command" "$KIT_ROOT/installer/uninstall.command"
cat > "$KIT_ROOT/INSTALL.command" <<'ASCII_EOF'
#!/bin/bash
# 安装入口(纯 ASCII 文件名)。中文文件名若被解压工具弄乱,双击这个一样能装。
HERE="$(cd "$(dirname "$0")" && pwd)"
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true
cd "$HERE" || exit 1
exec bash "$HERE/installer/install.command"
ASCII_EOF
cat > "$KIT_ROOT/README-INSTALL.txt" <<'ASCII_EOF'
INSTALL (read me first)

1. Double-click INSTALL.command
   (if macOS blocks it: right-click -> Open -> Open)
2. Confirm the proxy group / region, enter your password once
3. The app appears on your Desktop

This package contains the compiled app, core script, daemons and installer.
No Xcode, no other package, no separate upgrade command needed.
Needs macOS 13+, Apple Silicon, python3, a running proxy client, Claude desktop.

If the Chinese-named files show up as garbled text after unzipping, ignore them:
INSTALL.command and installer/install.command are plain ASCII and work anyway.
ASCII_EOF
chmod +x "$KIT_ROOT/INSTALL.command" "$KIT_ROOT/installer/install.command" \
         "$KIT_ROOT/installer/uninstall.command" \
         "$KIT_ROOT/installer/安装.command" "$KIT_ROOT/installer/卸载.command" \
         "$KIT_ROOT/scripts/upgrade-core.sh"
for ITEM in \
    README.md README.en.md AGENTS.md SECURITY.md LICENSE SHA256SUMS \
    INSTALL.command README-INSTALL.txt installer/install.command \
    core/claude-switch.sh daemons/claude-bodyguard.sh installer/安装.command \
    app/main.swift assets/icon-2048.png docs/screenshot.png \
    scripts/upgrade-core.sh; do
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
ditto "$APP" "$FULL_ROOT/Claude 环境检查器.app"
cat > "$FULL_ROOT/一键安装.command" <<'LAUNCH_EOF'
#!/bin/bash
# 中文入口,和 INSTALL.command 等价;统一走 ASCII 路径,乱码也不受影响。
HERE="$(cd "$(dirname "$0")" && pwd)"
# 网上下载的 zip 会给每个文件打 com.apple.quarantine。清掉本包内的隔离属性,
# 免得装好的 App 又被 Gatekeeper 拦一次。只处理解压目录,不碰系统其它位置。
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true
cd "$HERE" || exit 1
exec bash "$HERE/installer/install.command"
LAUNCH_EOF
cat > "$FULL_ROOT/先读我.txt" <<'NOTE_EOF'
一个包全装好 —— 三步

1. 双击 INSTALL.command(和「一键安装.command」完全一样)
   (首次若被 macOS 拦下:右键点它 → 打开 → 再点「打开」)
2. 按提示确认代理组 / 地区,输入一次开机密码
3. 完成后桌面出现「Claude 环境检查器」,双击启动

包内已经带上编译好的界面 App、核心脚本、守护进程和安装器:
不需要 Xcode、不需要另下 app-only 包、不需要再跑升级命令。
目标机仍需 python3(python.org 或 brew install python 均可)、macOS 13+、
Apple Silicon、一个正在运行的代理客户端和 Claude 桌面版。

如果解压后中文文件名变成乱码(老版本 zip 的问题),直接双击 ASCII 文件名的
INSTALL.command 即可,内部路径全是 ASCII,不受影响;详细说明见 README-INSTALL.txt。

特殊场景才用别的包:
  *-installer-kit.zip   Intel Mac 或想自己从源码编译
  *-app-only.dmg        只想换界面,核心脚本已经是新的
  scripts/upgrade-core.sh  旧机器只升级核心脚本
NOTE_EOF
chmod +x "$FULL_ROOT/INSTALL.command" "$FULL_ROOT/一键安装.command" \
         "$FULL_ROOT/installer/install.command" "$FULL_ROOT/installer/uninstall.command" \
         "$FULL_ROOT/installer/安装.command" \
         "$FULL_ROOT/installer/卸载.command" \
         "$FULL_ROOT/scripts/upgrade-core.sh"
for ITEM in "INSTALL.command" "README-INSTALL.txt" "一键安装.command" "先读我.txt" \
            "Claude 环境检查器.app/Contents/MacOS/ClaudeSwitcher" \
            "core/claude-switch.sh" "core/stun-probe.py" \
            "daemons/claude-bodyguard.sh" "installer/install.command" \
            "installer/安装.command" "scripts/upgrade-core.sh" "SHA256SUMS"; do
    if [ ! -e "$FULL_ROOT/$ITEM" ]; then
        echo "✗ 一体化安装包缺少 $ITEM" >&2
        exit 1
    fi
done
for ITEM in "INSTALL.command" "一键安装.command" "installer/install.command"; do
    [ -x "$FULL_ROOT/$ITEM" ] || { echo "✗ $ITEM 不可执行" >&2; exit 1; }
done
python3 "$ROOT/scripts/make-zip.py" "$FULL_ROOT" "$FULL_ZIP" "$FULL_NAME"

echo ""
echo "✓ 打包完成:"
for FILE in "$FULL_ZIP" "$ZIP" "$DMG" "$KIT_ZIP"; do
    [ -f "$FILE" ] || { echo "✗ 缺少产物 $FILE" >&2; exit 1; }
    printf '  %-58s %8s\n' "$(basename "$FILE")" "$(du -h "$FILE" | cut -f1)"
done
