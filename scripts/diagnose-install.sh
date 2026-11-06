#!/bin/bash
# 只读自检:核心脚本版本、App bundle 完整性、图标资源、Clash Verge 注册状态、内核首条规则。
# 不修改任何文件,不读取账号内容,不访问网络(除本机内核 socket)。
set -u

CORE="$HOME/.local/bin/claude-switch.sh"
APP="$HOME/Desktop/Claude 环境检查器.app"
CLASH_DIR=""

say() { printf '%s\n' "$*"; }
count() { local n; n=$(grep -c "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

say "=== 1. 核心脚本 ==="
if [ -f "$CORE" ]; then
    say "path=$CORE"
    say "sha256=$(shasum -a 256 "$CORE" | awk '{print $1}')"
    say "has_register_script=$(count "$CORE" 'register-script')"
    say "has_diag_lines=$(count "$CORE" 'FIX:诊断:Script.js')"
    say "expect_sha256=4a0ccffb2ed4def496977feea40b91b3b3f652671ffa07a3980c2a6c8d725d8e"
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
    say "icon_key=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || echo 无)"
    say "lsui=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null || echo 无)"
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
say "ClaudeSwitcher=$(pgrep -x ClaudeSwitcher | head -1 || echo 未运行)"
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
    else
        say "script_js=缺失"
        say "managed_block=0"
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
