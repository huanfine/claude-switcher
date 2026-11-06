#!/bin/bash
# 只读自检:核心脚本版本、App bundle 完整性、图标资源、Clash Verge 注册状态、内核首条规则。
# 不修改任何文件,不读取账号内容。网络只用于取一份 SHA256SUMS 做版本比对
# (取不到就标 unknown,绝不拿写死的哈希当结论)。
set -u

CORE="$HOME/.local/bin/claude-switch.sh"
APP="$HOME/Desktop/Claude 环境检查器.app"
CLASH_DIR=""
REPO_SLUG="${CLAUDE_SWITCHER_REPO:-huanfine/claude-switcher}"
SUMS_URL="https://raw.githubusercontent.com/$REPO_SLUG/main/SHA256SUMS"

say() { printf '%s\n' "$*"; }
count() { local n; n=$(grep -c "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

# 「应该是哪个哈希」只能来自发布清单,不能来自脚本里写死的常量。
# 写死的后果实测过:核心在 03:16 变了一次,自检脚本里的 expect 还停在 02:59,
# 于是升级成功的人也会看到「sha256 与 expect 不一致」,把已经修好的机器判成坏的。
expect_core_hash() {
    local tmp hash
    tmp="$(mktemp "${TMPDIR:-/tmp}/claude-switcher-sums.XXXXXX")" || return 1
    if curl -fsSL --max-time 8 "$SUMS_URL" -o "$tmp" 2>/dev/null; then
        hash=$(awk '$2=="core/claude-switch.sh" {print $1; exit}' "$tmp")
        rm -f "$tmp"
        [ -n "$hash" ] && { printf '%s' "$hash"; return 0; }
        return 1
    fi
    rm -f "$tmp"
    return 1
}

say "=== 1. 核心脚本 ==="
if [ -f "$CORE" ]; then
    say "path=$CORE"
    INSTALLED=$(shasum -a 256 "$CORE" | awk '{print $1}')
    say "sha256=$INSTALLED"
    say "has_register_script=$(count "$CORE" 'register-script')"
    say "has_diag_lines=$(count "$CORE" 'FIX:诊断:Script.js')"
    if EXPECT=$(expect_core_hash) && [ -n "$EXPECT" ]; then
        say "expect_sha256=$EXPECT"
        say "expect_source=$SUMS_URL"
        if [ "$INSTALLED" = "$EXPECT" ]; then
            say "version_match=yes"
        else
            say "version_match=no"
            say "hint=核心脚本落后于 main。执行 upgrade-core.sh 升级后,必须再跑一次 fix 才会重写 Script.js 并重启客户端"
        fi
    else
        say "expect_sha256=unknown"
        say "expect_source=取不到($SUMS_URL),本次不做版本比对"
        say "version_match=unknown"
    fi
else
    say "path=$CORE 不存在"
fi

say ""
say "=== 2. App bundle ==="
if [ -d "$APP" ]; then
    say "path=$APP"
    if [ -f "$APP/Contents/Info.plist" ] && [ -f "$APP/Contents/MacOS/ClaudeSwitcher" ]; then
        say "bundle_ok=yes"
    else
        say "bundle_ok=no"
    fi
    say "version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 读不到)"
    # 1.8.8 及更早的安装器在「现场编译」那条路径上把版本写死成 1.0,
    # 所有版本都长一样。看到 1.0 不代表装的是 1.0,只代表走的是编译路径。
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)" = "1.0" ]; then
        say "version_note=1.0 是旧安装器写死的占位版本,无法据此判断真实版本(说明装的是现场编译的界面)"
    fi
    say "icon_key=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || echo 无)"
    say "lsui=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null || echo 无)"
    # LSUIElement=1 的 App 本来就没有 Dock 图标。不少人把「Dock 里没有」当成
    # 「图标没打进去」,顺手把 icns 当成坏的重做一遍。这里直接说清预期。
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null)" = "true" ]; then
        say "dock_icon=按设计不常驻(LSUIElement=1),常驻入口是菜单栏图标"
        say "dock_hint=若菜单栏也看不到:双击桌面 App 会打开窗口;或 defaults write local.claude-switcher showInDock -bool true 后重开 App"
    fi
    say "bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo 无)"
    say "resources=$(ls "$APP/Contents/Resources" 2>/dev/null | tr '\n' ' ')"
    if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        say "icns_bytes=$(wc -c < "$APP/Contents/Resources/AppIcon.icns" | tr -d ' ')"
    else
        say "icns_bytes=缺失"
    fi
    say "quarantine=$(xattr -p com.apple.quarantine "$APP" 2>/dev/null | head -1 || echo 无)"
    say "codesign=$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p' | head -1 || echo 未知)"
