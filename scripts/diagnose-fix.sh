#!/bin/bash
# 「点了一键修复却没修好」的一键诊断。
#
# 为什么需要它:App 的「导出诊断日志」按设计是脱敏的,client.log 只留
# `command=fix exit=1 duration_ms=0` 这类元数据,recent-status.json 只有各项
# ok/warn/fail —— 都看不到 fix 到底卡在哪一行。这个脚本在终端里原样跑一次 fix,
# 把每一步 FIX: 输出、退出码、复查结果连同环境摘要一起落到桌面文件里。
#
# 用法(在那台出问题的 Mac 上,终端里粘一行):
#   bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/diagnose-fix.sh)
#
# 注意:会真的执行一次修复(可能弹一次管理员密码框),和点界面上的「修复」等价。
# 不想改环境就只看前半段,按 Ctrl-C 退出即可。
set -u

CORE="$HOME/.local/bin/claude-switch.sh"
LOG="$HOME/Library/Logs/claude-switcher/client.log"
OUT="$HOME/Desktop/claude-fix-diagnosis.txt"

main() {
    echo "===== Claude Switcher · 修复诊断 ====="
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "用户: $(id -un)  macOS: $(sw_vers -productVersion 2>/dev/null || echo 未知)"
    echo

    echo "----- 1. 环境 -----"
    if [ -x "$CORE" ]; then
        echo "core 脚本: 存在且可执行"
        echo "core 指纹: $(shasum -a 256 "$CORE" 2>/dev/null | cut -c1-16)"
    else
        echo "core 脚本: ✗ 不存在或不可执行 ($CORE)"
        echo "→ 安装没成功,先在包里双击 INSTALL.command 重装"
        return 1
    fi
    echo "当前 PATH: $PATH"
    echo "终端里的 python3: $(command -v python3 2>/dev/null || echo '未找到')"
    echo "系统 /usr/bin/python3: $(/usr/bin/python3 --version 2>&1 | head -1)"
    # GUI App 从 Finder 启动时继承的是 launchd 的极简 PATH。只有 /usr/bin/python3
    # 能保证两边都找得到;brew / python.org 装的只进得了终端。
    if [ ! -x /usr/bin/python3 ]; then
        echo "⚠ 系统没有 /usr/bin/python3:菜单栏 App 很可能找不到 python3,检查/修复会在 0 秒内失败"
        echo "  建议: xcode-select --install(装 Command Line Tools,提供 /usr/bin/python3)"
    fi
    echo

    echo "----- 2. 安装时探测到的环境值(白名单,不含 IP/凭据) -----"
    PY="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
    "$PY" - <<'PY' 2>&1 || echo "  env.json 读取失败"
import json
from pathlib import Path
p = Path.home() / ".claude-switcher/env.json"
try:
    d = json.loads(p.read_text(encoding="utf-8"))
    for k in ("proxy_mode", "proxy_group", "country", "timezone", "locale"):
        print(f"  {k} = {d.get(k, '(未设置)')}")
except Exception as e:
    print(f"  {type(e).__name__}: env.json 缺失或损坏")
PY
    echo

    echo "----- 3. 原样跑一次 fix(若弹管理员密码框,请输入开机密码) -----"
    echo "    下面每一条 FIX: 行都很关键,请连同结果一起发回。"
    "$CORE" fix 2>&1
    FIX_RC=$?
    echo "----- fix 退出码: $FIX_RC -----"
    echo

    echo "----- 4. 修复后的只读复查 -----"
    "$CORE" checkdetail 2>&1 | tail -20
    echo

    echo "----- 5. 客户端日志末尾(命令元数据) -----"
    tail -12 "$LOG" 2>/dev/null || echo "  (没有日志;检查配置里可能关了 logging)"
    echo

    echo "----- 6. 自动解读 -----"
    case "$FIX_RC" in
        0) echo "fix 自身跑完了。若界面仍有红项,那些是脚本修不了的项(出口 IP / ASN / IP 纯净度 / 生态可达性 / 更优节点),需要换线路或手动处理,不是按钮坏了。" ;;
        2) echo "退出码 2 = 核心脚本是旧版,不认识当前命令。请在终端跑:"; echo "  bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)" ;;
        *) echo "fix 非零退出。往上翻第 3 段,看最后一条 FIX: 行:"; echo "  · 停在「开始一键修复」之前 → 前置校验(python3 / WebRTC 策略)失败,0 秒退出"; echo "  · 「时区/IPv6/保镖 ✗(取消或失败)」→ 管理员密码框被取消或没弹出来"; echo "  · 「置顶规则 ✗」→ 规则写不进内核(代理组/UDP/扩展脚本未启用)"; echo "  · 「WebRTC ✗」收尾 → 前面其实都修好了,只是这项把整体判成失败" ;;
    esac
    echo
    echo "===== 诊断结束 ====="
}

# fix 的收尾会打印出口 IP(FIX:出口IP ✓ (1.2.3.4/US));诊断文件要发给别人,
# 落盘前把 IP 和本机绝对路径抹掉。国家码、各项 ✓/✗ 都保留,不影响定位。
scrub() {
    sed -E \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP]/g' \
        -e 's/(ip|warp|gateway)=[^ ]+/\1=[REDACTED]/g' \
        -e "s#$HOME#~#g"
}

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
main 2>&1 | scrub | tee "$OUT"
echo ""
echo "✓ 已保存到: $OUT"
echo "  把这个文件发给我即可(已脱敏 IP 与本机路径,不含凭据、账号内容)。"
