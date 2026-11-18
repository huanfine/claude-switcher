#!/bin/bash
# Claude 保镖 (参考模板) —— 安装程序会把 __PROXY_MODE__ / __FAKE_PREFIX__ /
# __LOG_DIR__ 替换为实际值后安装。
# 作用: 代理(内核或TUN)离线时,自动关闭 Claude,杜绝裸连重试
LOG="__LOG_DIR__/claude-bodyguard.log"
MODE="__PROXY_MODE__"
PREFIX="__FAKE_PREFIX__"
case "$PREFIX" in ''|__*) PREFIX="198.18." ;; esac

ok=1
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管。
# 前缀跟着安装时的 fake_ip_range 走;写死 198.18. 会把自定义网段的 TUN 判成离线,
# 于是保镖把正常使用的 Claude 反复杀掉。用 -F 按字面量匹配,前缀里的点不当正则。
ifconfig 2>/dev/null | grep -qF "inet $PREFIX" || ok=0

# 内核在线判定:按安装时识别的客户端分派
case "$MODE" in
    clash-verge)
        pgrep -f verge-mihomo >/dev/null 2>&1 || ok=0 ;;
    flclash)
        { pgrep -f FlClashCore >/dev/null 2>&1 || pgrep -x FlClash >/dev/null 2>&1; } || ok=0 ;;
    shadowrocket)
        # launchd 环境下 scutil 可能查不到 VPN 行,查不到时以 TUN 判定为准(避免误杀)
        nc=$(scutil --nc list 2>/dev/null)
        if echo "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
            echo "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)' || ok=0
        fi ;;
    sing-box)
        pgrep -f sing-box >/dev/null 2>&1 || ok=0 ;;
    clashx)
        { pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1; } || ok=0 ;;
    surge)
        pgrep -f Surge >/dev/null 2>&1 || ok=0 ;;
    auto)
        : ;;  # auto 模式只查 TUN
    *)
        pgrep -f verge-mihomo >/dev/null 2>&1 || ok=0 ;;
esac

if [ "$ok" -eq 0 ]; then
    # 不写死 /Applications:App 装在 ~/Applications 时保镖同样要能停掉它。
    if pgrep -f 'Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1; then
        pkill -f 'Claude.app/Contents/MacOS/Claude'
        echo "$(date '+%Y-%m-%d %H:%M:%S') 代理离线(内核或TUN丢失),已自动关闭 Claude" >>"$LOG"
    fi
fi