else
    say "path=$APP 不存在"
    say "--- 桌面上的 .app ---"
    ls -d "$HOME/Desktop"/*.app 2>/dev/null | head -10
fi

say ""
say "=== 3. 进程 ==="
PID=$(pgrep -x ClaudeSwitcher | head -1)
say "ClaudeSwitcher=${PID:-未运行}"
if [ -n "${PID:-}" ]; then
    # 装完新 App 后旧进程还在跑,是「界面没变化」的常见原因:双击只会激活它,
    # 不会启动新二进制。把真实可执行文件路径打出来,一眼能看出跑的是哪一份。
    say "running_exe=$(ps -o comm= -p "$PID" 2>/dev/null || echo 读不到)"
fi
say "verge-mihomo=$(pgrep -f verge-mihomo | head -1 || echo 未运行)"
say "ClashVerge=$(pgrep -f 'Clash Verge.app/Contents/MacOS/clash-verge' | head -1 || echo 未运行)"

say ""
say "=== 4. Clash Verge ==="
for d in "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" \
         "$HOME/Library/Application Support/clash-verge"; do
    if [ -d "$d" ]; then CLASH_DIR="$d"; break; fi
done
if [ -n "$CLASH_DIR" ]; then
    say "dir=$CLASH_DIR"
    if [ -f "$CLASH_DIR/profiles.yaml" ]; then
        say "profiles_yaml=yes"
        say "uid_script=$(count "$CLASH_DIR/profiles.yaml" '^[[:space:]]*-[[:space:]]*uid:[[:space:]]*Script[[:space:]]*$')"
    else
        say "profiles_yaml=no"
        say "uid_script=0"
    fi
    if [ -f "$CLASH_DIR/profiles/Script.js" ]; then
        say "script_js=$(wc -c < "$CLASH_DIR/profiles/Script.js" | tr -d ' ')bytes"
        say "managed_block=$(count "$CLASH_DIR/profiles/Script.js" 'claude-switcher managed rules')"
        # 关键:管理块必须在最后一个 main 定义之后。块在前、用户在块后又写了
        # main 时,我们的 IIFE 会被覆盖,内核里就没有置顶规则。
        say "script_structure:"
        grep -nE 'function[[:space:]]+main|claude-switcher managed rules|result\.rules[[:space:]]*=' \
            "$CLASH_DIR/profiles/Script.js" 2>/dev/null | head -12
    else
        say "script_js=缺失"
        say "managed_block=0"
    fi
    if [ -f "$CLASH_DIR/profiles/Merge.yaml" ]; then
        say "merge_prepend_rules=$(count "$CLASH_DIR/profiles/Merge.yaml" 'prepend-rules')"
    else
        say "merge_prepend_rules=0"
    fi
    say "clash_verge_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/Clash Verge.app/Contents/Info.plist" 2>/dev/null || echo 未知)"
else
    say "dir=未找到"
fi

say ""
say "=== 5. 内核首条规则 ==="
if [ -n "$CLASH_DIR" ]; then
    S=$(sed -n 's/^external-controller-unix:[[:space:]]*//p' "$CLASH_DIR/clash-verge.yaml" 2>/dev/null | tr -d '"' | head -1)
    for cand in "${S:-}" "/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock"; do
        [ -n "$cand" ] && [ -S "$cand" ] || continue
        say "socket=$cand"
        curl -s --unix-socket "$cand" --max-time 5 http://localhost/rules 2>/dev/null | \
            /usr/bin/python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("rules=读取失败"); raise SystemExit
for i, r in enumerate(d.get("rules", [])[:3]):
    print("rule[%d]=%s|%s|%s" % (i, r.get("type"), r.get("payload"), r.get("proxy")))' 2>/dev/null || say "rules=解析失败"
        break
    done
fi

say ""
say "=== 完成 ==="
