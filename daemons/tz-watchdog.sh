#!/bin/bash
# 时区看门狗 (参考模板) —— 安装程序会把两个占位符换成目标时区与用户目录后再安装
# 作用: 系统时区偏离目标值时自动改回,并记录日志
#
# 目标值以 env.json 为唯一来源,脚本里那份 __TZ_TARGET__ 只是「env.json 读不到」时的兜底。
# 为什么不再烧死:set-region / fix 改的是 env.json 和系统时区,没人记得回来改这里,
# 结果就是看门狗守着旧目标、每小时把系统时区改回去 —— 用户看到的是「修好了又坏了」。
TARGET="__TZ_TARGET__"
ENVJSON="__HOME__/.claude-switcher/env.json"
LOG="__HOME__/Library/Logs/tz-watchdog.log"

if [ -r "$ENVJSON" ]; then
    from_env=$(sed -n 's/.*"timezone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ENVJSON" | head -1)
    [ -n "$from_env" ] && TARGET="$from_env"
fi
# 目标为空时宁可不动:守错目标的看门狗比没有看门狗危害大得多
[ -n "$TARGET" ] || exit 0

current=$(readlink /etc/localtime 2>/dev/null)
if [ "$current" != "/var/db/timezone/zoneinfo/$TARGET" ]; then
    /usr/sbin/systemsetup -settimezone "$TARGET" >>"$LOG" 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') 时区异常: [$current] 已自动恢复为 $TARGET" >>"$LOG"
fi
